import AVFoundation
import CoreLocation
import PhotosUI
import SwiftUI
import UIKit
import Vision
import VisionKit
import ImageIO

struct ContentView: View {
    var body: some View {
        RootTabView()
    }
}

private struct RootTabView: View {
    @EnvironmentObject private var linkRouter: AppLinkRouter
    @EnvironmentObject private var notificationManager: NotificationManager
    @AppStorage("isSignedIn") private var isSignedIn = ConvexService.shared.hasCachedSession
    @State private var selectedTab = 0
    @State private var showProfileSignInSheet = false

    var body: some View {
        TabView(selection: $selectedTab) {
            ReceiptsView()
                .tabItem {
                    Label("Receipts", systemImage: "doc.text")
                }
                .tag(0)

            JoinView()
                .tabItem {
                    Label("Join", systemImage: "qrcode")
                }
                .tag(1)

            Group {
                if isSignedIn {
                    ProfileView()
                } else {
                    ProfileSignInRequiredView {
                        showProfileSignInSheet = true
                    }
                }
            }
            .tabItem {
                Label("Profile", systemImage: "person.crop.circle")
            }
            .tag(2)
        }
        .sheet(isPresented: $showProfileSignInSheet) {
            ProfileSignInSheet()
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.visible)
        }
        .tint(SPLTColor.ink)
        .onReceive(linkRouter.$joinReceiptId) { receiptId in
            guard receiptId != nil else { return }
            selectedTab = 0
        }
        .onReceive(notificationManager.$pendingPaymentConfirmation) { payload in
            guard payload != nil else { return }
            selectedTab = 0
        }
        .onChange(of: selectedTab) { tab in
            guard tab == 2, !isSignedIn else { return }
            showProfileSignInSheet = true
        }
        .onChange(of: isSignedIn) { signedIn in
            if signedIn {
                showProfileSignInSheet = false
            }
        }
        .onAppear {
            if linkRouter.joinReceiptId != nil {
                selectedTab = 0
            }
        }
    }
}

private struct ProfileSignInRequiredView: View {
    var onSignInTap: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                ReceiptsBackground()
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    EmptyStateView(
                        title: "Profile requires an account",
                        detail: "Sign in with Apple to sync receipts and keep settings in one place.",
                        icon: "person.crop.circle.badge.plus",
                        tint: SPLTColor.accent
                    )

                    Button(action: onSignInTap) {
                        HStack(spacing: 8) {
                            Image(systemName: "apple.logo")
                            Text("Sign in with Apple")
                        }
                        .font(SPLTType.bodyBold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(SPLTColor.ink)
                        )
                        .foregroundStyle(SPLTColor.canvas)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
            }
        }
    }
}

