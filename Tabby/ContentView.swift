import AVFoundation
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
        .tint(TabbyColor.ink)
        .onReceive(linkRouter.$joinReceiptId) { receiptId in
            guard receiptId != nil else { return }
            selectedTab = 1
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
                selectedTab = 1
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
                        tint: TabbyColor.accent
                    )

                    Button(action: onSignInTap) {
                        HStack(spacing: 8) {
                            Image(systemName: "apple.logo")
                            Text("Sign in with Apple")
                        }
                        .font(TabbyType.bodyBold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(TabbyColor.ink)
                        )
                        .foregroundStyle(TabbyColor.canvas)
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
                .fill(TabbyColor.ink.opacity(0.18))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            Text("Sign in to sync this device")
                .font(TabbyType.title)
                .foregroundStyle(TabbyColor.ink)

            Text("After sign in, we migrate guest receipts from this device into your Apple account.")
                .font(TabbyType.caption)
                .foregroundStyle(TabbyColor.ink.opacity(0.62))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            Button(action: handlePrimaryAction) {
                HStack(spacing: 8) {
                    if isBusy {
                        ProgressView()
                            .tint(TabbyColor.canvas)
                    } else {
                        Image(systemName: "apple.logo")
                    }
                    Text(primaryActionTitle)
                }
                .font(TabbyType.bodyBold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(TabbyColor.ink)
                )
                .foregroundStyle(TabbyColor.canvas)
            }
            .disabled(isBusy)

            if let errorMessage {
                Text(errorMessage)
                    .font(TabbyType.caption)
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
                colors: [TabbyColor.canvas, TabbyColor.canvasAccent],
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
            Task { await migrateGuestReceipts() }
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

        await migrateGuestReceipts()
    }

    @MainActor
    private func migrateGuestReceipts() async {
        do {
            let migratedCount = try await ConvexService.shared.migrateGuestDataToSignedInAccount()
            print("[Tabby] Migrated \(migratedCount) guest receipts to signed-in account")
            isBusy = false
            dismiss()
        } catch {
            errorMessage = "Signed in, but couldn't migrate guest receipts yet. Try again."
            isBusy = false
        }
    }
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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var permissionCenter = PermissionCenter()
    @AppStorage("shouldShowCameraPermissionNudge") private var shouldShowCameraPermissionNudge = false
    @AppStorage("useLocationForReceiptCapture") private var useLocationForReceiptCapture = true
    @State private var showScanner = false
    @State private var isProcessing = false
    @State private var showItemsSheet = false
    @State private var receipts: [Receipt] = []
    @State private var draftItems: [ReceiptItem] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var activeShareReceipt: Receipt?
    @State private var isLoadingRemoteReceipts = false
    @State private var showCameraPermissionSheet = false
    @State private var pendingScanAfterPermission = false
    @State private var selectedFilter: ReceiptFilter = .active

    var body: some View {
        NavigationStack {
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
            .sheet(isPresented: $showItemsSheet) {
                ItemsSheetView(items: $draftItems, isProcessing: isProcessing) { submittedItems in
                    submitReceipt(items: submittedItems)
                }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $activeShareReceipt) { receipt in
                ShareReceiptView(receipt: receipt)
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
                await loadRemoteReceipts()
            }
            .onAppear {
                maybeShowCameraPermissionNudgeIfNeeded()
            }
            .onChange(of: isSignedIn) { _ in
                Task {
                    await loadRemoteReceipts()
                }
            }
            .onChange(of: scenePhase) { newPhase in
                guard newPhase == .active else { return }
                permissionCenter.refreshStatuses()
                continuePendingScanIfPossible()
            }
            .onChange(of: permissionCenter.cameraStatus) { _ in
                continuePendingScanIfPossible()
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
                .tag(ReceiptFilter.active)

            receiptPane(for: .archived)
                .tag(ReceiptFilter.archived)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func receiptPane(for filter: ReceiptFilter) -> some View {
        let paneReceipts = receipts(for: filter)

        if paneReceipts.isEmpty {
            if isLoadingRemoteReceipts && receipts.isEmpty {
                loadingState
            } else {
                emptyState(for: filter)
            }
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(paneReceipts) { receipt in
                        Button {
                            activeShareReceipt = receipt
                        } label: {
                            ReceiptSummaryCard(receipt: receipt, showsShareHint: true)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            ProgressView()
                .tint(TabbyColor.ink)
            Text("Loading shared receipts")
                .font(TabbyType.caption)
                .foregroundStyle(TabbyColor.ink.opacity(0.6))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var receiptActionsMenu: some View {
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
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func emptyState(for filter: ReceiptFilter) -> some View {
        VStack {
            Spacer(minLength: 0)
            switch filter {
            case .active:
                EmptyStateView(
                    title: "No active receipt",
                    detail: "Scan a receipt to start splitting.",
                    icon: "doc.text.viewfinder",
                    tint: TabbyColor.accent
                )
            case .archived:
                EmptyStateView(
                    title: "No archived receipts",
                    detail: "Archived receipts will show up here.",
                    icon: "archivebox",
                    tint: TabbyColor.violet
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
        isProcessing = true
        showItemsSheet = true
        maybeRequestLocationPermissionForReceiptCapture()
        Task {
            let items = await OCRProcessor.shared.extractItems(from: images)
            await MainActor.run {
                draftItems = items
                isProcessing = false
            }
        }
    }

    private func submitReceipt(items: [ReceiptItem]) {
        guard !items.isEmpty else { return }
        let newReceipt = Receipt(items: items)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            receipts.insert(newReceipt, at: 0)
        }
        draftItems = []
        showItemsSheet = false
        activeShareReceipt = newReceipt
    }

    private func maybeRequestLocationPermissionForReceiptCapture() {
        guard useLocationForReceiptCapture else { return }
        permissionCenter.refreshStatuses()
        permissionCenter.requestLocation()
    }

    private func loadRemoteReceipts() async {
        await MainActor.run { isLoadingRemoteReceipts = true }

        do {
            let remoteReceipts = try await ConvexService.shared.fetchRecentReceipts(limit: 30)
            print("[Tabby] Fetched \(remoteReceipts.count) remote receipts")
            if !remoteReceipts.isEmpty {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        receipts = mergeReceipts(local: receipts, remote: remoteReceipts)
                    }
                }
            }
        } catch {
            print("[Tabby] Failed to fetch remote receipts: \(error)")
        }

        await MainActor.run { isLoadingRemoteReceipts = false }
    }

    private func mergeReceipts(local: [Receipt], remote: [Receipt]) -> [Receipt] {
        var merged = local

        for incoming in remote {
            if let exactMatchIndex = merged.firstIndex(where: { $0.id == incoming.id }) {
                merged[exactMatchIndex] = incoming
                continue
            }

            if let fuzzyMatchIndex = merged.firstIndex(where: { existing in
                existing.items == incoming.items && abs(existing.date.timeIntervalSince(incoming.date)) < 15
            }) {
                merged[fuzzyMatchIndex] = incoming
                continue
            }

            merged.append(incoming)
        }

        return merged.sorted { $0.date > $1.date }
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
            return "Tabby only asks for camera when you scan receipts. Open Settings to allow access."
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
                .fill(TabbyColor.ink.opacity(0.18))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            ZStack {
                Circle()
                    .fill(TabbyColor.accent.opacity(0.16))
                    .frame(width: 64, height: 64)
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(TabbyColor.accent)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(TabbyType.title)
                    .foregroundStyle(TabbyColor.ink)
                Text(detail)
                    .font(TabbyType.body)
                    .foregroundStyle(TabbyColor.ink.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 8)

            VStack(spacing: 8) {
                Button(actionTitle) {
                    onEnable()
                }
                .font(TabbyType.bodyBold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(TabbyColor.ink)
                )
                .foregroundStyle(TabbyColor.canvas)

                Button("Not now") {
                    onLater()
                }
                .font(TabbyType.caption)
                .foregroundStyle(TabbyColor.ink.opacity(0.55))
            }
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [TabbyColor.canvas, TabbyColor.canvasAccent],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct JoinView: View {
    @EnvironmentObject private var linkRouter: AppLinkRouter
    @State private var code = ""
    @State private var joinRequest: JoinRequest?
    @FocusState private var isCodeFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                TabbyGradientBackground()
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 24) {
                    joinHeader
                    joinCodeEntryCard
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
            }
            .sheet(item: $joinRequest) { request in
                JoinReceiptView(receiptId: request.id)
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
            .onReceive(linkRouter.$joinReceiptId) { receiptId in
                guard receiptId != nil else { return }
                consumePendingJoinCode()
            }
            .onAppear {
                consumePendingJoinCode()
            }
        }
    }

    private var joinHeader: some View {
        PageSectionHeader(
            title: "Join",
            detail: "Enter the 6-digit share code to claim your items."
        )
    }

    private var joinCodeEntryCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Share code")
                .font(TabbyType.label)
                .foregroundStyle(TabbyColor.ink.opacity(0.6))
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
                        .fill(TabbyColor.canvas)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(code.isEmpty ? TabbyColor.subtle : TabbyColor.accent.opacity(0.38), lineWidth: 1)
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
                .font(TabbyType.caption)
                .foregroundStyle(TabbyColor.ink.opacity(0.55))

            Button(action: joinWithCodeIfValid) {
                Text("Join receipt")
                    .font(TabbyType.bodyBold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(code.count == 6 ? TabbyColor.ink : TabbyColor.ink.opacity(0.18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(TabbyColor.subtle, lineWidth: 1)
                            )
                    )
                    .foregroundStyle(code.count == 6 ? TabbyColor.canvas : TabbyColor.ink.opacity(0.45))
            }
            .disabled(code.count != 6)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(TabbyColor.canvas.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(TabbyColor.subtle, lineWidth: 1)
                )
        )
    }

    private func joinWithCodeIfValid() {
        guard code.count == 6 else { return }
        isCodeFieldFocused = false
        hideKeyboard()
        joinRequest = JoinRequest(id: code)
        code = ""
    }

    private func consumePendingJoinCode() {
        guard let receiptId = linkRouter.joinReceiptId else { return }
        joinRequest = JoinRequest(id: receiptId)
        linkRouter.joinReceiptId = nil
    }
}

private struct JoinRequest: Identifiable {
    let id: String
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
    case appleCash = "apple_cash"
    case venmo = "venmo"
    case cashApp = "cash_app"
    case zelle = "zelle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleCash:
            return "Apple Cash"
        case .venmo:
            return "Venmo"
        case .cashApp:
            return "Cash App"
        case .zelle:
            return "Zelle"
        }
    }

    var symbol: String {
        switch self {
        case .appleCash:
            return "apple.logo"
        case .venmo:
            return "v.circle.fill"
        case .cashApp:
            return "c.square.fill"
        case .zelle:
            return "z.square.fill"
        }
    }
}

private struct ProfileView: View {
    @AppStorage("profileDisplayName") private var displayName = ""
    @AppStorage("profilePreferredPaymentMethod") private var preferredPaymentMethodRaw = PreferredPaymentMethod.appleCash.rawValue
    @AppStorage("appTheme") private var appThemeRaw = AppThemeOption.auto.rawValue
    @AppStorage("useLocationForReceiptCapture") private var useLocationForReceiptCapture = true
    @AppStorage("isSignedIn") private var isSignedIn = ConvexService.shared.hasCachedSession

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var profileImage: UIImage?
    @State private var accountEmail: String?
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var lastSyncedDisplayName = ""

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
                PaymentAndShippingView(
                    preferredPaymentMethodRaw: $preferredPaymentMethodRaw,
                    onSavePreferredPaymentMethod: {
                        Task { await savePreferredPaymentMethod() }
                    }
                )
            } label: {
                settingsRow(title: "Payment & Shipping", systemImage: "creditcard")
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
                .tint(TabbyColor.mint)
        } header: {
            Text("Receipt capture")
        } footer: {
            Text("When enabled, Tabby can use location permission during receipt capture to help match nearby merchant names.")
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
                    .font(TabbyType.caption)
                    .foregroundStyle(Color.red.opacity(0.9))
            }
        }
    }

    private func refreshProfile() async {
        profileImage = ProfilePhotoStore.loadImage()
        do {
            let profile = try await ConvexService.shared.fetchMyProfile()
            let remoteImage = await ProfilePhotoStore.loadImage(fromRemoteReference: profile?.pictureURL)
            await MainActor.run {
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
                } else {
                    accountEmail = nil
                    lastSyncedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                errorMessage = nil
            }
        } catch {
            await MainActor.run {
                errorMessage = "Couldn't load profile right now."
            }
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

    private func savePreferredPaymentMethod() async {
        guard isSignedIn else { return }
        do {
            try await ConvexService.shared.updateMyProfile(
                name: nil,
                preferredPaymentMethod: preferredPaymentMethodRaw
            )
            await MainActor.run { errorMessage = nil }
        } catch {
            await MainActor.run {
                errorMessage = "Couldn't save preferred payment method."
            }
        }
    }

    private func uploadProfilePhotoIfNeeded(imageData: Data) async {
        guard isSignedIn else { return }
        do {
            try await ConvexService.shared.uploadMyProfilePhoto(imageData)
            await refreshProfile()
            await MainActor.run { errorMessage = nil }
        } catch {
            print("[Tabby] Profile photo upload failed: \(error.localizedDescription)")
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

private struct PaymentAndShippingView: View {
    @Binding var preferredPaymentMethodRaw: String
    let onSavePreferredPaymentMethod: () -> Void

    private var selectedMethod: PreferredPaymentMethod {
        PreferredPaymentMethod(rawValue: preferredPaymentMethodRaw) ?? .appleCash
    }

    var body: some View {
        Form {
            Section {
                ForEach(PreferredPaymentMethod.allCases) { method in
                    Button {
                        guard preferredPaymentMethodRaw != method.rawValue else { return }
                        preferredPaymentMethodRaw = method.rawValue
                        onSavePreferredPaymentMethod()
                    } label: {
                        HStack {
                            Text(method.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            if method == selectedMethod {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Preferred Payment")
            } footer: {
                Text("This is your default suggestion when settling up.")
            }
        }
        .navigationTitle("Payment & Shipping")
        .navigationBarTitleDisplayMode(.inline)
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
                .font(TabbyType.display)
                .foregroundStyle(TabbyColor.ink)
            Text(detail)
                .font(TabbyType.body)
                .foregroundStyle(TabbyColor.ink.opacity(0.65))
        }
    }
}

private struct ItemsSheetView: View {
    @Binding var items: [ReceiptItem]
    let isProcessing: Bool
    var onSubmit: ([ReceiptItem]) -> Void
    @State private var quantityPickerIndex: Int?
    @State private var pricePickerIndex: Int?
    @FocusState private var focusedItem: UUID?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                ReceiptSheetHeader(itemCount: items.count, total: itemsTotal)

                if isProcessing {
                    ReceiptLoadingState()
                } else if items.isEmpty {
                    GlassCallout(
                        title: "No items detected",
                        detail: "Try a clearer photo or adjust lighting. You can also type items manually.",
                        icon: "sparkles",
                        tint: TabbyColor.sun
                    )
                } else {
                    List {
                        ForEach($items) { $item in
                            ItemRow(
                                item: $item,
                                focusedItem: $focusedItem,
                                onPriceTap: {
                                    quantityPickerIndex = nil
                                    pricePickerIndex = items.firstIndex(where: { $0.id == item.id })
                                },
                                onQuantityTap: {
                                    pricePickerIndex = nil
                                    quantityPickerIndex = items.firstIndex(where: { $0.id == item.id })
                                }
                            )
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteItem(id: item.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }

                Button {
                    focusedItem = nil
                    onSubmit(items)
                } label: {
                    Text("Create bill")
                        .font(TabbyType.bodyBold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [TabbyColor.ink, TabbyColor.ink.opacity(0.85)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(TabbyColor.subtle, lineWidth: 1)
                                )
                        )
                }
                .foregroundStyle(TabbyColor.canvas)
                .disabled(items.isEmpty || isProcessing)
                .opacity(items.isEmpty || isProcessing ? 0.6 : 1)
            }
            .padding(24)
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
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        focusedItem = nil
                        hideKeyboard()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
        }
    }

    private var itemsTotal: Double {
        items.reduce(0) { partial, item in
            return partial + (item.price ?? 0)
        }
    }

    private func deleteItem(id: UUID) {
        withAnimation(.easeInOut(duration: 0.2)) {
            items.removeAll { $0.id == id }
        }
    }
}

private struct ReceiptLoadingState: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(height: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(TabbyColor.subtle, lineWidth: 1)
                    )
                    .overlay(
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [TabbyColor.accent.opacity(0.08), TabbyColor.accent.opacity(0.35), TabbyColor.accent.opacity(0.08)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 8)
                            .offset(y: pulse ? 44 : -44)
                            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    )
            }

            VStack(spacing: 6) {
                Text("Scanning receipt")
                    .font(TabbyType.bodyBold)
                    .foregroundStyle(TabbyColor.ink)
                Text("Extracting items and prices")
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .onAppear { pulse.toggle() }
    }
}

private struct ReceiptSheetHeader: View {
    let itemCount: Int
    let total: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(TabbyColor.accent.opacity(0.18))
                    Circle()
                        .stroke(TabbyColor.accent.opacity(0.4), lineWidth: 1)
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(TabbyColor.accent)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Receipt review")
                        .font(TabbyType.title)
                        .foregroundStyle(TabbyColor.ink)
                    Text("Edit items before you submit the bill.")
                        .font(TabbyType.caption)
                        .foregroundStyle(TabbyColor.ink.opacity(0.6))
                }
                Spacer()
            }

            HStack(spacing: 8) {
                ReceiptMetaPill(title: "Items", value: "\(itemCount)", tint: TabbyColor.ink)
                ReceiptMetaPill(title: "Total", value: totalText, tint: TabbyColor.accent)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [TabbyColor.canvasAccent, TabbyColor.canvas],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(TabbyColor.subtle, lineWidth: 1)
                )
                .shadow(color: TabbyColor.shadow, radius: 16, x: 0, y: 8)
        )
    }

    private var totalText: String {
        total > 0 ? currencyText(total) : "—"
    }
}

private struct ReceiptMetaPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(TabbyType.label)
                .foregroundStyle(TabbyColor.ink.opacity(0.55))
            Text(value)
                .font(TabbyType.bodyBold)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(TabbyColor.canvas)
                .overlay(
                    Capsule()
                        .stroke(TabbyColor.subtle, lineWidth: 1)
                )
        )
    }
}

private struct ItemRow: View {
    @Binding var item: ReceiptItem
    var focusedItem: FocusState<UUID?>.Binding
    let onPriceTap: () -> Void
    let onQuantityTap: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Item", text: $item.name)
                    .font(TabbyType.bodyBold)
                    .foregroundStyle(TabbyColor.ink)
                    .textInputAutocapitalization(.words)
                    .focused(focusedItem, equals: item.id)
                    .onTapGesture { focusedItem.wrappedValue = item.id }

                Text("Tap price to edit")
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.5))
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 8) {
                Button(action: onPriceTap) {
                    Text(priceText)
                        .font(TabbyType.bodyBold)
                        .foregroundStyle(item.price == nil ? TabbyColor.ink.opacity(0.4) : TabbyColor.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(TabbyColor.canvas)
                                .overlay(
                                    Capsule()
                                        .stroke(TabbyColor.subtle, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)

                Button(action: onQuantityTap) {
                    HStack(spacing: 6) {
                        Text("Qty")
                            .font(TabbyType.caption)
                            .foregroundStyle(TabbyColor.ink.opacity(0.6))
                        Text("\(item.quantity)")
                            .font(TabbyType.bodyBold)
                            .foregroundStyle(TabbyColor.ink)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(TabbyColor.ink.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [TabbyColor.canvas, TabbyColor.canvasAccent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(TabbyColor.subtle, lineWidth: 1)
                )
        )
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
                    .font(TabbyType.bodyBold)
                    .foregroundStyle(TabbyColor.ink)

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
                        .font(TabbyType.bodyBold)
                        .foregroundStyle(TabbyColor.ink)
                    Text("Match the receipt total price for this item.")
                        .font(TabbyType.caption)
                        .foregroundStyle(TabbyColor.ink.opacity(0.6))
                }

                TextField("$0.00", text: $priceText)
                    .font(TabbyType.title)
                    .multilineTextAlignment(.center)
                    .keyboardType(.decimalPad)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(TabbyColor.canvasAccent)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(TabbyColor.subtle, lineWidth: 1)
                            )
                    )

                Button("Clear price") {
                    price = nil
                    dismiss()
                }
                .font(TabbyType.caption)
                .foregroundStyle(TabbyColor.ink.opacity(0.6))
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

private struct GlassIconButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(TabbyColor.ink)
                .padding(10)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .stroke(TabbyColor.subtle, lineWidth: 1)
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
            .foregroundStyle(TabbyColor.ink)
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
                .font(TabbyType.title)
                .foregroundStyle(TabbyColor.ink)
            Text(detail)
                .font(TabbyType.body)
                .foregroundStyle(TabbyColor.ink.opacity(0.6))
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
                    .font(TabbyType.bodyBold)
                    .foregroundStyle(TabbyColor.ink)
                Text(detail)
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(TabbyColor.subtle, lineWidth: 1)
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
            .foregroundStyle(TabbyColor.subtle)
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
                        colors: [TabbyColor.canvasAccent, TabbyColor.canvas],
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
                .stroke(TabbyColor.subtle, lineWidth: 1)
        )
        .shadow(color: TabbyColor.shadow, radius: 14, x: 0, y: 8)
    }
}

private struct ReceiptSummaryCard: View {
    let receipt: Receipt
    var showsShareHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Receipt")
                    .font(TabbyType.label)
                    .textCase(.uppercase)
                    .foregroundStyle(TabbyColor.ink.opacity(0.7))
                Spacer()
                Text(receipt.date.formatted(date: .abbreviated, time: .shortened))
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
            }

            ForEach(receipt.items.prefix(3)) { item in
                HStack {
                    Text(item.name)
                        .font(TabbyType.caption)
                    Spacer()
                    Text("x\(item.quantity)")
                        .font(TabbyType.caption)
                        .monospacedDigit()
                }
            }

            if receipt.items.count > 3 {
                Text("+ \(receipt.items.count - 3) more items")
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
            }

            if showsShareHint {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Tap to reopen sharing")
                }
                .font(TabbyType.caption)
                .foregroundStyle(TabbyColor.ink.opacity(0.55))
            }

            ReceiptDottedDivider()
                .padding(.vertical, 4)

            HStack {
                HStack(spacing: 6) {
                    Text("\(receipt.items.count)")
                        .font(TabbyType.bodyBold)
                        .foregroundStyle(TabbyColor.ink)
                        .monospacedDigit()
                    Text("items")
                        .font(TabbyType.caption)
                        .foregroundStyle(TabbyColor.ink.opacity(0.6))
                }
                Spacer()
                Text(currencyText(receipt.total))
                    .font(TabbyType.bodyBold)
                    .monospacedDigit()
            }
        }
        .padding(18)
        .background(
            ReceiptPaperCard()
        )
    }
}

