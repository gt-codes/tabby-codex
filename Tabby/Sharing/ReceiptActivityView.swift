import SwiftUI

struct ReceiptActivityView: View {
    let receipt: Receipt
    var onShareTap: (Receipt) -> Void
    var onReceiptUpdate: (Receipt) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model: ReceiptActivityViewModel
    @State private var didAnimateIn = false

    init(
        receipt: Receipt,
        onShareTap: @escaping (Receipt) -> Void,
        onReceiptUpdate: @escaping (Receipt) -> Void = { _ in }
    ) {
        self.receipt = receipt
        self.onShareTap = onShareTap
        self.onReceiptUpdate = onReceiptUpdate
        _model = StateObject(wrappedValue: ReceiptActivityViewModel(receipt: receipt))
    }

    var body: some View {
        ZStack {
            backgroundLayer

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    switch model.state {
                    case .idle, .loading:
                        loadingState
                    case .error(let message):
                        errorState(message: message)
                    case .ready(let liveState):
                        participantStrip(participants: liveState.participants)
                            .opacity(didAnimateIn ? 1 : 0)
                            .offset(y: didAnimateIn ? 0 : 10)

                        itemList(items: liveState.items)
                            .opacity(didAnimateIn ? 1 : 0)
                            .offset(y: didAnimateIn ? 0 : 16)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Claims")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let shareReceipt = model.shareReceipt {
                        onShareTap(shareReceipt)
                    } else {
                        onShareTap(receipt)
                    }
                } label: {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(TabbyColor.ink)
                }
                .accessibilityLabel("Share receipt")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .ready(let liveState) = model.state {
                claimedTotalBar(total: liveState.claimedTotal)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .opacity(didAnimateIn ? 1 : 0)
                    .offset(y: didAnimateIn ? 0 : 18)
            }
        }
        .sheet(isPresented: $model.isClaimedSheetPresented) {
            claimedItemsSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            if !didAnimateIn {
                withAnimation(.spring(response: 0.46, dampingFraction: 0.84)) {
                    didAnimateIn = true
                }
            }
            await model.start()
        }
        .onDisappear {
            model.stop()
        }
        .onChange(of: model.shareReceipt) { _, updatedReceipt in
            guard let updatedReceipt else { return }
            onReceiptUpdate(updatedReceipt)
        }
    }

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: [TabbyColor.canvas, TabbyColor.canvasAccent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [TabbyColor.accent.opacity(0.24), .clear],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 360
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [TabbyColor.violet.opacity(0.18), .clear],
                center: .bottomLeading,
                startRadius: 30,
                endRadius: 320
            )
            .ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Who's in")
                    .font(TabbyType.display)
                    .foregroundStyle(TabbyColor.ink)

                Text("Live claim board")
                    .font(TabbyType.body)
                    .foregroundStyle(TabbyColor.ink.opacity(0.62))
            }

            Spacer(minLength: 10)

            if let code = liveCode {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TabbyColor.ink.opacity(0.82))
                    Text(code)
                        .font(TabbyType.bodyBold)
                        .tracking(1.2)
                        .monospacedDigit()
                        .foregroundStyle(TabbyColor.ink)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(.thinMaterial)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(TabbyColor.subtle.opacity(0.9), lineWidth: 1)
                        )
                )
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(TabbyColor.ink)
            Text("Loading live receipt")
                .font(TabbyType.caption)
                .foregroundStyle(TabbyColor.ink.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .activityPanel(cornerRadius: 22)
    }

    private func errorState(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(TabbyType.body)
                .foregroundStyle(TabbyColor.ink)

            Button {
                Task {
                    await model.retry()
                }
            } label: {
                Text("Try again")
                    .font(TabbyType.bodyBold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(elevatedButtonFill)
                    )
                    .foregroundStyle(elevatedButtonForeground)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .activityPanel(cornerRadius: 22)
    }

    private func participantStrip(participants: [ReceiptLiveParticipant]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("People")
                    .font(TabbyType.label)
                    .textCase(.uppercase)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))

                Spacer()

                Text("\(participants.count) joined")
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.56))
                    .monospacedDigit()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(participants) { participant in
                        participantToken(participant)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .activityPanel(cornerRadius: 22)
    }

    private func participantToken(_ participant: ReceiptLiveParticipant) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(participant.isCurrentUser ? TabbyColor.accent.opacity(0.18) : TabbyColor.canvas.opacity(0.45))

                Circle()
                    .stroke(participant.isCurrentUser ? TabbyColor.accent : TabbyColor.subtle.opacity(0.95), lineWidth: participant.isCurrentUser ? 2.2 : 1)

                Text(initials(for: participant.name))
                    .font(TabbyType.bodyBold)
                    .foregroundStyle(TabbyColor.ink)

                Circle()
                    .fill(TabbyColor.mint)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(TabbyColor.canvas, lineWidth: 2)
                    )
                    .offset(x: 22, y: 22)
            }
            .frame(width: 64, height: 64)

            Text(participant.isCurrentUser ? "You" : participant.name)
                .font(TabbyType.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(TabbyColor.ink.opacity(0.78))
        }
        .frame(width: 78)
    }

    private func itemList(items: [ReceiptLiveItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Items")
                    .font(TabbyType.label)
                    .textCase(.uppercase)
                    .foregroundStyle(TabbyColor.ink.opacity(0.62))

                Spacer()

                Text("\(items.count) on receipt")
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.56))
                    .monospacedDigit()
            }

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                itemRow(item)
                if index < items.count - 1 {
                    Divider()
                        .overlay(TabbyColor.subtle.opacity(0.95))
                }
            }
        }
        .padding(16)
        .activityPanel(cornerRadius: 22)
    }

    private func itemRow(_ item: ReceiptLiveItem) -> some View {
        let isPending = model.pendingItemKeys.contains(item.id)
        let isClaimable = item.remainingQuantity > 0

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.name)
                    .font(TabbyType.bodyBold)
                    .foregroundStyle(TabbyColor.ink)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    infoChip(
                        text: isClaimable ? "\(item.remainingQuantity) left" : "0 left",
                        tint: isClaimable ? TabbyColor.mint : TabbyColor.subtle
                    )
                    infoChip(text: "qty \(item.quantity)", tint: TabbyColor.subtle)
                }
            }

            Spacer(minLength: 8)

            Button {
                Task {
                    await model.adjustClaim(itemKey: item.id, delta: 1)
                }
            } label: {
                Group {
                    if isPending {
                        ProgressView()
                            .tint(elevatedButtonForeground)
                    } else {
                        Text(isClaimable ? "Claim" : "Full")
                            .font(TabbyType.bodyBold)
                    }
                }
                .frame(minWidth: 90)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(isClaimable ? elevatedButtonFill : mutedButtonFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(TabbyColor.subtle.opacity(isClaimable ? 0.2 : 0.1), lineWidth: 1)
                        )
                )
                .foregroundStyle(isClaimable ? elevatedButtonForeground : mutedButtonForeground)
            }
            .buttonStyle(.plain)
            .disabled(!isClaimable || isPending)
        }
        .padding(.vertical, 4)
    }

    private func infoChip(text: String, tint: Color) -> some View {
        Text(text)
            .font(TabbyType.caption)
            .foregroundStyle(TabbyColor.ink.opacity(0.74))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.16))
            )
    }

    private func claimedTotalBar(total: Double) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Claimed total")
                        .font(TabbyType.caption)
                        .foregroundStyle(TabbyColor.ink.opacity(0.58))
                    if claimedItemCount > 0 {
                        Text("•")
                            .font(TabbyType.caption)
                            .foregroundStyle(TabbyColor.ink.opacity(0.4))
                        Text("\(claimedItemCount) item\(claimedItemCount == 1 ? "" : "s")")
                            .font(TabbyType.caption)
                            .foregroundStyle(TabbyColor.ink.opacity(0.52))
                            .monospacedDigit()
                    }
                }

                Text(activityCurrencyText(total))
                    .font(TabbyType.hero)
                    .foregroundStyle(TabbyColor.ink)
                    .monospacedDigit()
            }

            Spacer()

            Button {
                model.isClaimedSheetPresented = true
            } label: {
                Label("List", systemImage: "list.bullet.rectangle.portrait")
                    .font(TabbyType.bodyBold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(elevatedButtonFill)
                    )
                    .foregroundStyle(elevatedButtonForeground)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(TabbyColor.subtle.opacity(0.95), lineWidth: 1)
                )
                .shadow(color: TabbyColor.shadow.opacity(0.6), radius: 14, x: 0, y: 6)
        )
    }

    private var claimedItemsSheet: some View {
        NavigationStack {
            Group {
                if case .ready(let liveState) = model.state {
                    let claimedItems = liveState.items.filter { $0.viewerClaimedQuantity > 0 }

                    if claimedItems.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(TabbyColor.ink.opacity(0.45))
                            Text("No claimed items yet")
                                .font(TabbyType.body)
                                .foregroundStyle(TabbyColor.ink.opacity(0.62))
                            Text("Claim from the main list to edit quantities here.")
                                .font(TabbyType.caption)
                                .foregroundStyle(TabbyColor.ink.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(claimedItems) { item in
                                HStack(spacing: 14) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name)
                                            .font(TabbyType.bodyBold)
                                            .foregroundStyle(TabbyColor.ink)

                                        Text(activityCurrencyText(item.viewerClaimedTotal))
                                            .font(TabbyType.caption)
                                            .foregroundStyle(TabbyColor.ink.opacity(0.58))
                                            .monospacedDigit()
                                    }

                                    Spacer()

                                    HStack(spacing: 10) {
                                        quantityButton(symbol: "minus", enabled: item.viewerClaimedQuantity > 0) {
                                            Task {
                                                await model.adjustClaim(itemKey: item.id, delta: -1)
                                            }
                                        }

                                        Text("\(item.viewerClaimedQuantity)")
                                            .font(TabbyType.bodyBold)
                                            .frame(minWidth: 24)
                                            .monospacedDigit()

                                        quantityButton(symbol: "plus", enabled: item.remainingQuantity > 0) {
                                            Task {
                                                await model.adjustClaim(itemKey: item.id, delta: 1)
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 6)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                } else {
                    loadingState
                        .padding(.horizontal, 20)
                }
            }
            .navigationTitle("Your claims")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func quantityButton(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(enabled ? TabbyColor.ink : TabbyColor.ink.opacity(0.15))
                )
                .foregroundStyle(enabled ? TabbyColor.canvas : TabbyColor.ink.opacity(0.42))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var liveCode: String? {
        switch model.state {
        case .ready(let state):
            return state.code
        case .idle, .loading, .error:
            return model.shareReceipt?.shareCode
        }
    }

    private var claimedItemCount: Int {
        switch model.state {
        case .ready(let state):
            return state.items.reduce(0) { partial, item in
                partial + item.viewerClaimedQuantity
            }
        case .idle, .loading, .error:
            return 0
        }
    }

    private var elevatedButtonFill: Color {
        colorScheme == .dark ? .white : TabbyColor.ink
    }

    private var elevatedButtonForeground: Color {
        colorScheme == .dark ? Color.black.opacity(0.85) : TabbyColor.canvas
    }

    private var mutedButtonFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.15) : TabbyColor.ink.opacity(0.12)
    }

    private var mutedButtonForeground: Color {
        colorScheme == .dark ? Color.white.opacity(0.42) : TabbyColor.ink.opacity(0.38)
    }

    private func initials(for name: String) -> String {
        let components = name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }

        if components.isEmpty {
            return "?"
        }

        return String(components).uppercased()
    }
}