private struct ProfileSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("isSignedIn") private var isSignedIn = ConvexService.shared.hasCachedSession
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(SPLTColor.ink.opacity(0.18))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            Text("Sign in to sync this device")
                .font(SPLTType.title)
                .foregroundStyle(SPLTColor.ink)

            Text("After sign in, we migrate guest receipts and claimed items from this device into your Apple account.")
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.62))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            Button(action: handlePrimaryAction) {
                HStack(spacing: 8) {
                    if isBusy {
                        ProgressView()
                            .tint(SPLTColor.canvas)
                    } else {
                        Image(systemName: "apple.logo")
                    }
                    Text(primaryActionTitle)
                }
                .font(SPLTType.bodyBold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(SPLTColor.ink)
                )
                .foregroundStyle(SPLTColor.canvas)
            }
            .disabled(isBusy)

            if let errorMessage {
                Text(errorMessage)
                    .font(SPLTType.caption)
                    .foregroundStyle(Color.red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [SPLTColor.canvas, SPLTColor.canvasAccent],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var primaryActionTitle: String {
        if isBusy {
            return isSignedIn ? "Migrating..." : "Signing in..."
        }
        return isSignedIn ? "Retry migration" : "Sign in with Apple"
    }

    private func handlePrimaryAction() {
        errorMessage = nil
        isBusy = true

        if isSignedIn {
            Task { await migrateGuestData() }
            return
        }

        Task { await signInThenMigrate() }
    }

    @MainActor
    private func signInThenMigrate() async {
        do {
            _ = try await ConvexService.shared.signInWithApple()
        } catch {
            errorMessage = "Sign in with Apple failed."
            isBusy = false
            return
        }

        await migrateGuestData()
    }

    @MainActor
    private func migrateGuestData() async {
        do {
            let migratedCount = try await ConvexService.shared.migrateGuestDataToSignedInAccount()
            print("[SPLT] Migrated guest data to signed-in account (\(migratedCount) owned receipts)")
            isBusy = false
            dismiss()
        } catch {
            errorMessage = "Signed in, but couldn't migrate guest data yet. Try again."
            isBusy = false
        }
    }
}

private struct ReceiptRoute: Hashable {
    let receiptID: UUID
}

private struct ReceiptsView: View {
    private let headerControlSize: CGFloat = 36

    private enum ReceiptFilter: String, CaseIterable, Identifiable {
        case active
        case archived

        var id: String { rawValue }

        var title: String {
            switch self {
            case .active:
                return "Active"
            case .archived:
                return "Archived"
            }
        }
    }

    @AppStorage("isSignedIn") private var isSignedIn = ConvexService.shared.hasCachedSession
    @EnvironmentObject private var linkRouter: AppLinkRouter
    @EnvironmentObject private var notificationManager: NotificationManager
    @EnvironmentObject private var startupStore: SPLTStartupStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var permissionCenter = PermissionCenter()
    @AppStorage("shouldShowCameraPermissionNudge") private var shouldShowCameraPermissionNudge = false
    @AppStorage("useLocationForReceiptCapture") private var useLocationForReceiptCapture = true
    @State private var showScanner = false
    @State private var isProcessing = false
    @State private var showItemsSheet = false
    @State private var receipts: [Receipt] = []
    @State private var draftItems: [ReceiptItem] = []
    @State private var draftReceiptImages: [UIImage] = []
    @State private var draftReceiptTotal: Double?
    @State private var draftReceiptSubtotal: Double?
    @State private var draftReceiptTax: Double?
    @State private var draftReceiptGratuity: Double?
    @State private var draftReceiptMerchantName: String?
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var activeShareReceipt: Receipt?
    @State private var isLoadingRemoteReceipts = false
    @State private var showCameraPermissionSheet = false
    @State private var pendingScanAfterPermission = false
    @State private var selectedFilter: ReceiptFilter = .active
    @State private var navigationPath: [ReceiptRoute] = []
    @State private var joinErrorMessage: String?
    @State private var isJoiningReceipt = false
    @State private var showJoinNameSheet = false
    @State private var pendingJoinReceipt: Receipt?
    @State private var joinDisplayName = ""
    @State private var showHostSignInSheet = false
    @State private var didHydrateStartupReceipts = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                ReceiptsBackground()
                    .ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    receiptsHeader
                    receiptsTabContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 24)
                .padding(.top, 12)
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScannerView { images in
                    showScanner = false
                    process(images: images)
                }
            }
            .sheet(isPresented: $showCameraPermissionSheet) {
                CameraPermissionSheet(
                    status: permissionCenter.cameraStatus,
                    onEnable: {
                        shouldShowCameraPermissionNudge = false
                        permissionCenter.requestCamera()
                    },
                    onLater: {
                        shouldShowCameraPermissionNudge = false
                        pendingScanAfterPermission = false
                        showCameraPermissionSheet = false
                    }
                )
                .presentationDetents([.height(360)])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showItemsSheet, onDismiss: {
                draftItems = []
                draftReceiptImages = []
                draftReceiptTotal = nil
                draftReceiptSubtotal = nil
                draftReceiptTax = nil
                draftReceiptGratuity = nil
                draftReceiptMerchantName = nil
                isProcessing = false
            }) {
                ItemsSheetView(
                    items: $draftItems,
                    receiptImages: draftReceiptImages,
                    scannedTotal: $draftReceiptTotal,
                    merchantName: draftReceiptMerchantName,
                    isProcessing: isProcessing,
                    tax: $draftReceiptTax,
                    gratuity: $draftReceiptGratuity
                ) { submittedItems in
                    submitReceipt(items: submittedItems)
                }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $activeShareReceipt) { receipt in
                ShareReceiptView(receipt: receipt)
            }
            .alert(
                "Unable to join receipt",
                isPresented: Binding(
                    get: { joinErrorMessage != nil },
                    set: { newValue in
                        if !newValue {
                            joinErrorMessage = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(joinErrorMessage ?? "")
            }
            .sheet(isPresented: $showJoinNameSheet, onDismiss: {
                if let receipt = pendingJoinReceipt {
                    openReceipt(receipt)
                    pendingJoinReceipt = nil
                }
            }) {
                JoinNameInputSheet(
                    displayName: $joinDisplayName,
                    onContinue: { name in
                        Task {
                            if let receipt = pendingJoinReceipt, let code = receipt.shareCode, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                try? await ConvexService.shared.updateParticipantDisplayName(
                                    receiptCode: code,
                                    displayName: name
                                )
                            }
                            await MainActor.run {
                                showJoinNameSheet = false
                            }
                        }
                    },
                    onSkip: {
                        showJoinNameSheet = false
                    }
                )
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.visible)
            }
            .navigationDestination(for: ReceiptRoute.self) { route in
                if let receipt = receipts.first(where: { $0.id == route.receiptID }) {
                    ReceiptActivityView(
                        receipt: receipt,
                        onShareTap: { receiptForShare in
                            activeShareReceipt = receiptForShare
                        },
                        onReceiptUpdate: { updatedReceipt in
                            upsertReceipt(updatedReceipt)
                        },
                        onExitToReceipts: {
                            navigationPath.removeAll()
                            selectedFilter = .active
                            Task {
                                await loadRemoteReceipts()
                            }
                        }
                    )
                } else {
                    EmptyStateView(
                        title: "Receipt not available",
                        detail: "Pull to refresh and try opening it again.",
                        icon: "doc.text.magnifyingglass",
                        tint: SPLTColor.accent
                    )
                    .padding(.horizontal, 24)
                }
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $photoPickerItems,
                maxSelectionCount: 6,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: photoPickerItems) { newItems in
                guard !newItems.isEmpty else { return }
                showPhotoPicker = false
                Task {
                    var images: [UIImage] = []
                    for item in newItems {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            images.append(image)
                        }
                    }
                    if !images.isEmpty {
                        process(images: images)
                    }
                    await MainActor.run { photoPickerItems = [] }
                }
            }
            .task {
                hydrateFromStartupPrefetchIfNeeded()
                if receipts.isEmpty {
                    await loadRemoteReceipts()
                }
            }
            .onAppear {
                maybeShowCameraPermissionNudgeIfNeeded()
                consumePendingJoinCodeIfNeeded()
            }
            .onChange(of: isSignedIn) { _ in
                Task {
                    await loadRemoteReceipts()
                }
            }
            .onReceive(linkRouter.$joinReceiptId) { code in
                guard let code else { return }
                // If this is triggered by a payment notification, the host already
                // owns the receipt — navigate directly without the join name sheet.
                if linkRouter.pendingPaymentConfirmation != nil {
                    Task {
                        await navigateToReceiptByCode(code)
                    }
                } else {
                    Task {
                        await joinReceipt(using: code)
                    }
                }
            }
            .onReceive(notificationManager.$pendingPaymentConfirmation) { payload in
                guard let payload else { return }
                linkRouter.handlePaymentNotification(payload)
            }
            .onChange(of: scenePhase) { newPhase in
                guard newPhase == .active else { return }
                permissionCenter.refreshStatuses()
                continuePendingScanIfPossible()
            }
            .onChange(of: permissionCenter.cameraStatus) { _ in
                continuePendingScanIfPossible()
            }
            .sheet(isPresented: $showHostSignInSheet) {
                HostSignInSheet()
                    .presentationDetents([.height(340)])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var receiptsHeader: some View {
        HStack(spacing: 12) {
            receiptFilterToggle
                .frame(maxWidth: .infinity)

            receiptActionsMenu
        }
    }

    private var receiptFilterToggle: some View {
        Picker("Receipts filter", selection: $selectedFilter) {
            ForEach(ReceiptFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .frame(height: headerControlSize)
    }

    private var receiptsTabContent: some View {
        TabView(selection: $selectedFilter) {
            receiptPane(for: .active)
                .padding(.horizontal, 10)
                .tag(ReceiptFilter.active)

            receiptPane(for: .archived)
                .padding(.horizontal, 10)
                .tag(ReceiptFilter.archived)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func receiptPane(for filter: ReceiptFilter) -> some View {
        let paneReceipts = receipts(for: filter)

        ScrollView(showsIndicators: false) {
            if paneReceipts.isEmpty {
                if isLoadingRemoteReceipts && receipts.isEmpty {
                    loadingState
                } else {
                    emptyState(for: filter)
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(paneReceipts) { receipt in
                        if receipt.canManageActions {
                            Button {
                                openReceipt(receipt)
                            } label: {
                                ReceiptSummaryCard(receipt: receipt, showsShareHint: true)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if filter == .active {
                                    Button {
                                        shareReceipt(receipt)
                                    } label: {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }

                                    Button {
                                        archiveReceipt(receipt)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                } else if filter == .archived {
                                    Button {
                                        unarchiveReceipt(receipt)
                                    } label: {
                                        Label("Unarchive", systemImage: "arrow.uturn.backward")
                                    }
                                }

                                Button(role: .destructive) {
                                    deleteReceipt(receipt)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        } else {
                            Button {
                                openReceipt(receipt)
                            } label: {
                                ReceiptSummaryCard(receipt: receipt, showsShareHint: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .refreshable {
            await loadRemoteReceipts()
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            ProgressView()
                .tint(SPLTColor.ink)
            Text("Loading shared receipts")
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.6))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var receiptActionsMenu: some View {
        Group {
            if isSignedIn {
                Menu {
                    Button {
                        startScan()
                    } label: {
                        Label("Scan receipt", systemImage: "doc.text.viewfinder")
                    }

                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("Upload receipt", systemImage: "photo.on.rectangle")
                    }
                } label: {
                    receiptActionIcon
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    showHostSignInSheet = true
                } label: {
                    receiptActionIcon
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var receiptActionIcon: some View {
        Image(systemName: "doc.viewfinder")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color(uiColor: .label))
            .frame(width: headerControlSize, height: headerControlSize)
            .background(
                Circle()
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .overlay(
                        Circle()
                            .stroke(Color(uiColor: .separator).opacity(0.28), lineWidth: 1)
                    )
            )
    }

    @ViewBuilder
    private func emptyState(for filter: ReceiptFilter) -> some View {
        VStack {
            Spacer(minLength: 0)
            switch filter {
            case .active:
                if isSignedIn {
                    EmptyStateView(
                        title: "No active receipt",
                        detail: "Scan a receipt to start splitting.",
                        icon: "doc.text.viewfinder",
                        tint: SPLTColor.accent
                    )
                } else {
                    EmptyStateView(
                        title: "Sign in to host receipts",
                        detail: "Create and manage receipt splits. Joined receipts will also show up here.",
                        icon: "person.crop.circle.badge.plus",
                        tint: SPLTColor.accent
                    )
                }
            case .archived:
                EmptyStateView(
                    title: "No archived receipts",
                    detail: "Archived receipts will show up here.",
                    icon: "archivebox",
                    tint: SPLTColor.violet
                )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func receipts(for filter: ReceiptFilter) -> [Receipt] {
        switch filter {
        case .active:
            return receipts.filter(\.isActive)
        case .archived:
            return receipts.filter { !$0.isActive }
        }
    }

    private func startScan() {
        guard VNDocumentCameraViewController.isSupported else { return }
        shouldShowCameraPermissionNudge = false
        permissionCenter.refreshStatuses()

        guard permissionCenter.cameraEnabled else {
            pendingScanAfterPermission = true
            showCameraPermissionSheet = true
            return
        }

        showScanner = true
    }

    private func maybeShowCameraPermissionNudgeIfNeeded() {
        guard shouldShowCameraPermissionNudge else { return }
        permissionCenter.refreshStatuses()

        if permissionCenter.cameraEnabled {
            shouldShowCameraPermissionNudge = false
            return
        }

        showCameraPermissionSheet = true
    }

    private func continuePendingScanIfPossible() {
        if permissionCenter.cameraEnabled {
            showCameraPermissionSheet = false
            shouldShowCameraPermissionNudge = false

            if pendingScanAfterPermission {
                pendingScanAfterPermission = false
                showScanner = true
            }
        }
    }

    private func process(images: [UIImage]) {
        guard !images.isEmpty else { return }
        draftItems = []
        draftReceiptImages = images
        draftReceiptTotal = nil
        draftReceiptSubtotal = nil
        draftReceiptTax = nil
        draftReceiptGratuity = nil
        draftReceiptMerchantName = nil
        isProcessing = true
        showItemsSheet = true
        maybeRequestLocationPermissionForReceiptCapture()
        Task {
            let locationHint = await receiptCaptureLocationHint()
            let extraction = await OCRProcessor.shared.extract(from: images, locationHint: locationHint)
            await MainActor.run {
                draftItems = extraction.items
                draftReceiptTotal = extraction.receiptTotal
                draftReceiptSubtotal = extraction.subtotal
                draftReceiptTax = extraction.tax
                draftReceiptGratuity = extraction.gratuity
                draftReceiptMerchantName = extraction.merchantName
                isProcessing = false
            }
        }
    }

    private func submitReceipt(items: [ReceiptItem]) {
        guard !items.isEmpty else { return }
        let newReceipt = Receipt(
            items: items,
            scannedTotal: draftReceiptTotal,
            scannedSubtotal: draftReceiptSubtotal,
            scannedTax: draftReceiptTax,
            scannedGratuity: draftReceiptGratuity
        )
        // Persist the first receipt image so it can be uploaded to Convex later
        if let firstImage = draftReceiptImages.first {
            ReceiptImageCache.save(firstImage, for: newReceipt.id)
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            receipts = mergeReceipts(local: receipts, remote: [newReceipt])
        }
        draftItems = []
        draftReceiptImages = []
        draftReceiptTotal = nil
        draftReceiptSubtotal = nil
        draftReceiptTax = nil
        draftReceiptGratuity = nil
        draftReceiptMerchantName = nil
        showItemsSheet = false
        activeShareReceipt = newReceipt
    }

    private func shareReceipt(_ receipt: Receipt) {
        activeShareReceipt = receipt
    }

    private func archiveReceipt(_ receipt: Receipt) {
        guard receipt.canManageActions else { return }
        guard let index = receiptIndex(for: receipt), receipts[index].isActive else {
            return
        }

        withAnimation(.easeInOut(duration: 0.22)) {
            receipts[index].isActive = false
        }

        Task {
            await archiveReceiptRemotelyIfNeeded(receipt)
        }
    }

    private func deleteReceipt(_ receipt: Receipt) {
        guard receipt.canManageActions else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            receipts.removeAll { matchesReceipt($0, receipt) }
        }

        Task {
            await destroyReceiptRemotely(receipt)
        }
    }

    private func unarchiveReceipt(_ receipt: Receipt) {
        guard receipt.canManageActions else { return }
        guard let index = receiptIndex(for: receipt), !receipts[index].isActive else {
            return
        }

        withAnimation(.easeInOut(duration: 0.22)) {
            receipts[index].isActive = true
        }

        Task {
            await unarchiveReceiptRemotely(receipt)
        }
    }

    private func openReceipt(_ receipt: Receipt) {
        navigationPath = [ReceiptRoute(receiptID: receipt.id)]
    }

    /// Navigate directly to a receipt by share code — used when the host taps a
    /// payment notification so we skip the join-name sheet entirely.
    @MainActor
    private func navigateToReceiptByCode(_ rawCode: String) async {
        let code = rawCode.filter(\.isNumber)
        linkRouter.joinReceiptId = nil

        // Try to find the receipt in the existing local list first.
        if let existing = receipts.first(where: { $0.shareCode == code }) {
            selectedFilter = existing.archivedReason != nil ? .archived : .active
            navigationPath = [ReceiptRoute(receiptID: existing.id)]
            return
        }

        // If not found locally, refresh and try again.
        await loadRemoteReceipts()

        if let existing = receipts.first(where: { $0.shareCode == code }) {
            selectedFilter = existing.archivedReason != nil ? .archived : .active
            navigationPath = [ReceiptRoute(receiptID: existing.id)]
            return
        }

        // As a last resort, join (host re-joining is a no-op on the server).
        do {
            if let joined = try await ConvexService.shared.joinReceipt(withCode: code) {
                withAnimation(.easeInOut(duration: 0.22)) {
                    receipts = mergeReceipts(local: receipts, remote: [joined])
                    selectedFilter = .active
                }
                let dest = receipts.first(where: {
                    $0.id == joined.id ||
                    ($0.shareCode != nil && $0.shareCode == joined.shareCode)
                }) ?? joined
                navigationPath = [ReceiptRoute(receiptID: dest.id)]
            }
        } catch {
            print("[SPLT] navigateToReceiptByCode failed: \(error)")
        }
    }

    private func consumePendingJoinCodeIfNeeded() {
        guard let code = linkRouter.joinReceiptId else { return }
        Task {
            await joinReceipt(using: code)
        }
    }

    @MainActor
    private func joinReceipt(using rawCode: String) async {
        guard !isJoiningReceipt else { return }

        let code = rawCode.filter(\.isNumber)
        guard code.count == 6 else {
            linkRouter.joinReceiptId = nil
            joinErrorMessage = "Share code should be 6 digits."
            return
        }

        isJoiningReceipt = true
        linkRouter.joinReceiptId = nil
        defer { isJoiningReceipt = false }

        do {
            guard let joinedReceipt = try await ConvexService.shared.joinReceipt(withCode: code) else {
                joinErrorMessage = "We couldn't find that active receipt."
                return
            }

            withAnimation(.easeInOut(duration: 0.22)) {
                receipts = mergeReceipts(local: receipts, remote: [joinedReceipt])
                selectedFilter = .active
            }

            let destinationReceipt = receipts.first(where: {
                $0.id == joinedReceipt.id ||
                ($0.remoteID != nil && $0.remoteID == joinedReceipt.remoteID) ||
                ($0.shareCode != nil && $0.shareCode == joinedReceipt.shareCode)
            }) ?? joinedReceipt

            pendingJoinReceipt = destinationReceipt
            joinDisplayName = ""
            showJoinNameSheet = true
        } catch {
            joinErrorMessage = error.localizedDescription
        }
    }

    private func upsertReceipt(_ updatedReceipt: Receipt) {
        withAnimation(.easeInOut(duration: 0.18)) {
            receipts = mergeReceipts(local: receipts, remote: [updatedReceipt])
        }
    }

    @MainActor
    private func archiveReceiptRemotelyIfNeeded(_ receipt: Receipt) async {
        guard shouldSyncReceiptAction(receipt) else { return }

        do {
            _ = try await ConvexService.shared.archiveReceipt(clientReceiptId: receipt.id.uuidString)
        } catch {
            print("[SPLT] Failed to archive receipt \(receipt.id): \(error)")
        }
    }

    @MainActor
    private func unarchiveReceiptRemotely(_ receipt: Receipt) async {
        guard shouldSyncReceiptAction(receipt) else { return }

        do {
            _ = try await ConvexService.shared.unarchiveReceipt(clientReceiptId: receipt.id.uuidString)
        } catch {
            print("[SPLT] Failed to unarchive receipt \(receipt.id): \(error)")
        }
    }

    @MainActor
    private func destroyReceiptRemotely(_ receipt: Receipt) async {
        guard shouldSyncReceiptAction(receipt) else { return }

        do {
            _ = try await ConvexService.shared.destroyReceipt(clientReceiptId: receipt.id.uuidString)
        } catch {
            print("[SPLT] Failed to destroy receipt \(receipt.id): \(error)")
        }
    }

    private func maybeRequestLocationPermissionForReceiptCapture() {
        guard useLocationForReceiptCapture else { return }
        permissionCenter.refreshStatuses()
        permissionCenter.requestLocation()
    }

    private func receiptCaptureLocationHint() async -> OCRProcessor.LocationHint? {
        guard useLocationForReceiptCapture else { return nil }
        permissionCenter.refreshStatuses()
        guard permissionCenter.locationEnabled else { return nil }

        guard let location = await ReceiptLocationProvider.shared.currentLocation() else {
            return nil
        }

        let accuracy = location.horizontalAccuracy > 0 ? location.horizontalAccuracy : nil
        return OCRProcessor.LocationHint(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracyMeters: accuracy,
            capturedAt: location.timestamp
        )
    }

    private func loadRemoteReceipts() async {
        await MainActor.run { isLoadingRemoteReceipts = true }

        do {
            let remoteReceipts = try await ConvexService.shared.fetchRecentReceipts(limit: 30)
            print("[SPLT] Fetched \(remoteReceipts.count) remote receipts")
            if !remoteReceipts.isEmpty {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        receipts = mergeReceipts(local: receipts, remote: remoteReceipts)
                    }
                }
            }
        } catch {
            print("[SPLT] Failed to fetch remote receipts: \(error)")
        }

        await MainActor.run { isLoadingRemoteReceipts = false }
    }

    private func hydrateFromStartupPrefetchIfNeeded() {
        guard !didHydrateStartupReceipts else { return }
        didHydrateStartupReceipts = true

        let prefetchedReceipts = startupStore.consumePrefetchedReceipts()
        guard !prefetchedReceipts.isEmpty else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            receipts = mergeReceipts(local: receipts, remote: prefetchedReceipts)
        }
    }

    private func mergeReceipts(local: [Receipt], remote: [Receipt]) -> [Receipt] {
        var merged = local

        for incoming in remote {
            if let exactMatchIndex = merged.firstIndex(where: { $0.id == incoming.id }) {
                merged[exactMatchIndex] = mergeReceipt(existing: merged[exactMatchIndex], incoming: incoming)
                continue
            }

            if let remoteMatchIndex = merged.firstIndex(where: { existing in
                (existing.remoteID != nil && existing.remoteID == incoming.remoteID) ||
                (existing.shareCode != nil && existing.shareCode == incoming.shareCode)
            }) {
                merged[remoteMatchIndex] = mergeReceipt(
                    existing: merged[remoteMatchIndex],
                    incoming: incoming,
                    preserveExistingID: true
                )
                continue
            }

            if let fuzzyMatchIndex = merged.firstIndex(where: { existing in
                existing.items == incoming.items && abs(existing.date.timeIntervalSince(incoming.date)) < 15
            }) {
                merged[fuzzyMatchIndex] = mergeReceipt(
                    existing: merged[fuzzyMatchIndex],
                    incoming: incoming,
                    preserveExistingID: true
                )
                continue
            }

            merged.append(incoming)
        }

        return merged.sorted { $0.date > $1.date }
    }

    private func receiptIndex(for target: Receipt) -> Int? {
        receipts.firstIndex { matchesReceipt($0, target) }
    }

    private func matchesReceipt(_ lhs: Receipt, _ rhs: Receipt) -> Bool {
        if lhs.id == rhs.id { return true }
        if let lhsRemoteID = lhs.remoteID, let rhsRemoteID = rhs.remoteID, lhsRemoteID == rhsRemoteID {
            return true
        }
        if let lhsCode = lhs.shareCode, let rhsCode = rhs.shareCode, lhsCode == rhsCode {
            return true
        }
        return false
    }

    private func shouldSyncReceiptAction(_ receipt: Receipt) -> Bool {
        receipt.canManageActions && (receipt.remoteID != nil || !(receipt.shareCode?.isEmpty ?? true))
    }

    private func mergeReceipt(existing: Receipt, incoming: Receipt, preserveExistingID: Bool = false) -> Receipt {
        Receipt(
            id: preserveExistingID ? existing.id : incoming.id,
            date: incoming.date,
            items: incoming.items,
            isActive: incoming.isActive,
            canManageActions: incoming.canManageActions,
            scannedTotal: incoming.scannedTotal ?? existing.scannedTotal,
            scannedSubtotal: incoming.scannedSubtotal ?? existing.scannedSubtotal,
            scannedTax: incoming.scannedTax ?? existing.scannedTax,
            scannedGratuity: incoming.scannedGratuity ?? existing.scannedGratuity,
            settlementPhase: incoming.settlementPhase,
            archivedReason: incoming.archivedReason ?? existing.archivedReason,
            shareCode: incoming.shareCode ?? existing.shareCode,
            remoteID: incoming.remoteID ?? existing.remoteID
        )
    }
}

private struct CameraPermissionSheet: View {
    let status: AVAuthorizationStatus
    var onEnable: () -> Void
    var onLater: () -> Void

    private var title: String {
        switch status {
        case .denied, .restricted:
            return "Enable camera in Settings"
        default:
            return "Enable camera when you scan"
        }
    }

    private var detail: String {
        switch status {
        case .denied, .restricted:
            return "SPLT only asks for camera when you scan receipts. Open Settings to allow access."
        default:
            return "Camera access is only needed for scanning receipts. You can keep using upload anytime."
        }
    }

    private var actionTitle: String {
        switch status {
        case .denied, .restricted:
            return "Open Settings"
        default:
            return "Enable Camera"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(SPLTColor.ink.opacity(0.18))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            ZStack {
                Circle()
                    .fill(SPLTColor.accent.opacity(0.16))
                    .frame(width: 64, height: 64)
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(SPLTColor.accent)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(SPLTType.title)
                    .foregroundStyle(SPLTColor.ink)
                Text(detail)
                    .font(SPLTType.body)
                    .foregroundStyle(SPLTColor.ink.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 8)

            VStack(spacing: 8) {
                Button(actionTitle) {
                    onEnable()
                }
                .font(SPLTType.bodyBold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(SPLTColor.ink)
                )
                .foregroundStyle(SPLTColor.canvas)

                Button("Not now") {
                    onLater()
                }
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.55))
            }
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [SPLTColor.canvas, SPLTColor.canvasAccent],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct HostSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("isSignedIn") private var isSignedIn = ConvexService.shared.hasCachedSession
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(SPLTColor.ink.opacity(0.18))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            ZStack {
                Circle()
                    .fill(SPLTColor.accent.opacity(0.16))
                    .frame(width: 64, height: 64)
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(SPLTColor.accent)
            }

            VStack(spacing: 6) {
                Text("Sign in to host")
                    .font(SPLTType.title)
                    .foregroundStyle(SPLTColor.ink)
                Text("Hosting a receipt requires an account so your receipts, payment info, and history stay safe across devices.")
                    .font(SPLTType.body)
                    .foregroundStyle(SPLTColor.ink.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 8)

            VStack(spacing: 8) {
                Button {
                    signIn()
                } label: {
                    HStack(spacing: 8) {
                        if isBusy {
                            ProgressView()
                                .tint(SPLTColor.canvas)
                        } else {
                            Image(systemName: "apple.logo")
                        }
                        Text(isBusy ? "Signing in..." : "Sign in with Apple")
                    }
                    .font(SPLTType.bodyBold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(SPLTColor.ink)
                    )
                    .foregroundStyle(SPLTColor.canvas)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                Button("Not now") {
                    dismiss()
                }
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.55))
            }
            .padding(.top, 2)

            if let errorMessage {
                Text(errorMessage)
                    .font(SPLTType.caption)
                    .foregroundStyle(Color.red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [SPLTColor.canvas, SPLTColor.canvasAccent],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func signIn() {
        errorMessage = nil
        isBusy = true
        Task {
            do {
                _ = try await ConvexService.shared.signInWithApple()
                let _ = try await ConvexService.shared.migrateGuestDataToSignedInAccount()
                await MainActor.run {
                    isBusy = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Sign in failed. Please try again."
                    isBusy = false
                }
            }
        }
    }
}

private struct JoinNameInputSheet: View {
    @Binding var displayName: String
    var onContinue: (String) -> Void
    var onSkip: () -> Void

    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(SPLTColor.ink.opacity(0.18))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            ZStack {
                Circle()
                    .fill(SPLTColor.mint.opacity(0.16))
                    .frame(width: 64, height: 64)
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(SPLTColor.mint)
            }

            VStack(spacing: 6) {
                Text("You're in!")
                    .font(SPLTType.title)
                    .foregroundStyle(SPLTColor.ink)
                Text("Add your name so everyone knows who you are.")
                    .font(SPLTType.body)
                    .foregroundStyle(SPLTColor.ink.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 8)

            TextField("Your name", text: $displayName)
                .font(SPLTType.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(SPLTColor.ink.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(SPLTColor.subtle, lineWidth: 1)
                        )
                )
                .focused($isNameFocused)
                .submitLabel(.done)
                .onSubmit {
                    onContinue(displayName)
                }

            VStack(spacing: 8) {
                Button {
                    onContinue(displayName)
                } label: {
                    Text("Continue")
                        .font(SPLTType.bodyBold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(SPLTColor.ink)
                        )
                        .foregroundStyle(SPLTColor.canvas)
                }
                .buttonStyle(.plain)

                Button("Skip for now") {
                    onSkip()
                }
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.55))
            }
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [SPLTColor.canvas, SPLTColor.canvasAccent],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onAppear {
            isNameFocused = true
        }
    }
}

private struct JoinView: View {
    @EnvironmentObject private var linkRouter: AppLinkRouter
    @State private var code = ""
    @FocusState private var isCodeFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                SPLTGradientBackground()
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 24) {
                    joinHeader
                    joinCodeEntryCard
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        isCodeFieldFocused = false
                        hideKeyboard()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
        }
    }

    private var joinHeader: some View {
        PageSectionHeader(
            title: "Join",
            detail: "Enter the 6-digit share code. We'll open the live receipt in your Receipts tab."
        )
    }

    private var joinCodeEntryCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Share code")
                .font(SPLTType.label)
                .foregroundStyle(SPLTColor.ink.opacity(0.6))
                .textCase(.uppercase)

            TextField("123456", text: $code)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .kerning(4)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .keyboardType(.numberPad)
                .focused($isCodeFieldFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(SPLTColor.canvas)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(code.isEmpty ? SPLTColor.subtle : SPLTColor.accent.opacity(0.38), lineWidth: 1)
                        )
                )
                .onChange(of: code) { newValue in
                    let digitsOnly = newValue.filter { $0.isNumber }
                    let limited = String(digitsOnly.prefix(6))
                    if limited != newValue {
                        code = limited
                    }
                }
                .submitLabel(.go)
                .onSubmit {
                    joinWithCodeIfValid()
                }

            Text("Use the code your friend shared with you.")
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.55))

            Button(action: joinWithCodeIfValid) {
                Text("Join receipt")
                    .font(SPLTType.bodyBold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(code.count == 6 ? SPLTColor.ink : SPLTColor.ink.opacity(0.18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(SPLTColor.subtle, lineWidth: 1)
                            )
                    )
                    .foregroundStyle(code.count == 6 ? SPLTColor.canvas : SPLTColor.ink.opacity(0.45))
            }
            .disabled(code.count != 6)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(SPLTColor.canvas.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(SPLTColor.subtle, lineWidth: 1)
                )
        )
    }

    private func joinWithCodeIfValid() {
        guard code.count == 6 else { return }
        isCodeFieldFocused = false
        hideKeyboard()
        linkRouter.joinReceiptId = code
        code = ""
    }
}

private enum AppThemeOption: String, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            return "Auto"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}

private enum PreferredPaymentMethod: String, CaseIterable, Identifiable {
    case venmo = "venmo"
    case cashApp = "cash_app"
    case zelle = "zelle"
    case cashApplePay = "cash_apple_pay"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .venmo:
            return "Venmo"
        case .cashApp:
            return "Cash App"
        case .zelle:
            return "Zelle"
        case .cashApplePay:
            return "Cash / Apple Pay"
        }
    }

    var symbol: String {
        switch self {
        case .venmo:
            return "v.circle.fill"
        case .cashApp:
            return "c.square.fill"
        case .zelle:
            return "z.square.fill"
        case .cashApplePay:
            return "wallet.pass"
        }
    }

    var logoAssetName: String? {
        switch self {
        case .venmo:
            return "PaymentLogoVenmo"
        case .cashApp:
            return "PaymentLogoCashApp"
        case .zelle:
            return "PaymentLogoZelle"
        case .cashApplePay:
            return nil
        }
    }

    var brandColor: Color {
        switch self {
        case .venmo:
            return Color(red: 0.0, green: 140.0 / 255.0, blue: 1.0) // #008CFF
        case .cashApp:
            return Color(red: 0.0, green: 224.0 / 255.0, blue: 18.0 / 255.0) // #00E012
        case .zelle:
            return Color(red: 108.0 / 255.0, green: 28.0 / 255.0, blue: 211.0 / 255.0) // #6C1CD3
        case .cashApplePay:
            return Color(.systemGray)
        }
    }

    var inputLabel: String {
        switch self {
        case .venmo: return "Username"
        case .cashApp: return "Cashtag"
        case .zelle: return "Contact"
        case .cashApplePay: return ""
        }
    }

    var inputPlaceholder: String {
        switch self {
        case .venmo: return "@username"
        case .cashApp: return "$cashtag"
        case .zelle: return "phone or email"
        case .cashApplePay: return ""
        }
    }
}

private struct ProfileView: View {
    @EnvironmentObject private var startupStore: SPLTStartupStore
    @AppStorage("profileDisplayName") private var displayName = ""
    @AppStorage("profilePreferredPaymentMethod") private var preferredPaymentMethodRaw = PreferredPaymentMethod.cashApplePay.rawValue
    @AppStorage("profileAbsorbExtraCents") private var absorbExtraCents = false
    @AppStorage("profileVenmoEnabled") private var venmoEnabled = false
    @AppStorage("profileVenmoUsername") private var venmoUsername = ""
    @AppStorage("profileCashAppEnabled") private var cashAppEnabled = false
    @AppStorage("profileCashAppCashtag") private var cashAppCashtag = ""
    @AppStorage("profileZelleEnabled") private var zelleEnabled = false
    @AppStorage("profileZelleContact") private var zelleContact = ""
    @AppStorage("profileCashApplePayEnabled") private var cashApplePayEnabled = true
    @AppStorage("appTheme") private var appThemeRaw = AppThemeOption.auto.rawValue
    @AppStorage("useLocationForReceiptCapture") private var useLocationForReceiptCapture = true
    @AppStorage("isSignedIn") private var isSignedIn = ConvexService.shared.hasCachedSession

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var profileImage: UIImage?
    @State private var accountEmail: String?
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var lastSyncedDisplayName = ""
    @State private var didHydrateStartupProfile = false

    var body: some View {
        NavigationStack {
            Form {
                profileHeaderSection
                accountMenuSection
                appearanceSection
                receiptCaptureSection
                authSection
                errorSection
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await refreshProfile()
        }
        .onChange(of: selectedPhotoItem) { newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    let encoded = ProfilePhotoStore.optimizedJPEGData(for: image) ?? data
                    try? ProfilePhotoStore.save(data: encoded)
                    let previewImage = UIImage(data: encoded) ?? image
                    await MainActor.run {
                        profileImage = previewImage
                    }
                    await uploadProfilePhotoIfNeeded(imageData: encoded)
                }
            }
        }
    }

    private var profileHeaderSection: some View {
        Section {
            VStack(spacing: 10) {
                ProfileAvatarView(image: profileImage, size: 78)
                Text(profileDisplayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var accountMenuSection: some View {
        Section {
            NavigationLink {
                PersonalInfoView(
                    displayName: $displayName,
                    accountEmail: accountEmail,
                    profileImage: profileImage,
                    selectedPhotoItem: $selectedPhotoItem,
                    onSaveName: {
                        Task { await saveDisplayNameIfNeeded() }
                    }
                )
            } label: {
                settingsRow(title: "Personal Information", systemImage: "person.text.rectangle")
            }

            NavigationLink {
                PaymentOptionsView(
                    preferredPaymentMethodRaw: $preferredPaymentMethodRaw,
                    absorbExtraCents: $absorbExtraCents,
                    venmoEnabled: $venmoEnabled,
                    venmoUsername: $venmoUsername,
                    cashAppEnabled: $cashAppEnabled,
                    cashAppCashtag: $cashAppCashtag,
                    zelleEnabled: $zelleEnabled,
                    zelleContact: $zelleContact,
                    onSave: {
                        Task { await savePaymentOptions() }
                    }
                )
            } label: {
                settingsRow(title: "Payment options", systemImage: "creditcard")
            }
        }
    }

    private var profileDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Your Account" : trimmed
    }

    private func settingsRow(title: String, systemImage: String) -> some View {
        Label {
            Text(title)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker("App theme", selection: $appThemeRaw) {
                ForEach(AppThemeOption.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
        } header: {
            Text("Appearance")
        }
    }

    private var receiptCaptureSection: some View {
        Section {
            Toggle("Match location", isOn: $useLocationForReceiptCapture)
                .tint(SPLTColor.mint)
        } header: {
            Text("Receipt capture")
        } footer: {
            Text("When enabled, SPLT can use location permission during receipt capture to help match nearby merchant names.")
        }
    }

    private var authSection: some View {
        Section("Sign-In & Security") {
            if isSignedIn {
                Button(role: .destructive) {
                    Task { await handleLogout() }
                } label: {
                    HStack {
                        if isBusy {
                            ProgressView()
                        }
                        Text("Log out")
                    }
                }
            } else {
                Button {
                    Task { await handleSignIn() }
                } label: {
                    HStack(spacing: 8) {
                        if isBusy {
                            ProgressView()
                        } else {
                            Image(systemName: "apple.logo")
                        }
                        Text("Sign in with Apple")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let errorMessage {
            Section {
                Text(errorMessage)
                    .font(SPLTType.caption)
                    .foregroundStyle(Color.red.opacity(0.9))
            }
        }
    }

    private func refreshProfile() async {
        profileImage = ProfilePhotoStore.loadImage()
        if !didHydrateStartupProfile {
            didHydrateStartupProfile = true
            if let prefetchedProfile = startupStore.consumePrefetchedProfile() {
                let prefetchedImage = await ProfilePhotoStore.loadImage(fromRemoteReference: prefetchedProfile.pictureURL)
                await MainActor.run {
                    applyLoadedProfile(prefetchedProfile, remoteImage: prefetchedImage)
                }
            }
        }

        do {
            let profile = try await ConvexService.shared.fetchMyProfile()
            let remoteImage = await ProfilePhotoStore.loadImage(fromRemoteReference: profile?.pictureURL)
            await MainActor.run {
                applyLoadedProfile(profile, remoteImage: remoteImage)
                errorMessage = nil
            }
        } catch {
            await MainActor.run {
                errorMessage = "Couldn't load profile right now."
            }
        }
    }

    private func applyLoadedProfile(_ profile: UserProfile?, remoteImage: UIImage?) {
        if let profile {
            accountEmail = profile.email
            if let remoteImage {
                profileImage = remoteImage
                if let encoded = ProfilePhotoStore.optimizedJPEGData(for: remoteImage) {
                    try? ProfilePhotoStore.save(data: encoded)
                }
            }
            let remoteName = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let remoteName = profile.name,
               !remoteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = remoteName
            }
            lastSyncedDisplayName = remoteName
            if let remotePayment = profile.preferredPaymentMethod,
               PreferredPaymentMethod(rawValue: remotePayment) != nil {
                preferredPaymentMethodRaw = remotePayment
            }
            absorbExtraCents = profile.absorbExtraCents
            venmoEnabled = profile.venmoEnabled
            venmoUsername = profile.venmoUsername ?? ""
            cashAppEnabled = profile.cashAppEnabled
            cashAppCashtag = profile.cashAppCashtag ?? ""
            zelleEnabled = profile.zelleEnabled
            zelleContact = profile.zelleContact ?? ""
            cashApplePayEnabled = profile.cashApplePayEnabled
        } else {
            accountEmail = nil
            lastSyncedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if PreferredPaymentMethod(rawValue: preferredPaymentMethodRaw) == nil {
            preferredPaymentMethodRaw = PreferredPaymentMethod.cashApplePay.rawValue
        }
    }

    private func saveDisplayNameIfNeeded() async {
        guard isSignedIn else { return }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName != lastSyncedDisplayName else { return }
        do {
            try await ConvexService.shared.updateMyProfile(
                name: trimmedName.isEmpty ? nil : trimmedName,
                preferredPaymentMethod: nil
            )
            await MainActor.run {
                lastSyncedDisplayName = trimmedName
                errorMessage = nil
            }
        } catch {
            await MainActor.run {
                errorMessage = "Couldn't save your name."
            }
        }
    }

    private func savePaymentOptions() async {
        guard isSignedIn else { return }
        let normalizedVenmo = venmoUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCashApp = cashAppCashtag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "$"))
        let normalizedZelle = zelleContact.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeMethods = availablePreferredMethods(
            venmoEnabled: venmoEnabled,
            venmoUsername: normalizedVenmo,
            cashAppEnabled: cashAppEnabled,
            cashAppCashtag: normalizedCashApp,
            zelleEnabled: zelleEnabled,
            zelleContact: normalizedZelle,
            cashApplePayEnabled: true
        )
        if !activeMethods.contains(where: { $0.rawValue == preferredPaymentMethodRaw }) {
            preferredPaymentMethodRaw = activeMethods.first?.rawValue ?? PreferredPaymentMethod.cashApplePay.rawValue
        }

        do {
            try await ConvexService.shared.updateMyProfile(
                name: nil,
                preferredPaymentMethod: preferredPaymentMethodRaw,
                absorbExtraCents: absorbExtraCents,
                venmoEnabled: venmoEnabled,
                venmoUsername: normalizedVenmo.isEmpty ? nil : normalizedVenmo,
                cashAppEnabled: cashAppEnabled,
                cashAppCashtag: normalizedCashApp.isEmpty ? nil : normalizedCashApp,
                zelleEnabled: zelleEnabled,
                zelleContact: normalizedZelle.isEmpty ? nil : normalizedZelle,
                cashApplePayEnabled: true
            )
            await MainActor.run { errorMessage = nil }
        } catch {
            await MainActor.run {
                errorMessage = "Couldn't save payment options."
            }
        }
    }

    private func availablePreferredMethods(
        venmoEnabled: Bool,
        venmoUsername: String,
        cashAppEnabled: Bool,
        cashAppCashtag: String,
        zelleEnabled: Bool,
        zelleContact: String,
        cashApplePayEnabled: Bool
    ) -> [PreferredPaymentMethod] {
        var methods: [PreferredPaymentMethod] = [.cashApplePay]
        if venmoEnabled, !venmoUsername.isEmpty {
            methods.append(.venmo)
        }
        if cashAppEnabled, !cashAppCashtag.isEmpty {
            methods.append(.cashApp)
        }
        if zelleEnabled, !zelleContact.isEmpty {
            methods.append(.zelle)
        }
        return methods
    }

    private func uploadProfilePhotoIfNeeded(imageData: Data) async {
        guard isSignedIn else { return }
        do {
            try await ConvexService.shared.uploadMyProfilePhoto(imageData)
            await refreshProfile()
            await MainActor.run { errorMessage = nil }
        } catch {
            print("[SPLT] Profile photo upload failed: \(error.localizedDescription)")
            await MainActor.run {
                errorMessage = "Couldn't upload your profile photo."
            }
        }
    }

    private func handleSignIn() async {
        await MainActor.run { isBusy = true }
        do {
            _ = try await ConvexService.shared.signInWithApple()
            _ = try? await ConvexService.shared.migrateGuestDataToSignedInAccount()
            await refreshProfile()
        } catch {
            await MainActor.run {
                errorMessage = "Sign in with Apple failed."
            }
        }
        await MainActor.run { isBusy = false }
    }

    private func handleLogout() async {
        await MainActor.run { isBusy = true }
        await ConvexService.shared.signOut()
        await MainActor.run {
            accountEmail = nil
            lastSyncedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = nil
            isBusy = false
        }
    }
}

private struct ProfileAvatarView: View {
    let image: UIImage?
    var size: CGFloat = 52

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                )
        } else {
            Circle()
                .fill(Color(uiColor: .systemGray5))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: max(14, size * 0.36), weight: .semibold))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                )
                .overlay(
                    Circle()
                        .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                )
        }
    }
}

private struct PersonalInfoView: View {
    @Binding var displayName: String
    let accountEmail: String?
    let profileImage: UIImage?
    @Binding var selectedPhotoItem: PhotosPickerItem?
    let onSaveName: () -> Void

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    ProfileAvatarView(image: profileImage, size: 90)
                    Spacer()
                }

                PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                    Text("Change Photo")
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

            Section {
                LabeledContent("Name") {
                    TextField("Name", text: $displayName)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(onSaveName)
                }

                HStack {
                    Text("Email")
                    Spacer(minLength: 12)
                    Text(accountEmail ?? "Not available")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .navigationTitle("Personal Information")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: onSaveName)
    }
}

private struct PaymentOptionsView: View {
    @Binding var preferredPaymentMethodRaw: String
    @Binding var absorbExtraCents: Bool
    @Binding var venmoEnabled: Bool
    @Binding var venmoUsername: String
    @Binding var cashAppEnabled: Bool
    @Binding var cashAppCashtag: String
    @Binding var zelleEnabled: Bool
    @Binding var zelleContact: String
    let onSave: () -> Void

    private var availableMethods: [PreferredPaymentMethod] {
        var methods: [PreferredPaymentMethod] = [.cashApplePay]
        if venmoEnabled, !venmoUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            methods.append(.venmo)
        }
        if cashAppEnabled, !cashAppCashtag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            methods.append(.cashApp)
        }
        if zelleEnabled, !zelleContact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            methods.append(.zelle)
        }
        return methods
    }

    var body: some View {
        Form {
            Section {
                Picker("Preferred", selection: $preferredPaymentMethodRaw) {
                    ForEach(availableMethods) { method in
                        Text(method.title).tag(method.rawValue)
                    }
                }
            } header: {
                Text("Preferred Payment")
            } footer: {
                Text("This is your default suggestion when settling up.")
            }

            Section {
                paymentToggleRow(.venmo, isOn: $venmoEnabled)
                if venmoEnabled {
                    paymentInputRow(.venmo, text: $venmoUsername)
                }

                paymentToggleRow(.cashApp, isOn: $cashAppEnabled)
                if cashAppEnabled {
                    paymentInputRow(.cashApp, text: $cashAppCashtag)
                }

                paymentToggleRow(.zelle, isOn: $zelleEnabled)
                if zelleEnabled {
                    paymentInputRow(.zelle, text: $zelleContact)
                }
            } header: {
                Text("Active options")
            } footer: {
                Text("Enable the methods guests can use to pay you. Cash and Apple Pay are always available as a fallback.")
            }

            Section {
                Toggle("Absorb extra cents", isOn: $absorbExtraCents)
                    .tint(SPLTColor.mint)
            } footer: {
                Text("If enabled, rounding cents are added to your portion. Otherwise the guest with the largest split gets the extra cent.")
            }
        }
        .navigationTitle("Payment options")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: preferredPaymentMethodRaw) { _ in onSave() }
        .onChange(of: venmoEnabled) { _ in onSave() }
        .onChange(of: cashAppEnabled) { _ in onSave() }
        .onChange(of: zelleEnabled) { _ in onSave() }
        .onChange(of: absorbExtraCents) { _ in onSave() }
        .onChange(of: venmoUsername) { _ in onSave() }
        .onChange(of: cashAppCashtag) { _ in onSave() }
        .onChange(of: zelleContact) { _ in onSave() }
        .onDisappear(perform: onSave)
    }

    // MARK: - Payment Method Row Builders

    @ViewBuilder
    private func paymentToggleRow(
        _ method: PreferredPaymentMethod,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 14) {
            paymentMethodBadge(method: method, isEnabled: isOn.wrappedValue)

            Toggle(method.title, isOn: isOn.animation(.spring(response: 0.35, dampingFraction: 0.8)))
                .tint(SPLTColor.mint)
        }
    }

    @ViewBuilder
    private func paymentMethodBadge(method: PreferredPaymentMethod, isEnabled: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isEnabled ? method.brandColor : Color(.systemGray3))

            if let assetName = method.logoAssetName, UIImage(named: assetName) != nil {
                Image(assetName)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
                    .opacity(isEnabled ? 1 : 0.65)
            } else {
                Image(systemName: method.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.85))
            }
        }
        .frame(width: 29, height: 29)
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
    }

    @ViewBuilder
    private func paymentInputRow(
        _ method: PreferredPaymentMethod,
        text: Binding<String>
    ) -> some View {
        HStack {
            Text(method.inputLabel)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Spacer()
            TextField(method.inputPlaceholder, text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .padding(.leading, 43)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

private enum ProfilePhotoStore {
    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profile-photo.jpg")
    }

    static func loadImage() -> UIImage? {
        UIImage(contentsOfFile: fileURL.path)
    }

    static func save(data: Data) throws {
        try data.write(to: fileURL, options: .atomic)
    }

    static func optimizedJPEGData(for image: UIImage) -> Data? {
        let maxDimension: CGFloat = 640
        let longestEdge = max(image.size.width, image.size.height)
        let scale = longestEdge > maxDimension ? (maxDimension / longestEdge) : 1
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resizedImage.jpegData(compressionQuality: 0.72)
    }

    static func loadImage(fromRemoteReference reference: String?) async -> UIImage? {
        guard let reference else { return nil }

        if reference.hasPrefix("data:image") {
            guard let commaIndex = reference.firstIndex(of: ",") else { return nil }
            let base64Payload = String(reference[reference.index(after: commaIndex)...])
            guard let data = Data(base64Encoded: base64Payload) else { return nil }
            return UIImage(data: data)
        }

        guard let url = URL(string: reference) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else { return nil }
        return UIImage(data: data)
    }
}

private struct PageSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(SPLTType.display)
                .foregroundStyle(SPLTColor.ink)
            Text(detail)
                .font(SPLTType.body)
                .foregroundStyle(SPLTColor.ink.opacity(0.65))
        }
    }
}