private struct ReceiptsBackground: View {
    var body: some View {
        LinearGradient(
            colors: [TabbyColor.canvas, TabbyColor.canvasAccent],
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
                            .stroke(TabbyColor.subtle, lineWidth: 1)
                    )
                    .overlay(
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [TabbyColor.accent.opacity(0.1), TabbyColor.accent.opacity(0.4), TabbyColor.accent.opacity(0.1)],
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
                    .font(TabbyType.bodyBold)
                    .foregroundStyle(TabbyColor.ink)
                Text("Extracting items and totals")
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
            }
        }
        .onAppear { pulse.toggle() }
    }
}

private let tabbyCurrencyCode = Locale.current.currencyCode ?? "USD"

private func currencyText(_ value: Double) -> String {
    value.formatted(.currency(code: tabbyCurrencyCode))
}

private func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

struct Receipt: Identifiable, Hashable, Codable {
    let id: UUID
    let date: Date
    var items: [ReceiptItem]
    var isActive: Bool

    init(id: UUID = UUID(), date: Date = Date(), items: [ReceiptItem], isActive: Bool = true) {
        self.id = id
        self.date = date
        self.items = items
        self.isActive = isActive
    }

    var total: Double {
        items.reduce(0) { partial, item in
            return partial + (item.price ?? 0)
        }
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
    static let shared = OCRProcessor()

    func extractItems(from images: [UIImage]) async -> [ReceiptItem] {
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

            let results = request.results ?? []
            for observation in results {
                if let candidate = observation.topCandidates(1).first {
                    lines.append(candidate.string)
                }
            }
        }

        let parsed = Self.parseItems(from: lines)
        if !parsed.isEmpty {
            return parsed
        }
        return Self.fallbackItems(from: lines)
    }