private struct ActivityPanelModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(TabbyColor.subtle.opacity(0.9), lineWidth: 1)
                    )
            )
    }
}

private extension View {
    func activityPanel(cornerRadius: CGFloat = 20) -> some View {
        modifier(ActivityPanelModifier(cornerRadius: cornerRadius))
    }
}

@MainActor
final class ReceiptActivityViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case ready(ReceiptLiveState)
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var shareReceipt: Receipt?
    @Published var isClaimedSheetPresented = false
    @Published var pendingItemKeys: Set<String> = []

    private let seedReceipt: Receipt
    private var subscriptionTask: Task<Void, Never>?

    init(receipt: Receipt) {
        seedReceipt = receipt
        shareReceipt = receipt
    }

    deinit {
        subscriptionTask?.cancel()
    }

    func start() async {
        guard subscriptionTask == nil else { return }

        state = .loading

        do {
            let code = try await ensureShareCode()
            _ = try await ConvexService.shared.joinReceipt(withCode: code)
            subscribeToLiveReceipt(withCode: code)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func retry() async {
        stop()
        await start()
    }

    func stop() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    func adjustClaim(itemKey: String, delta: Int) async {
        guard delta != 0 else { return }
        guard !pendingItemKeys.contains(itemKey) else { return }
        guard let code = activeCode else { return }

        pendingItemKeys.insert(itemKey)
        defer {
            pendingItemKeys.remove(itemKey)
        }

        do {
            try await ConvexService.shared.updateClaim(receiptCode: code, itemKey: itemKey, delta: delta)
        } catch {
            print("[Tabby] Failed to update claim: \(error)")
        }
    }

    private var activeCode: String? {
        switch state {
        case .ready(let liveState):
            return liveState.code
        case .idle, .loading, .error:
            return shareReceipt?.shareCode
        }
    }

    private func ensureShareCode() async throws -> String {
        if let existingCode = shareReceipt?.shareCode?.filter(\.isNumber), existingCode.count == 6 {
            return existingCode
        }

        let response = try await ConvexService.shared.createReceiptShare(seedReceipt)
        let code = response.code.filter(\.isNumber)
        guard code.count == 6 else {
            throw ReceiptShareError.invalidShareCode
        }

        shareReceipt = Receipt(
            id: seedReceipt.id,
            date: seedReceipt.date,
            items: seedReceipt.items,
            isActive: seedReceipt.isActive,
            shareCode: code,
            remoteID: response.id
        )

        return code
    }

    private func subscribeToLiveReceipt(withCode code: String) {
        subscriptionTask = Task { [weak self] in
            guard let self else { return }

            do {
                for try await payload in ConvexService.shared.observeReceiptLive(receiptCode: code) {
                    guard !Task.isCancelled else { return }

                    guard let payload else {
                        await MainActor.run {
                            self.state = .error("This receipt is no longer active.")
                        }
                        return
                    }

                    let updatedReceipt = Receipt(
                        id: self.shareReceipt?.id ?? self.seedReceipt.id,
                        date: self.shareReceipt?.date ?? self.seedReceipt.date,
                        items: self.shareReceipt?.items ?? self.seedReceipt.items,
                        isActive: payload.isActive,
                        shareCode: payload.code,
                        remoteID: payload.remoteId
                    )

                    await MainActor.run {
                        self.shareReceipt = updatedReceipt
                        self.state = .ready(payload)
                    }
                }
            } catch {
                await MainActor.run {
                    if !Task.isCancelled {
                        self.state = .error(error.localizedDescription)
                    }
                }
            }

            await MainActor.run {
                self.subscriptionTask = nil
            }
        }
    }
}

private let receiptActivityCurrencyCode = Locale.current.currency?.identifier ?? "USD"

private func activityCurrencyText(_ value: Double) -> String {
    value.formatted(.currency(code: receiptActivityCurrencyCode))
}