private struct ItemsSheetView: View {
    private struct RemovedItemEntry {
        let item: ReceiptItem
        let index: Int
    }

    private struct RemovedItemsSnapshot {
        let entries: [RemovedItemEntry]

        var count: Int { entries.count }
    }

    @Binding var items: [ReceiptItem]
    let receiptImages: [UIImage]
    @Binding var scannedTotal: Double?
    let merchantName: String?
    let isProcessing: Bool
    @Binding var tax: Double?
    @Binding var gratuity: Double?
    var onSubmit: ([ReceiptItem]) -> Void
    @State private var quantityPickerIndex: Int?
    @State private var isFeeSectionExpanded = false
    @State private var editingFeeField: FeeField?

    private enum FeeField: Hashable {
        case tax, gratuity, otherFees
    }
    @State private var pricePickerIndex: Int?
    @State private var isBulkSelectionEnabled = false
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var pendingUndoSnapshot: RemovedItemsSnapshot?
    @State private var undoDismissTask: Task<Void, Never>?
    @State private var isAddItemSheetPresented = false
    @FocusState private var focusedItem: UUID?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    ReceiptSheetHeader(
                        title: headerTitle,
                        itemCount: items.count,
                        total: displayedTotal,
                        isLoading: isProcessing,
                        isBulkSelectionEnabled: isBulkSelectionEnabled,
                        selectedCount: selectedItemIDs.count,
                        onBulkToggle: toggleBulkSelectionMode,
                        onBulkRemove: removeSelectedItems
                    )