    private static func parseItems(from lines: [String]) -> [ReceiptItem] {
        let ignore = [
            "subtotal", "total", "tax", "tip", "gratuity", "balance", "amount", "change",
            "cash", "visa", "mastercard", "amex", "discover", "debit", "credit",
            "guest", "guests", "party", "table", "server", "order", "check", "ticket",
            "receipt", "invoice", "phone", "address", "register", "terminal", "auth",
            "approval", "ref", "trace", "host", "merchant", "cashier", "store",
            "dine", "takeout", "pickup", "delivery", "seat", "covers"
        ]
        let priceRegex = try? NSRegularExpression(pattern: "(\\d+[\\.,]\\d{2})")
        let qtyRegex = try? NSRegularExpression(pattern: "^(\\d{1,3})\\s*[xX]?\\s+")
        let nonItemRegexes: [NSRegularExpression] = [
            try! NSRegularExpression(pattern: "\\b(\\d{1,2}[:]\\d{2}\\s?(am|pm)?)\\b", options: .caseInsensitive),
            try! NSRegularExpression(pattern: "\\b\\d{2}/\\d{2}/\\d{2,4}\\b", options: .caseInsensitive),
            try! NSRegularExpression(pattern: "\\b\\d{4}-\\d{2}-\\d{2}\\b", options: .caseInsensitive),
            try! NSRegularExpression(pattern: "^#?\\d{4,}$", options: .caseInsensitive)
        ]
        var items: [ReceiptItem] = []

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 2 else { continue }
            let lower = trimmed.lowercased()
            if ignore.contains(where: { lower.contains($0) }) {
                continue
            }
            if nonItemRegexes.contains(where: { $0.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil }) {
                continue
            }

            let normalized = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            var name = normalized
            var price: Double?

            if let matches = priceRegex?.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
               let match = matches.last,
               let priceRange = Range(match.range(at: 1), in: normalized) {
                let priceString = String(normalized[priceRange]).replacingOccurrences(of: ",", with: ".")
                price = Double(priceString)
                name = String(normalized[..<priceRange.lowerBound])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -:$"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            var quantity = 1
            if let qtyMatch = qtyRegex?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
               let qtyRange = Range(qtyMatch.range(at: 1), in: name) {
                quantity = Int(name[qtyRange]) ?? 1
                if let fullRange = Range(qtyMatch.range(at: 0), in: name) {
                    name = String(name[fullRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-•:"))
            if name.isEmpty { continue }
            let hasLetters = name.rangeOfCharacter(from: .letters) != nil
            if !hasLetters && price == nil { continue }

            items.append(ReceiptItem(name: name, quantity: quantity, price: price))
        }

        return items
    }

    private static func fallbackItems(from lines: [String]) -> [ReceiptItem] {
        let ignore = [
            "subtotal", "total", "tax", "tip", "gratuity", "balance", "amount", "change",
            "cash", "visa", "mastercard", "amex", "discover", "debit", "credit",
            "guest", "guests", "party", "table", "server", "order", "check", "ticket",
            "receipt", "invoice", "phone", "address", "register", "terminal", "auth",
            "approval", "ref", "trace", "host", "merchant", "cashier", "store",
            "dine", "takeout", "pickup", "delivery", "seat", "covers"
        ]
        let candidates = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in
                let lower = line.lowercased()
                let hasLetters = line.rangeOfCharacter(from: .letters) != nil
                return hasLetters && !ignore.contains(where: { lower.contains($0) })
            }

        return candidates.prefix(8).map { ReceiptItem(name: $0, quantity: 1, price: nil) }
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

#Preview {
    ContentView()
}
