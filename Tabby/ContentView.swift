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
    @State private var selectedTab = 0

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

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }
                .tag(2)
        }
        .tint(TabbyColor.ink)
        .onReceive(linkRouter.$joinReceiptId) { receiptId in
            guard receiptId != nil else { return }
            selectedTab = 1
        }
        .onAppear {
            if linkRouter.joinReceiptId != nil {
                selectedTab = 1
            }
        }
    }
}

private struct ReceiptsView: View {
    @State private var showScanner = false
    @State private var isProcessing = false
    @State private var showItemsSheet = false
    @State private var receipts: [Receipt] = []
    @State private var draftItems: [ReceiptItem] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var activeShareReceipt: Receipt?
    @State private var isLoadingRemoteReceipts = false

    var body: some View {
        NavigationStack {
            ZStack {
                ReceiptsBackground()
                    .ignoresSafeArea()

                if receipts.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        receiptsHeader
                        Spacer(minLength: 0)
                        if isLoadingRemoteReceipts {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .tint(TabbyColor.ink)
                                Text("Loading shared receipts")
                                    .font(TabbyType.caption)
                                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            EmptyStateView(
                                title: "No active receipt",
                                detail: "Scan a receipt to start splitting.",
                                icon: "doc.text.viewfinder",
                                tint: TabbyColor.accent
                            )
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            receiptsHeader
                            ForEach(receipts) { receipt in
                                Button {
                                    activeShareReceipt = receipt
                                } label: {
                                    ReceiptSummaryCard(receipt: receipt, showsShareHint: true)
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                    }
                }

            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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
                        GlassIconLabel(icon: "doc.viewfinder")
                    }
                    .buttonStyle(.plain)
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScannerView { images in
                    showScanner = false
                    process(images: images)
                }
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
        }
    }

    private var receiptsHeader: some View {
        PageSectionHeader(
            title: "Receipts",
            detail: "Start a new bill or continue an active one."
        )
    }

    private func startScan() {
        guard VNDocumentCameraViewController.isSupported else { return }
        showScanner = true
    }

    private func process(images: [UIImage]) {
        guard !images.isEmpty else { return }
        draftItems = []
        isProcessing = true
        showItemsSheet = true
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
            let alreadyExists = merged.contains { existing in
                existing.items == incoming.items && abs(existing.date.timeIntervalSince(incoming.date)) < 15
            }
            if !alreadyExists {
                merged.append(incoming)
            }
        }

        return merged.sorted { $0.date > $1.date }
    }
}

private struct JoinView: View {
    @EnvironmentObject private var linkRouter: AppLinkRouter
    @State private var code = ""
    @State private var joinRequest: JoinRequest?

    var body: some View {
        NavigationStack {
            ZStack {
                TabbyGradientBackground()
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 16) {
                    joinHeader

                    Spacer(minLength: 0)

                    EmptyStateView(
                        title: "No shared receipt yet",
                        detail: "Enter a 6-digit code from your friend to claim your items.",
                        icon: "qrcode.viewfinder",
                        tint: TabbyColor.mint
                    )

                    joinCodeEntryCard

                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
            }
            .sheet(item: $joinRequest) { request in
                JoinReceiptView(receiptId: request.id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // Reserved for a future quick action on the Join screen.
                    } label: {
                        GlassIconLabel(icon: "qrcode.viewfinder")
                    }
                    .buttonStyle(.plain)
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
            detail: "Scan the host's QR code or enter the share code to claim your items."
        )
    }

    private var joinCodeEntryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter code")
                .font(TabbyType.label)
                .foregroundStyle(TabbyColor.ink.opacity(0.6))
                .textCase(.uppercase)

            TextField("e.g. 123456", text: $code)
                .font(TabbyType.title)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.numberPad)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(TabbyColor.canvasAccent)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(TabbyColor.subtle, lineWidth: 1)
                        )
                )
                .onChange(of: code) { newValue in
                    let digitsOnly = newValue.filter { $0.isNumber }
                    let limited = String(digitsOnly.prefix(6))
                    if limited != newValue {
                        code = limited
                    }
                }

            Text("6-digit code")
                .font(TabbyType.caption)
                .foregroundStyle(TabbyColor.ink.opacity(0.55))

            Button {
                guard code.count == 6 else { return }
                joinRequest = JoinRequest(id: code)
                code = ""
            } label: {
                Text("Join receipt")
                    .font(TabbyType.bodyBold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [TabbyColor.mint, TabbyColor.mint.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(TabbyColor.subtle, lineWidth: 1)
                            )
                    )
                    .foregroundStyle(TabbyColor.canvas)
            }
            .disabled(code.count != 6)
            .opacity(code.count == 6 ? 1 : 0.6)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(TabbyColor.subtle, lineWidth: 1)
                )
        )
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

private struct HistoryView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                ReceiptsBackground()
                    .ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    PageSectionHeader(
                        title: "History",
                        detail: "Review your previous receipts and split sessions."
                    )

                    Spacer()
                    EmptyStateView(
                        title: "Receipt history",
                        detail: "Past receipts will appear here.",
                        icon: "clock",
                        tint: TabbyColor.violet
                    )
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // Reserved for a future quick action on the History screen.
                    } label: {
                        GlassIconLabel(icon: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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

    init(id: UUID = UUID(), date: Date = Date(), items: [ReceiptItem]) {
        self.id = id
        self.date = date
        self.items = items
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