                    if !receiptImages.isEmpty {
                        ReceiptCapturePreviewCard(
                            images: receiptImages,
                            isLoading: isProcessing
                        )
                    }

                    if !isProcessing, items.isEmpty {
                        GlassCallout(
                            title: "No items detected",
                            detail: "Try a clearer photo or adjust lighting. You can also type items manually.",
                            icon: "sparkles",
                            tint: SPLTColor.sun
                        )
                    } else if !isProcessing {
                        LazyVStack(spacing: 10) {
                            ForEach($items) { $item in
                                let row = ItemRow(
                                    item: $item,
                                    focusedItem: $focusedItem,
                                    isBulkSelectionEnabled: isBulkSelectionEnabled,
                                    isSelected: selectedItemIDs.contains(item.id),
                                    onSelectionToggle: {
                                        toggleItemSelection(item.id)
                                    },
                                    onNameSubmit: {
                                        handleNameSubmit(for: item.id)
                                    },
                                    onPriceTap: {
                                        guard !isBulkSelectionEnabled else { return }
                                        quantityPickerIndex = nil
                                        pricePickerIndex = items.firstIndex(where: { $0.id == item.id })
                                    },
                                    onQuantityTap: {
                                        guard !isBulkSelectionEnabled else { return }
                                        pricePickerIndex = nil
                                        quantityPickerIndex = items.firstIndex(where: { $0.id == item.id })
                                    }
                                )

                                if isBulkSelectionEnabled {
                                    row
                                } else {
                                    row.contextMenu {
                                        Button(role: .destructive) {
                                            deleteItem(id: item.id)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if !isProcessing && isBulkSelectionEnabled {
                        addItemButton
                    }

                    if !isProcessing && !items.isEmpty {
                        feesSection
                    }
                }
                .padding(24)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if focusedItem == nil {
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(SPLTColor.subtle.opacity(0.9))
                            .frame(height: 1)
                        createBillButton
                            .padding(.horizontal, 24)
                            .padding(.top, 12)
                            .padding(.bottom, 12)
                    }
                    .background(.ultraThinMaterial)
                }
            }
            .overlay(alignment: .bottom) {
                if let pendingUndoSnapshot {
                    UndoDeleteToast(
                        removedCount: pendingUndoSnapshot.count,
                        onUndo: undoLastRemoval
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if focusedItem != nil {
                    keyboardDismissButton
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.9), value: pendingUndoSnapshot?.count)
            .animation(.easeInOut(duration: 0.2), value: focusedItem != nil)
            .sheet(isPresented: Binding(
                get: { quantityPickerIndex != nil },
                set: { if !$0 { quantityPickerIndex = nil } }
            )) {
                if let index = quantityPickerIndex {
                    QuantityPickerView(quantity: $items[index].quantity, name: items[index].name)
                        .presentationDetents([.height(320)])
                }
            }
            .sheet(isPresented: Binding(
                get: { pricePickerIndex != nil },
                set: { if !$0 { pricePickerIndex = nil } }
            )) {
                if let index = pricePickerIndex {
                    PriceEditorView(price: $items[index].price, name: items[index].name, quantity: items[index].quantity)
                        .presentationDetents([.height(280)])
                }
            }
            .sheet(isPresented: $isAddItemSheetPresented) {
                AddItemSheetView { newItem in
                    appendItem(newItem)
                }
                .presentationDetents([.height(360)])
            }
            .sheet(isPresented: Binding(
                get: { editingFeeField != nil },
                set: { if !$0 { editingFeeField = nil } }
            )) {
                if let field = editingFeeField {
                    FeeEditorView(
                        label: {
                            switch field {
                            case .tax: return "Tax"
                            case .gratuity: return "Gratuity"
                            case .otherFees: return "Other fees"
                            }
                        }(),
                        value: Binding(
                            get: {
                                switch field {
                                case .tax: return tax
                                case .gratuity: return gratuity
                                case .otherFees: return otherFees > 0.005 ? otherFees : nil
                                }
                            },
                            set: { newVal in
                                switch field {
                                case .tax: tax = newVal
                                case .gratuity: gratuity = newVal
                                case .otherFees:
                                    let fees = (tax ?? 0) + (gratuity ?? 0) + (newVal ?? 0)
                                    scannedTotal = itemsTotal + fees
                                }
                            }
                        )
                    )
                    .presentationDetents([.height(240)])
                }
            }
            .onChange(of: items) { updatedItems in
                let validIDs = Set(updatedItems.map(\.id))
                selectedItemIDs = selectedItemIDs.intersection(validIDs)
                if updatedItems.isEmpty {
                    isBulkSelectionEnabled = false
                }
            }
            .onDisappear {
                undoDismissTask?.cancel()
            }
        }
    }

    private var keyboardDismissButton: some View {
        Button {
            focusedItem = nil
            hideKeyboard()
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(uiColor: .label))
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }

    private var createBillButton: some View {
        Button {
            submitBill()
        } label: {
            Text("Create bill")
                .font(SPLTType.bodyBold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [SPLTColor.ink, SPLTColor.ink.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(SPLTColor.subtle, lineWidth: 1)
                        )
                )
        }
        .foregroundStyle(SPLTColor.canvas)
        .disabled(items.isEmpty || isProcessing)
        .opacity(items.isEmpty || isProcessing ? 0.6 : 1)
    }

    private var itemsTotal: Double {
        items.reduce(0) { partial, item in
            return partial + (item.price ?? 0)
        }
    }

    private var addItemButton: some View {
        Button {
            focusedItem = nil
            hideKeyboard()
            isAddItemSheetPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                Text("Add item")
                    .font(SPLTType.bodyBold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(SPLTColor.ink)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(SPLTColor.ink.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(SPLTColor.subtle, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var otherFees: Double {
        let knownFees = (tax ?? 0) + (gratuity ?? 0)
        let total = scannedTotal ?? 0
        let remaining = total - itemsTotal - knownFees
        return remaining > 0.005 ? remaining : 0
    }

    private var hasFees: Bool {
        (tax ?? 0) > 0 || (gratuity ?? 0) > 0 || otherFees > 0.005
    }

    @ViewBuilder
    private var feesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isFeeSectionExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "dollarsign.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SPLTColor.ink.opacity(0.55))
                    Text("Taxes & fees")
                        .font(SPLTType.bodyBold)
                        .foregroundStyle(SPLTColor.ink)
                    if !isFeeSectionExpanded && hasFees {
                        Text("•")
                            .font(SPLTType.caption)
                            .foregroundStyle(SPLTColor.ink.opacity(0.35))
                        Text(feesSummaryText)
                            .font(SPLTType.caption)
                            .foregroundStyle(SPLTColor.ink.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SPLTColor.ink.opacity(0.4))
                        .rotationEffect(.degrees(isFeeSectionExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            if isFeeSectionExpanded {
                VStack(spacing: 0) {
                    Divider().overlay(SPLTColor.subtle.opacity(0.7))

                    feeEditRow(
                        label: "Tax",
                        value: tax,
                        field: .tax,
                        onChange: { tax = $0 }
                    )

                    Divider().overlay(SPLTColor.subtle.opacity(0.5)).padding(.horizontal, 12)

                    feeEditRow(
                        label: "Gratuity",
                        value: gratuity,
                        field: .gratuity,
                        onChange: { gratuity = $0 }
                    )

                    if otherFees > 0.005 {
                        Divider().overlay(SPLTColor.subtle.opacity(0.5)).padding(.horizontal, 12)

                        feeEditRow(
                            label: "Other fees",
                            value: otherFees,
                            field: .otherFees,
                            onChange: { newVal in
                                let fees = (tax ?? 0) + (gratuity ?? 0) + (newVal ?? 0)
                                scannedTotal = itemsTotal + fees
                            }
                        )
                    }
                }
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                isFeeSectionExpanded.toggle()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(SPLTColor.ink.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(SPLTColor.subtle, lineWidth: 1)
                )
        )
    }

    private func feeEditRow(
        label: String,
        value: Double?,
        field: FeeField,
        onChange: @escaping (Double?) -> Void
    ) -> some View {
        HStack {
            Text(label)
                .font(SPLTType.body)
                .foregroundStyle(SPLTColor.ink)
            Spacer()
            Button {
                editingFeeField = field
            } label: {
                HStack(spacing: 4) {
                    if let value, value > 0 {
                        Text(currencyText(value))
                            .font(SPLTType.bodyBold)
                            .monospacedDigit()
                            .foregroundStyle(SPLTColor.ink)
                    } else {
                        Text("—")
                            .font(SPLTType.body)
                            .foregroundStyle(SPLTColor.ink.opacity(0.35))
                    }
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SPLTColor.ink.opacity(0.4))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var feesSummaryText: String {
        var parts: [String] = []
        if let t = tax, t > 0 { parts.append("tax \(currencyText(t))") }
        if let g = gratuity, g > 0 { parts.append("tip \(currencyText(g))") }
        if otherFees > 0.005 { parts.append("other \(currencyText(otherFees))") }
        return parts.joined(separator: ", ")
    }

    private var displayedTotal: Double? {
        if let scannedTotal, scannedTotal > 0 {
            return scannedTotal
        }
        return itemsTotal > 0 ? itemsTotal : nil
    }

    private var headerTitle: String {
        let trimmed = merchantName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Review receipt" : trimmed
    }

    private func toggleBulkSelectionMode() {
        if isBulkSelectionEnabled {
            isBulkSelectionEnabled = false
            selectedItemIDs.removeAll()
            return
        }

        focusedItem = nil
        hideKeyboard()
        isBulkSelectionEnabled = true
    }

    private func toggleItemSelection(_ id: UUID) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
    }

    private func handleNameSubmit(for id: UUID) {
        guard !isBulkSelectionEnabled else { return }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }

        let trimmed = items[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
        items[index].name = trimmed

        guard !trimmed.isEmpty else {
            focusedItem = nil
            hideKeyboard()
            return
        }

        if index < items.count - 1 {
            focusedItem = items[index + 1].id
            return
        }

        let newItem = ReceiptItem(name: "", quantity: 1, price: nil)
        appendItem(newItem)
        focusedItem = newItem.id
    }

    private func appendItem(_ item: ReceiptItem) {
        withAnimation(.easeInOut(duration: 0.18)) {
            items.append(item)
        }
    }

    private func submitBill() {
        focusedItem = nil
        dismissUndoToast()
        onSubmit(items)
    }

    private func removeSelectedItems() {
        guard !selectedItemIDs.isEmpty else { return }

        let snapshotEntries = items.enumerated()
            .filter { selectedItemIDs.contains($0.element.id) }
            .map { RemovedItemEntry(item: $0.element, index: $0.offset) }

        guard !snapshotEntries.isEmpty else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            items.removeAll { selectedItemIDs.contains($0.id) }
        }

        selectedItemIDs.removeAll()
        isBulkSelectionEnabled = false
        presentUndoSnapshot(snapshotEntries)
    }

    private func deleteItem(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }

        let removedItem = items[index]
        _ = withAnimation(.easeInOut(duration: 0.2)) {
            items.remove(at: index)
        }

        presentUndoSnapshot([RemovedItemEntry(item: removedItem, index: index)])
    }

    private func presentUndoSnapshot(_ entries: [RemovedItemEntry]) {
        undoDismissTask?.cancel()

        withAnimation(.easeInOut(duration: 0.2)) {
            pendingUndoSnapshot = RemovedItemsSnapshot(entries: entries)
        }

        undoDismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    pendingUndoSnapshot = nil
                }
            }
        }
    }

    private func undoLastRemoval() {
        guard let pendingUndoSnapshot else { return }

        undoDismissTask?.cancel()

        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
            for entry in pendingUndoSnapshot.entries.sorted(by: { $0.index < $1.index }) {
                let safeIndex = max(0, min(entry.index, items.count))
                items.insert(entry.item, at: safeIndex)
            }
            self.pendingUndoSnapshot = nil
        }
    }

    private func dismissUndoToast() {
        undoDismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            pendingUndoSnapshot = nil
        }
    }
}

private struct ReceiptCapturePreviewCard: View {
    let images: [UIImage]
    let isLoading: Bool

    private let previewHeight: CGFloat = 420

    var body: some View {
        TabView {
            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                ZoomableReceiptImage(
                    image: image,
                    isLoading: isLoading
                )
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(maxWidth: .infinity)
        .frame(height: previewHeight)
        .background(Color.black.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(SPLTColor.subtle, lineWidth: 1)
                )
                .shadow(color: SPLTColor.shadow, radius: 16, x: 0, y: 8)
        )
    }
}

private struct ZoomableReceiptImage: View {
    let image: UIImage
    let isLoading: Bool

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isPulsing = false

    var body: some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .opacity(isLoading ? (isPulsing ? 0.45 : 1) : 1)
                .gesture(
                    magnificationGesture(in: proxy.size)
                        .simultaneously(with: dragGesture(in: proxy.size))
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            resetTransform()
                        }
                    }
                )
                .onAppear {
                    isPulsing = isLoading
                }
                .onChange(of: isLoading) { loading in
                    isPulsing = loading
                }
                .animation(
                    isLoading
                        ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.2),
                    value: isPulsing
                )
        }
        .clipped()
        .background(Color.black)
    }

    private func magnificationGesture(in size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let nextScale = min(max(lastScale * value, 1), 6)
                scale = nextScale
                offset = clampedOffset(offset, in: size, scale: nextScale)
            }
            .onEnded { _ in
                if scale <= 1.01 {
                    resetTransform()
                    return
                }

                scale = min(max(scale, 1), 6)
                lastScale = scale
                offset = clampedOffset(offset, in: size, scale: scale)
                lastOffset = offset
            }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                let next = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                offset = clampedOffset(next, in: size, scale: scale)
            }
            .onEnded { _ in
                guard scale > 1 else {
                    resetTransform()
                    return
                }
                lastOffset = offset
            }
    }

    private func clampedOffset(_ proposed: CGSize, in size: CGSize, scale: CGFloat) -> CGSize {
        guard scale > 1 else { return .zero }

        let maxX = ((size.width * scale) - size.width) / 2
        let maxY = ((size.height * scale) - size.height) / 2

        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private func resetTransform() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}

private struct UndoDeleteToast: View {
    let removedCount: Int
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SPLTColor.canvas)

            Text(message)
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.canvas)

            Spacer(minLength: 8)

            Button("Undo") {
                onUndo()
            }
            .font(SPLTType.bodyBold)
            .foregroundStyle(SPLTColor.canvas)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(SPLTColor.canvas.opacity(0.2))
            )
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(SPLTColor.ink.opacity(0.95))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(SPLTColor.canvas.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: SPLTColor.shadow.opacity(0.45), radius: 16, x: 0, y: 8)
        )
    }

    private var message: String {
        if removedCount == 1 {
            return "Item removed"
        }
        return "\(removedCount) items removed"
    }
}

private struct ReceiptSheetHeader: View {
    let title: String
    let itemCount: Int
    let total: Double?
    let isLoading: Bool
    let isBulkSelectionEnabled: Bool
    let selectedCount: Int
    let onBulkToggle: () -> Void
    let onBulkRemove: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                Button {
                    onBulkToggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isBulkSelectionEnabled ? "checkmark.circle.fill" : "slider.horizontal.3")
                            .font(.system(size: 14, weight: .semibold))
                        Text(isBulkSelectionEnabled ? "Done" : "Edit")
                            .font(SPLTType.caption)
                    }
                    .foregroundStyle(SPLTColor.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(SPLTColor.ink.opacity(0.08))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(SPLTColor.subtle, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                if isBulkSelectionEnabled {
                    Button(selectedCount > 0 ? "Remove \(selectedCount)" : "Remove") {
                        onBulkRemove()
                    }
                    .disabled(selectedCount == 0)
                    .font(SPLTType.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(selectedCount > 0 ? Color.red.opacity(0.2) : SPLTColor.ink.opacity(0.06))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(selectedCount > 0 ? Color.red.opacity(0.3) : SPLTColor.subtle, lineWidth: 1)
                            )
                    )
                    .foregroundStyle(selectedCount > 0 ? Color.red : SPLTColor.ink.opacity(0.55))
                }
            }

            VStack(spacing: 2) {
                Text(title)
                    .font(SPLTType.label)
                    .foregroundStyle(SPLTColor.ink.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if isLoading {
                    ReceiptSubtitleLoadingPlaceholder()
                } else {
                    Text("\(itemCount) items • \(totalText)")
                        .font(SPLTType.caption)
                        .foregroundStyle(SPLTColor.ink.opacity(0.62))
                }
            }
        }
        .padding(.top, 2)
    }

    private var totalText: String {
        guard let total, total > 0 else { return "—" }
        return currencyText(total)
    }
}

private struct ReceiptSubtitleLoadingPlaceholder: View {
    var body: some View {
        TimelineView(.animation) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let alpha = 0.45 + (0.55 * ((sin(seconds * (2 * .pi / 1.05)) + 1) / 2))

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(SPLTColor.ink.opacity(0.14))
                    .frame(width: 68, height: 10)

                Circle()
                    .fill(SPLTColor.ink.opacity(0.16))
                    .frame(width: 3, height: 3)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(SPLTColor.ink.opacity(0.14))
                    .frame(width: 54, height: 10)
            }
            .frame(width: 150, alignment: .center)
            .opacity(alpha)
            .accessibilityLabel("Loading receipt summary")
        }
    }
}

private struct ItemRow: View {
    @Binding var item: ReceiptItem
    var focusedItem: FocusState<UUID?>.Binding
    let isBulkSelectionEnabled: Bool
    let isSelected: Bool
    let onSelectionToggle: () -> Void
    let onNameSubmit: () -> Void
    let onPriceTap: () -> Void
    let onQuantityTap: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if isBulkSelectionEnabled {
                Button(action: onSelectionToggle) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isSelected ? SPLTColor.accent : SPLTColor.ink.opacity(0.35))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Item", text: $item.name)
                    .font(SPLTType.bodyBold)
                    .foregroundStyle(SPLTColor.ink)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .disabled(isBulkSelectionEnabled)
                    .focused(focusedItem, equals: item.id)
                    .onTapGesture { focusedItem.wrappedValue = item.id }
                    .onSubmit {
                        onNameSubmit()
                    }

                if isBulkSelectionEnabled {
                    Text("Tap to select items to remove")
                        .font(SPLTType.caption)
                        .foregroundStyle(SPLTColor.ink.opacity(0.5))
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(action: onPriceTap) {
                    Text(priceText)
                        .font(SPLTType.bodyBold)
                        .monospacedDigit()
                        .foregroundStyle(item.price == nil ? SPLTColor.ink.opacity(0.4) : SPLTColor.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(SPLTColor.canvas)
                                .overlay(
                                    Capsule()
                                        .stroke(SPLTColor.subtle, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(isBulkSelectionEnabled)

                Button(action: onQuantityTap) {
                    HStack(spacing: 6) {
                        Text("Qty")
                            .font(SPLTType.caption)
                            .foregroundStyle(SPLTColor.ink.opacity(0.6))
                        Text("\(item.quantity)")
                            .font(SPLTType.bodyBold)
                            .monospacedDigit()
                            .foregroundStyle(SPLTColor.ink)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(SPLTColor.ink.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isBulkSelectionEnabled)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [SPLTColor.canvas, SPLTColor.canvasAccent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(SPLTColor.subtle, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard isBulkSelectionEnabled else { return }
            onSelectionToggle()
        }
    }

    private var priceText: String {
        guard let price = item.price else { return "—" }
        return String(format: "$%.2f", price)
    }
}

private struct QuantityPickerView: View {
    @Binding var quantity: Int
    let name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Quantity for \(name)")
                    .font(SPLTType.bodyBold)
                    .foregroundStyle(SPLTColor.ink)

                Picker("Quantity", selection: $quantity) {
                    ForEach(1...100, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .pickerStyle(.wheel)
            }
            .padding(20)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct PriceEditorView: View {
    @Binding var price: Double?
    let name: String
    let quantity: Int
    @Environment(\.dismiss) private var dismiss
    @State private var priceText: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text("Total price for \(quantity) \(name)")
                        .font(SPLTType.bodyBold)
                        .foregroundStyle(SPLTColor.ink)
                    Text("Match the receipt total price for this item.")
                        .font(SPLTType.caption)
                        .foregroundStyle(SPLTColor.ink.opacity(0.6))
                }

                TextField("$0.00", text: $priceText)
                    .font(SPLTType.title)
                    .multilineTextAlignment(.center)
                    .keyboardType(.decimalPad)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(SPLTColor.canvasAccent)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(SPLTColor.subtle, lineWidth: 1)
                            )
                    )

                Button("Clear price") {
                    price = nil
                    dismiss()
                }
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.6))
            }
            .padding(20)
            .onAppear {
                if let price {
                    priceText = String(format: "%.2f", price)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        let trimmed = priceText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            price = nil
                        } else {
                            let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
                            if let value = Double(normalized) {
                                price = value
                            }
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct FeeEditorView: View {
    let label: String
    @Binding var value: Double?
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text(label)
                        .font(SPLTType.bodyBold)
                        .foregroundStyle(SPLTColor.ink)
                    Text("Enter the \(label.lowercased()) amount from the receipt.")
                        .font(SPLTType.caption)
                        .foregroundStyle(SPLTColor.ink.opacity(0.6))
                }

                TextField("$0.00", text: $text)
                    .font(SPLTType.title)
                    .multilineTextAlignment(.center)
                    .keyboardType(.decimalPad)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(SPLTColor.canvasAccent)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(SPLTColor.subtle, lineWidth: 1)
                            )
                    )

                Button("Clear") {
                    value = nil
                    dismiss()
                }
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.6))
            }
            .padding(20)
            .onAppear {
                if let value, value > 0 {
                    text = String(format: "%.2f", value)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            value = nil
                        } else {
                            let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
                            if let parsed = Double(normalized), parsed >= 0 {
                                value = parsed > 0 ? parsed : nil
                            }
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct AddItemSheetView: View {
    let onAdd: (ReceiptItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var quantity: Int = 1
    @State private var priceText: String = ""
    @State private var isQuantityPickerPresented = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("Item name", text: $name)
                    .font(SPLTType.bodyBold)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)
                    .focused($isNameFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(SPLTColor.canvasAccent)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(SPLTColor.subtle, lineWidth: 1)
                            )
                    )

                HStack(spacing: 12) {
                    Text("Quantity")
                        .font(SPLTType.bodyBold)
                        .foregroundStyle(SPLTColor.ink)
                    Spacer()
                    Button {
                        isQuantityPickerPresented = true
                    } label: {
                        HStack(spacing: 6) {
                            Text("Qty")
                                .font(SPLTType.caption)
                                .foregroundStyle(SPLTColor.ink.opacity(0.6))
                            Text("\(quantity)")
                                .font(SPLTType.bodyBold)
                                .foregroundStyle(SPLTColor.ink)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(SPLTColor.ink.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(SPLTColor.canvasAccent)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(SPLTColor.subtle, lineWidth: 1)
                        )
                )

                TextField("Total price", text: $priceText)
                    .font(SPLTType.bodyBold)
                    .keyboardType(.decimalPad)
                    .submitLabel(.done)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(SPLTColor.canvasAccent)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(SPLTColor.subtle, lineWidth: 1)
                            )
                    )
                    .onSubmit {
                        commit()
                    }
            }
            .padding(20)
            .onAppear {
                isNameFocused = true
            }
            .sheet(isPresented: $isQuantityPickerPresented) {
                QuantityPickerView(
                    quantity: $quantity,
                    name: trimmedName.isEmpty ? "item" : trimmedName
                )
                .presentationDetents([.height(320)])
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        commit()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        guard !trimmedName.isEmpty else { return }
        let price = parsePrice(priceText)
        onAdd(
            ReceiptItem(
                name: trimmedName,
                quantity: max(1, quantity),
                price: price
            )
        )
        dismiss()
    }

    private func parsePrice(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }
}

private struct GlassIconButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SPLTColor.ink)
                .padding(10)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .stroke(SPLTColor.subtle, lineWidth: 1)
                        )
                )
        }
    }
}

private struct GlassIconLabel: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(SPLTColor.ink)
    }
}

private struct EmptyStateView: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 56, height: 56)

            Text(title)
                .font(SPLTType.title)
                .foregroundStyle(SPLTColor.ink)
            Text(detail)
                .font(SPLTType.body)
                .foregroundStyle(SPLTColor.ink.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}

private struct GlassCallout: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(SPLTType.bodyBold)
                    .foregroundStyle(SPLTColor.ink)
                Text(detail)
                    .font(SPLTType.caption)
                    .foregroundStyle(SPLTColor.ink.opacity(0.6))
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(SPLTColor.subtle, lineWidth: 1)
                )
        )
    }
}

private struct ReceiptDottedDivider: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: proxy.size.width, y: 0))
            }
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 4], dashPhase: 2))
            .foregroundStyle(SPLTColor.subtle)
        }
        .frame(height: 1)
        .accessibilityHidden(true)
    }
}

private struct ReceiptPaperCard: View {
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [SPLTColor.canvasAccent, SPLTColor.canvas],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    LinearGradient(
                        colors: [Color.white.opacity(0.5), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                )
        }
        .compositingGroup()
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(SPLTColor.subtle, lineWidth: 1)
        )
        .shadow(color: SPLTColor.shadow, radius: 14, x: 0, y: 8)
    }
}

private struct ReceiptSummaryCard: View {
    let receipt: Receipt
    var showsShareHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Receipt")
                    .font(SPLTType.label)
                    .textCase(.uppercase)
                    .foregroundStyle(SPLTColor.ink.opacity(0.7))
                if receipt.isActive && receipt.settlementPhase != "finalized" {
                    LiveClaimBadge()
                } else if !receipt.isActive {
                    ArchiveReasonBadge(reason: receipt.archivedReason)
                }
                Spacer()
                Text(receipt.date.formatted(date: .abbreviated, time: .shortened))
                    .font(SPLTType.caption)
                    .foregroundStyle(SPLTColor.ink.opacity(0.6))
            }

            ForEach(receipt.items.prefix(3)) { item in
                HStack {
                    Text(item.name)
                        .font(SPLTType.caption)
                    Spacer()
                    Text("x\(item.quantity)")
                        .font(SPLTType.caption)
                        .monospacedDigit()
                }
            }

            if receipt.items.count > 3 {
                Text("+ \(receipt.items.count - 3) more items")
                    .font(SPLTType.caption)
                    .foregroundStyle(SPLTColor.ink.opacity(0.6))
            }

            if showsShareHint, receipt.isActive {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle.portrait")
                    Text("Tap to open live claims")
                }
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.55))
            }

            ReceiptDottedDivider()
                .padding(.vertical, 4)

            HStack {
                HStack(spacing: 6) {
                    Text("\(receipt.items.count)")
                        .font(SPLTType.bodyBold)
                        .foregroundStyle(SPLTColor.ink)
                        .monospacedDigit()
                    Text("items")
                        .font(SPLTType.caption)
                        .foregroundStyle(SPLTColor.ink.opacity(0.6))
                }
                Spacer()
                Text(currencyText(receipt.total))
                    .font(SPLTType.bodyBold)
                    .monospacedDigit()
            }
        }
        .padding(18)
        .background(
            ReceiptPaperCard()
        )
    }
}

private struct LiveClaimBadge: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(SPLTColor.mint)
                .frame(width: 7, height: 7)
                .opacity(pulse ? 0.42 : 1)
                .scaleEffect(pulse ? 1.3 : 0.9)
                .animation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true), value: pulse)
            Text("Live")
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.72))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(SPLTColor.mint.opacity(0.16))
        )
        .onAppear {
            pulse = true
        }
    }
}

private struct ArchiveReasonBadge: View {
    let reason: String?

    var title: String {
        if reason == "auto_settled" {
            return "Settled"
        }
        return "Archived"
    }

    var tint: Color {
        reason == "auto_settled" ? SPLTColor.mint : SPLTColor.subtle
    }

    var body: some View {
        Text(title)
            .font(SPLTType.caption)
            .foregroundStyle(SPLTColor.ink.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.16))
            )
    }
}

private struct ReceiptsBackground: View {
    var body: some View {
        LinearGradient(
            colors: [SPLTColor.canvas, SPLTColor.canvasAccent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct ScanningOverlay: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()

            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: 260, height: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(SPLTColor.subtle, lineWidth: 1)
                    )
                    .overlay(
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [SPLTColor.accent.opacity(0.1), SPLTColor.accent.opacity(0.4), SPLTColor.accent.opacity(0.1)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 6)
                            .offset(y: pulse ? 52 : -52)
                            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    )

                Text("Scanning receipt")
                    .font(SPLTType.bodyBold)
                    .foregroundStyle(SPLTColor.ink)
                Text("Extracting items and totals")
                    .font(SPLTType.caption)
                    .foregroundStyle(SPLTColor.ink.opacity(0.6))
            }
        }
        .onAppear { pulse.toggle() }
    }
}

private let spltCurrencyCode = Locale.current.currencyCode ?? "USD"

private func currencyText(_ value: Double) -> String {
    value.formatted(.currency(code: spltCurrencyCode))
}

private func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

struct Receipt: Identifiable, Hashable, Codable {
    let id: UUID
    let date: Date
    var items: [ReceiptItem]
    var isActive: Bool
    var canManageActions: Bool
    var scannedTotal: Double?
    var scannedSubtotal: Double?
    var scannedTax: Double?
    var scannedGratuity: Double?
    var settlementPhase: String
    var archivedReason: String?
    var shareCode: String?
    var remoteID: String?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        items: [ReceiptItem],
        isActive: Bool = true,
        canManageActions: Bool = true,
        scannedTotal: Double? = nil,
        scannedSubtotal: Double? = nil,
        scannedTax: Double? = nil,
        scannedGratuity: Double? = nil,
        settlementPhase: String = "claiming",
        archivedReason: String? = nil,
        shareCode: String? = nil,
        remoteID: String? = nil
    ) {
        self.id = id
        self.date = date
        self.items = items
        self.isActive = isActive
        self.canManageActions = canManageActions
        self.scannedTotal = scannedTotal
        self.scannedSubtotal = scannedSubtotal
        self.scannedTax = scannedTax
        self.scannedGratuity = scannedGratuity
        self.settlementPhase = settlementPhase
        self.archivedReason = archivedReason
        self.shareCode = shareCode
        self.remoteID = remoteID
    }

    var total: Double {
        if let scannedTotal, scannedTotal > 0 {
            return scannedTotal
        }
        return items.reduce(0) { partial, item in
            return partial + (item.price ?? 0)
        }
    }

    var extraFeesTotal: Double {
        let itemTotal = items.reduce(0) { partial, item in
            partial + (item.price ?? 0)
        }
        if let scannedTotal, scannedTotal > 0 {
            return max(0, scannedTotal - itemTotal)
        }
        return max(0, (scannedTax ?? 0) + (scannedGratuity ?? 0))
    }
}

struct ReceiptItem: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var quantity: Int
    var price: Double?

    init(id: UUID = UUID(), name: String, quantity: Int = 1, price: Double? = nil) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.price = price
    }
}

actor OCRProcessor {
    struct Extraction {
        let items: [ReceiptItem]
        let receiptTotal: Double?
        let subtotal: Double?
        let tax: Double?
        let gratuity: Double?
        let merchantName: String?
    }

    struct LocationHint {
        let latitude: Double
        let longitude: Double
        let horizontalAccuracyMeters: Double?
        let capturedAt: Date
    }

    static let shared = OCRProcessor()
    private static let defaultRemoteProcessingURL = "https://splt.money/process-receipt"
    private static let defaultRemoteProcessingURLFallback = "https://www.splt.money/process-receipt"
    private static let localRemoteProcessingHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
    private static let remoteProcessingEnvKey = "SPLT_RECEIPT_PROCESSING_URL"
    private static let legacyRemoteProcessingEnvKey = "TABBY_RECEIPT_PROCESSING_URL"
    private static let remoteProcessingDefaultsKey = "splt.receiptProcessingURL"
    private static let legacyRemoteProcessingDefaultsKey = "tabby.receiptProcessingURL"
    private static let remoteProcessingInfoPlistKey = "ReceiptProcessingURL"
    private static let locationTimestampFormatter = ISO8601DateFormatter()

    private static let moneyRegex = try! NSRegularExpression(
        pattern: #"(?:\$\s*)?([0-9]{1,6}(?:[.,][0-9]{3})*(?:[.,][0-9]{2}))"#
    )
    private static let leadingQuantityRegex = try! NSRegularExpression(
        pattern: #"^(\d{1,3})\s*[xX]?\s+"#
    )
    private static let timeRegex = try! NSRegularExpression(
        pattern: #"\b\d{1,2}:\d{2}\s?(am|pm)?\b"#,
        options: .caseInsensitive
    )
    private static let dateRegex = try! NSRegularExpression(
        pattern: #"\b(\d{1,4}[/-]\d{1,2}[/-]\d{1,4})\b"#,
        options: .caseInsensitive
    )
    private static let phoneRegex = try! NSRegularExpression(
        pattern: #"\b(?:\+?1[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}\b"#
    )
    private static let addressRegex = try! NSRegularExpression(
        pattern: #"^\d+\s+.*\b(st|street|ave|avenue|rd|road|blvd|boulevard|dr|drive|ln|lane|way|hwy|highway|suite|ste)\b"#,
        options: .caseInsensitive
    )

    func extract(from images: [UIImage], locationHint: LocationHint? = nil) async -> Extraction {
        guard !images.isEmpty else {
            return Extraction(items: [], receiptTotal: nil, subtotal: nil, tax: nil, gratuity: nil, merchantName: nil)
        }

        do {
            let remoteExtraction = try await extractRemotely(from: images, locationHint: locationHint)
            if !remoteExtraction.items.isEmpty {
                return remoteExtraction
            }
            print("[SPLT] Remote receipt processing returned no items. Falling back to local OCR.")
            let localExtraction = extractLocally(from: images)
            if localExtraction.receiptTotal == nil, let remoteTotal = remoteExtraction.receiptTotal, remoteTotal > 0 {
                return Extraction(
                    items: localExtraction.items,
                    receiptTotal: remoteTotal,
                    subtotal: localExtraction.subtotal,
                    tax: localExtraction.tax,
                    gratuity: localExtraction.gratuity,
                    merchantName: remoteExtraction.merchantName
                )
            }
            return localExtraction
        } catch {
            print("[SPLT] Remote receipt processing failed: \(error.localizedDescription). Falling back to local OCR.")
        }

        return extractLocally(from: images)
    }

    func extractItems(from images: [UIImage]) async -> [ReceiptItem] {
        let extraction = await extract(from: images, locationHint: nil)
        return extraction.items
    }

    private func extractRemotely(from images: [UIImage], locationHint: LocationHint?) async throws -> Extraction {
        guard let firstImage = images.first else {
            throw RemoteExtractionError.emptyImageSet
        }

        guard let imageData = firstImage.jpegData(compressionQuality: 0.88) ?? firstImage.pngData() else {
            throw RemoteExtractionError.invalidImageData
        }

        let endpoints = Self.remoteProcessingURLs
        guard !endpoints.isEmpty else {
            throw RemoteExtractionError.invalidURL
        }

        var lastError: Error?
        for endpoint in endpoints {
            do {
                return try await performRemoteExtraction(
                    with: imageData,
                    endpoint: endpoint,
                    locationHint: locationHint
                )
            } catch {
                lastError = error
                print("[SPLT] Receipt endpoint \(endpoint.absoluteString) failed: \(error.localizedDescription)")
            }
        }

        if Self.configuredRemoteProcessingURL() == nil {
            let attempted = Self.remoteProcessingURLs.map(\.absoluteString).joined(separator: ", ")
            print("[SPLT] Tried receipt endpoints: \(attempted)")
#if !targetEnvironment(simulator)
            print("[SPLT] Tip: For on-device local testing, set SPLT_RECEIPT_PROCESSING_URL to http://<your-mac-lan-ip>:3000/process-receipt")
#endif
        }

        throw lastError ?? RemoteExtractionError.invalidURL
    }

    private func performRemoteExtraction(
        with imageData: Data,
        endpoint: URL,
        locationHint: LocationHint?
    ) async throws -> Extraction {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let requestBody = Self.multipartBody(
            boundary: boundary,
            fieldName: "receipt",
            fileName: "receipt.jpg",
            mimeType: "image/jpeg",
            fileData: imageData,
            textFields: Self.locationHintFormFields(from: locationHint)
        )

        let (responseData, response) = try await URLSession.shared.upload(for: request, from: requestBody)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteExtractionError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw RemoteExtractionError.badStatus(
                code: httpResponse.statusCode,
                bodyPreview: Self.responsePreview(from: responseData),
                responseTrace: Self.responseTrace(from: httpResponse, body: responseData)
            )
        }

        let decoder = JSONDecoder()

        if let payload = try? decoder.decode(RemoteExtractionResponse.self, from: responseData) {
            if payload.success, let data = payload.data {
                return Self.extraction(from: data)
            }
            if !payload.success {
                throw RemoteExtractionError.unsuccessfulResponse(
                    message: payload.error ?? Self.responsePreview(from: responseData)
                )
            }
        }

        if let payload = try? decoder.decode(RemoteExtractionPayload.self, from: responseData) {
            return Self.extraction(from: payload)
        }

        throw RemoteExtractionError.invalidPayload(bodyPreview: Self.responsePreview(from: responseData))
    }

    private static var remoteProcessingURLs: [URL] {
        if let configured = configuredRemoteProcessingURL() {
            return [configured]
        }

        var candidates: [URL] = []
        [defaultRemoteProcessingURL, defaultRemoteProcessingURLFallback]
            .compactMap { remoteProcessingURL(from: $0) }
            .forEach { candidates.append($0) }

#if targetEnvironment(simulator)
        ["http://localhost:3000/process-receipt", "http://127.0.0.1:3000/process-receipt", "http://[::1]:3000/process-receipt"]
            .compactMap { remoteProcessingURL(from: $0) }
            .forEach { candidates.append($0) }
#endif

        var seen = Set<String>()
        let filtered = candidates.filter { candidate in
            guard isAllowedRemoteProcessingURL(candidate) else { return false }
            let key = candidate.absoluteString
            if seen.contains(key) {
                return false
            }
            seen.insert(key)
            return true
        }

        if !filtered.isEmpty {
            return filtered
        }

        return []
    }

    private static func configuredRemoteProcessingURL() -> URL? {
        let envSources = [remoteProcessingEnvKey, legacyRemoteProcessingEnvKey]
        for envKey in envSources {
            if let endpoint = ProcessInfo.processInfo.environment[envKey],
               let url = remoteProcessingURL(from: endpoint) {
                if isAllowedRemoteProcessingURL(url) {
                    return url
                }
                print("[SPLT] Ignoring disallowed receipt processing URL from \(envKey): \(url.absoluteString)")
            }
        }

        let defaultsSources = [remoteProcessingDefaultsKey, legacyRemoteProcessingDefaultsKey]
        for defaultsKey in defaultsSources {
            if let endpoint = UserDefaults.standard.string(forKey: defaultsKey),
               let url = remoteProcessingURL(from: endpoint) {
                if isAllowedRemoteProcessingURL(url) {
                    return url
                }
                UserDefaults.standard.removeObject(forKey: defaultsKey)
                print("[SPLT] Cleared disallowed receipt processing URL from UserDefaults: \(url.absoluteString)")
            }
        }

        if let endpoint = Bundle.main.object(forInfoDictionaryKey: remoteProcessingInfoPlistKey) as? String,
           let url = remoteProcessingURL(from: endpoint) {
            if isAllowedRemoteProcessingURL(url) {
                return url
            }
            print("[SPLT] Ignoring disallowed receipt processing URL from Info.plist: \(url.absoluteString)")
        }

        return nil
    }

    private static func remoteProcessingURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else if looksLikeLocalHostWithoutScheme(trimmed) {
            candidate = "http://\(trimmed)"
        } else {
            candidate = "https://\(trimmed)"
        }
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              components.host != nil else {
            return nil
        }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/process-receipt"
        }
        return components.url
    }

    private static func looksLikeLocalHostWithoutScheme(_ value: String) -> Bool {
        let hostWithOptionalPort = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        let host: String = {
            if hostWithOptionalPort.hasPrefix("["),
               let bracketEnd = hostWithOptionalPort.firstIndex(of: "]") {
                return String(hostWithOptionalPort[...bracketEnd])
            }
            return hostWithOptionalPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? hostWithOptionalPort
        }()

        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return false }
        if normalized == "localhost" || normalized == "::1" || normalized == "[::1]" { return true }
        if normalized.hasSuffix(".local") { return true }
        return isIPv4Address(normalized)
    }

    private static func isIPv4Address(_ host: String) -> Bool {
        let octets = host.split(separator: ".")
        guard octets.count == 4 else { return false }

        for octet in octets {
            guard let value = Int(octet), value >= 0, value <= 255 else {
                return false
            }
        }
        return true
    }

    private static func isAllowedRemoteProcessingURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if localRemoteProcessingHosts.contains(host) {
#if targetEnvironment(simulator)
            return true
#else
            return false
#endif
        }
        return true
    }

    private static func extraction(from data: RemoteExtractionPayload) -> Extraction {
        let items = (data.items ?? []).compactMap { item -> ReceiptItem? in
            let cleanedName = cleanItemName(item.name)
            guard !cleanedName.isEmpty else { return nil }
            let quantity = max(1, item.quantity)
            let computedTotal = item.totalPrice > 0
                ? item.totalPrice
                : (item.unitPrice > 0 ? item.unitPrice * Double(quantity) : 0)
            let normalizedPrice = computedTotal > 0 ? computedTotal : nil
            return ReceiptItem(name: cleanedName, quantity: quantity, price: normalizedPrice)
        }

        let normalizedTotal: Double?
        if let total = data.total, total > 0 {
            normalizedTotal = total
        } else {
            normalizedTotal = nil
        }
        let normalizedMerchantName = data.merchantName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let merchantName = (normalizedMerchantName?.isEmpty == false) ? normalizedMerchantName : nil
        return Extraction(
            items: items,
            receiptTotal: normalizedTotal,
            subtotal: data.subtotal,
            tax: data.tax,
            gratuity: data.gratuity,
            merchantName: merchantName
        )
    }

    private static func responsePreview(from data: Data, maxLength: Int = 220) -> String? {
        guard !data.isEmpty else { return nil }
        let decoded = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded, !decoded.isEmpty else {
            return "<\(data.count) bytes binary>"
        }
        if decoded.count <= maxLength {
            return decoded
        }
        let endIndex = decoded.index(decoded.startIndex, offsetBy: maxLength)
        return "\(decoded[..<endIndex])..."
    }

    private static func responseTrace(from response: HTTPURLResponse, body: Data) -> String? {
        var parts: [String] = []
        if let value = response.value(forHTTPHeaderField: "x-request-id"), !value.isEmpty {
            parts.append("x-request-id=\(value)")
        }
        if let value = response.value(forHTTPHeaderField: "x-vercel-id"), !value.isEmpty {
            parts.append("x-vercel-id=\(value)")
        }
        if let value = response.value(forHTTPHeaderField: "cf-ray"), !value.isEmpty {
            parts.append("cf-ray=\(value)")
        }
        if let runId = extractionRunId(from: body) {
            parts.append("runId=\(runId)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func extractionRunId(from data: Data) -> String? {
        guard
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let runId = payload["runId"] as? String,
            !runId.isEmpty
        else {
            return nil
        }
        return runId
    }

    private func extractLocally(from images: [UIImage]) -> Extraction {
        var lines: [String] = []

        for image in images {
            guard let cgImage = image.cgImage else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en_US"]

            let orientation = CGImagePropertyOrientation(image.imageOrientation)
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            try? handler.perform([request])

            let results = (request.results ?? []).sorted { lhs, rhs in
                let lhsY = lhs.boundingBox.midY
                let rhsY = rhs.boundingBox.midY
                if abs(lhsY - rhsY) > 0.015 {
                    return lhsY > rhsY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }

            for observation in results {
                if let candidate = observation.topCandidates(1).first {
                    lines.append(candidate.string)
                }
            }
        }

        let normalizedLines = lines.map(Self.normalizedLine).filter { !$0.isEmpty }
        let parsed = Self.parseItems(from: normalizedLines)
        let items = parsed.isEmpty ? Self.fallbackItems(from: normalizedLines) : parsed
        let receiptTotal = Self.extractReceiptTotal(from: normalizedLines)
        return Extraction(
            items: items,
            receiptTotal: receiptTotal,
            subtotal: nil,
            tax: nil,
            gratuity: nil,
            merchantName: nil
        )
    }

    private static func multipartBody(
        boundary: String,
        fieldName: String,
        fileName: String,
        mimeType: String,
        fileData: Data,
        textFields: [String: String] = [:]
    ) -> Data {
        var body = Data()
        for (name, value) in textFields.sorted(by: { $0.key < $1.key }) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")
        return body
    }

    private static func locationHintFormFields(from hint: LocationHint?) -> [String: String] {
        guard let hint else { return [:] }

        var fields: [String: String] = [:]
        fields["location_hint"] = String(format: "%.6f,%.6f", hint.latitude, hint.longitude)
        fields["location_latitude"] = String(hint.latitude)
        fields["location_longitude"] = String(hint.longitude)
        fields["location_timestamp"] = locationTimestampFormatter.string(from: hint.capturedAt)

        if let accuracy = hint.horizontalAccuracyMeters {
            fields["location_accuracy_meters"] = String(accuracy)
        }

        return fields
    }

    private static func parseItems(from lines: [String]) -> [ReceiptItem] {
        var parsed: [ReceiptItem] = []
        for line in lines {
            guard let item = parseItem(from: line) else { continue }
            parsed.append(item)
        }
        return dedupe(parsed)
    }

    private static func fallbackItems(from lines: [String]) -> [ReceiptItem] {
        let candidates = lines.compactMap { line -> ReceiptItem? in
            let normalized = normalizedLine(line)
            guard !normalized.isEmpty else { return nil }
            guard !looksLikeMetadata(normalized) else { return nil }

            let lower = normalized.lowercased()
            guard !containsNonItemKeyword(lower) else { return nil }

            let matches = moneyMatches(in: normalized)
            var name = normalized
            var price: Double?
            if let match = matches.last {
                price = match.amount
                name = String(normalized[..<match.range.lowerBound])
            }

            let cleanedName = cleanItemName(name)
            guard isLikelyItemName(cleanedName) else { return nil }
            return ReceiptItem(name: cleanedName, quantity: 1, price: price)
        }

        return Array(dedupe(candidates).prefix(12))
    }

    private static func parseItem(from line: String) -> ReceiptItem? {
        let normalized = normalizedLine(line)
        guard normalized.count > 2 else { return nil }
        guard !looksLikeMetadata(normalized) else { return nil }

        let lower = normalized.lowercased()
        guard !containsNonItemKeyword(lower) else { return nil }

        let prices = moneyMatches(in: normalized)
        guard let trailingPrice = prices.last, trailingPrice.amount > 0 else {
            return nil
        }

        var quantity = 1
        var name = String(normalized[..<trailingPrice.range.lowerBound])
        if let qtyMatch = leadingQuantityRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let qtyRange = Range(qtyMatch.range(at: 1), in: name) {
            quantity = max(1, Int(name[qtyRange]) ?? 1)
            if let fullRange = Range(qtyMatch.range(at: 0), in: name) {
                name = String(name[fullRange.upperBound...])
            }
        }

        let cleanedName = cleanItemName(name)
        guard isLikelyItemName(cleanedName) else { return nil }
        return ReceiptItem(name: cleanedName, quantity: quantity, price: trailingPrice.amount)
    }

    private static func extractReceiptTotal(from lines: [String]) -> Double? {
        struct Candidate {
            let amount: Double
            let score: Int
            let index: Int
        }

        var candidates: [Candidate] = []

        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            let amounts = moneyMatches(in: line)
            guard let lastAmount = amounts.last?.amount, lastAmount > 0 else { continue }

            var score = index
            if lower.contains("grand total") {
                score += 140
            } else if lower.contains("amount due") || lower.contains("balance due") || lower.contains("total due") {
                score += 120
            } else if lower.contains("total") {
                score += 90
            }

            if lower.contains("subtotal") { score -= 120 }
            if lower.contains("tax") { score -= 80 }
            if lower.contains("tip") || lower.contains("gratuity") { score -= 80 }
            if lower.contains("discount") || lower.contains("coupon") || lower.contains("savings") { score -= 60 }
            if lower.contains("change") || lower.contains("cash") || lower.contains("tender") { score -= 60 }

            if score > 0 {
                candidates.append(Candidate(amount: lastAmount, score: score, index: index))
            }
        }

        if let best = candidates.max(by: { lhs, rhs in
            if lhs.score == rhs.score {
                if abs(lhs.amount - rhs.amount) < 0.01 {
                    return lhs.index < rhs.index
                }
                return lhs.amount < rhs.amount
            }
            return lhs.score < rhs.score
        }) {
            return best.amount
        }

        let startIndex = max(0, lines.count / 2)
        var fallback: (amount: Double, index: Int)?
        for index in startIndex..<lines.count {
            let line = lines[index]
            let lower = line.lowercased()
            if lower.contains("subtotal") || lower.contains("tax") || lower.contains("tip") ||
                lower.contains("gratuity") || lower.contains("discount") || lower.contains("change") {
                continue
            }
            guard let amount = moneyMatches(in: line).last?.amount else { continue }
            if let existing = fallback {
                if amount >= existing.amount || index > existing.index {
                    fallback = (amount, index)
                }
            } else {
                fallback = (amount, index)
            }
        }

        return fallback?.amount
    }

    private static func moneyMatches(in line: String) -> [(range: Range<String.Index>, amount: Double)] {
        let matches = moneyRegex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: line) else { return nil }
            guard let amount = parseCurrency(String(line[range])) else { return nil }
            return (range, amount)
        }
    }

    private static func parseCurrency(_ raw: String) -> Double? {
        var cleaned = raw
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "'", with: "")
        guard !cleaned.isEmpty else { return nil }

        let hasComma = cleaned.contains(",")
        let hasDot = cleaned.contains(".")
        if hasComma && hasDot {
            let commaIndex = cleaned.lastIndex(of: ",")
            let dotIndex = cleaned.lastIndex(of: ".")
            if let commaIndex, let dotIndex, commaIndex > dotIndex {
                cleaned = cleaned.replacingOccurrences(of: ".", with: "")
                cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            } else {
                cleaned = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if hasComma {
            let parts = cleaned.split(separator: ",")
            if let last = parts.last, last.count == 2 {
                cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            } else {
                cleaned = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if hasDot {
            let parts = cleaned.split(separator: ".")
            if let last = parts.last, last.count != 2 {
                cleaned = cleaned.replacingOccurrences(of: ".", with: "")
            }
        }

        return Double(cleaned)
    }

    private static func normalizedLine(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func cleanItemName(_ line: String) -> String {
        normalizedLine(line)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-•:|_"))
            .replacingOccurrences(of: #"^\W+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsNonItemKeyword(_ lower: String) -> Bool {
        let blocked = [
            "subtotal", "grand total", "total due", "amount due", "balance due", "tax",
            "tip", "gratuity", "change", "cash", "payment", "tender", "visa", "mastercard",
            "amex", "discover", "debit", "credit", "receipt", "invoice", "merchant", "terminal",
            "auth", "approval", "reference", "ref#", "ref #", "order #", "ticket", "table",
            "guest", "server", "cashier", "store", "location", "phone", "tel", "address",
            "www.", ".com", "http", "thank you", "survey", "visit us", "loyalty", "rewards"
        ]
        return blocked.contains { lower.contains($0) }
    }

    private static func looksLikeMetadata(_ line: String) -> Bool {
        if timeRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            return true
        }
        if dateRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            return true
        }
        if phoneRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            return true
        }
        if addressRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            return true
        }

        let lower = line.lowercased()
        if lower.contains("www.") || lower.contains("http") || lower.contains(".com") || lower.contains("@") {
            return true
        }

        if line.range(of: #"^#?\d{4,}$"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    private static func isLikelyItemName(_ name: String) -> Bool {
        let trimmed = cleanItemName(name)
        guard trimmed.count >= 2 else { return false }
        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return false }

        let words = trimmed.split(separator: " ")
        guard words.count <= 8 else { return false }

        let lower = trimmed.lowercased()
        if containsNonItemKeyword(lower) {
            return false
        }
        if lower.contains("street") || lower.contains("avenue") || lower.contains("suite") {
            return false
        }

        return true
    }

    private static func dedupe(_ items: [ReceiptItem]) -> [ReceiptItem] {
        var seen: Set<String> = []
        var deduped: [ReceiptItem] = []
        for item in items {
            let key = "\(item.name.lowercased())|\(item.quantity)|\(item.price ?? -1)"
            if seen.contains(key) { continue }
            seen.insert(key)
            deduped.append(item)
        }
        return deduped
    }

    private struct RemoteExtractionResponse: Decodable {
        let success: Bool
        let runId: String?
        let data: RemoteExtractionPayload?
        let error: String?
    }

    private struct RemoteExtractionPayload: Decodable {
        let merchantName: String?
        let date: String?
        let total: Double?
        let items: [RemoteExtractionItem]?
        let locationName: String?
        let subtotal: Double?
        let tax: Double?
        let gratuity: Double?
    }

    private struct RemoteExtractionItem: Decodable {
        let name: String
        let quantity: Int
        let unitPrice: Double
        let totalPrice: Double
    }

    private enum RemoteExtractionError: LocalizedError {
        case invalidURL
        case emptyImageSet
        case invalidImageData
        case invalidResponse
        case badStatus(code: Int, bodyPreview: String?, responseTrace: String?)
        case unsuccessfulResponse(message: String?)
        case invalidPayload(bodyPreview: String?)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid receipt processing URL."
            case .emptyImageSet:
                return "No receipt image was provided."
            case .invalidImageData:
                return "Receipt image data could not be encoded."
            case .invalidResponse:
                return "Receipt processing returned an invalid HTTP response."
            case .badStatus(let code, let bodyPreview, let responseTrace):
                if let bodyPreview, !bodyPreview.isEmpty {
                    if let responseTrace, !responseTrace.isEmpty {
                        return "Receipt processing failed with HTTP \(code): \(bodyPreview) [\(responseTrace)]"
                    }
                    return "Receipt processing failed with HTTP \(code): \(bodyPreview)"
                }
                if let responseTrace, !responseTrace.isEmpty {
                    return "Receipt processing failed with HTTP \(code). [\(responseTrace)]"
                }
                return "Receipt processing failed with HTTP \(code)."
            case .unsuccessfulResponse(let message):
                if let message, !message.isEmpty {
                    return "Receipt processing returned success=false: \(message)"
                }
                return "Receipt processing returned success=false."
            case .invalidPayload(let bodyPreview):
                if let bodyPreview, !bodyPreview.isEmpty {
                    return "Receipt processing returned an unexpected payload: \(bodyPreview)"
                }
                return "Receipt processing returned an unexpected payload."
            }
        }
    }
}

@MainActor
private final class ReceiptLocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = ReceiptLocationProvider()

    private let manager: CLLocationManager
    private var pendingContinuation: CheckedContinuation<CLLocation?, Never>?
    private var timeoutTask: Task<Void, Never>?

    private override init() {
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        self.manager = manager
        super.init()
        self.manager.delegate = self
    }

    func currentLocation(maxAge: TimeInterval = 300, timeout: TimeInterval = 2.5) async -> CLLocation? {
        if let cached = manager.location, abs(cached.timestamp.timeIntervalSinceNow) <= maxAge {
            return cached
        }

        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            pendingContinuation?.resume(returning: nil)
            pendingContinuation = continuation

            timeoutTask?.cancel()
            timeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.finish(with: nil)
            }

            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(with: locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: nil)
    }

    private func finish(with location: CLLocation?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        pendingContinuation?.resume(returning: location)
        pendingContinuation = nil
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        append(data)
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

private struct DocumentScannerView: UIViewControllerRepresentable {
    var onComplete: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        var onComplete: ([UIImage]) -> Void

        init(onComplete: @escaping ([UIImage]) -> Void) {
            self.onComplete = onComplete
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var images: [UIImage] = []
            for index in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: index))
            }
            controller.dismiss(animated: true) {
                self.onComplete(images)
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            controller.dismiss(animated: true)
        }
    }
}

// MARK: - Receipt Image Cache

enum ReceiptImageCache {
    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("receipt-images", isDirectory: true)
    }

    private static func fileURL(for receiptID: UUID) -> URL {
        cacheDirectory.appendingPathComponent("\(receiptID.uuidString).jpg")
    }

    static func save(_ image: UIImage, for receiptID: UUID) {
        guard let data = image.jpegData(compressionQuality: 0.82) else { return }
        let directory = cacheDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: receiptID))
    }

    static func load(for receiptID: UUID) -> Data? {
        try? Data(contentsOf: fileURL(for: receiptID))
    }

    static func remove(for receiptID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: receiptID))
    }
}

#Preview {
    ContentView()
}
