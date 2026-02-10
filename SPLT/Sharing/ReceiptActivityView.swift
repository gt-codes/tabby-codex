import SwiftUI
import UIKit

struct ReceiptActivityView: View {
    let receipt: Receipt
    var onShareTap: (Receipt) -> Void
    var onReceiptUpdate: (Receipt) -> Void = { _ in }
    var onExitToReceipts: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var notificationManager: NotificationManager
    @StateObject private var model: ReceiptActivityViewModel
    @State private var didAnimateIn = false
    @State private var isSettlementSheetPresented = false
    @State private var isPaymentSheetPresented = false
    @State private var isHostPaymentSheetPresented = false
    @State private var isSettlementFeesExpanded = false
    @State private var hasAutoPresentedPaymentSheet = false
    @State private var hasAutoPresentedHostPaymentSheet = false
    @State private var toastMessage: String?
    @State private var isReceiptImagePresented = false
    @State private var paymentConfirmationPayload: PaymentConfirmationPayload?
    @State private var hasRequestedExitToReceipts = false

    init(
        receipt: Receipt,
        onShareTap: @escaping (Receipt) -> Void,
        onReceiptUpdate: @escaping (Receipt) -> Void = { _ in },
        onExitToReceipts: @escaping () -> Void = {}
    ) {
        self.receipt = receipt
        self.onShareTap = onShareTap
        self.onReceiptUpdate = onReceiptUpdate
        self.onExitToReceipts = onExitToReceipts
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
                        if liveState.viewerRemoved {
                            removedState
                        } else {
                            statusBanner(liveState)
                                .opacity(didAnimateIn ? 1 : 0)
                                .offset(y: didAnimateIn ? 0 : 8)

                            participantStrip(liveState: liveState)
                                .opacity(didAnimateIn ? 1 : 0)
                                .offset(y: didAnimateIn ? 0 : 10)

                            itemList(items: liveState.items, claimsLocked: claimsLocked(in: liveState))
                                .opacity(didAnimateIn ? 1 : 0)
                                .offset(y: didAnimateIn ? 0 : 16)

                            if hasReceiptFeeBreakdown(liveState) {
                                receiptTotalsPanel(liveState)
                                    .opacity(didAnimateIn ? 1 : 0)
                                    .offset(y: didAnimateIn ? 0 : 18)
                            }

                            if isViewerHost(in: liveState), liveState.settlementPhase == "finalized" {
                                hostPaymentsPanel(liveState)
                                    .opacity(didAnimateIn ? 1 : 0)
                                    .offset(y: didAnimateIn ? 0 : 18)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }

            if let toastMessage {
                VStack {
                    Text(toastMessage)
                        .font(SPLTType.caption)
                        .foregroundStyle(SPLTColor.canvas)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(SPLTColor.ink.opacity(0.92))
                        )
                    Spacer()
                }
                .padding(.top, 14)
                .transition(.move(edge: .top).combined(with: .opacity))
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
                        .foregroundStyle(SPLTColor.ink)
                }
                .accessibilityLabel("Share receipt")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .ready(let liveState) = model.state, !liveState.viewerRemoved {
                bottomActionBar(liveState: liveState)
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
        .sheet(isPresented: $isSettlementSheetPresented) {
            if case .ready(let liveState) = model.state {
                settlementPreviewSheet(liveState)
                    .interactiveDismissDisabled(true)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.hidden)
            }
        }
        .sheet(isPresented: $isPaymentSheetPresented) {
            if case .ready(let liveState) = model.state {
                paymentSheet(liveState)
                    .interactiveDismissDisabled(true)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
            }
        }
        .sheet(isPresented: $isHostPaymentSheetPresented) {
            if case .ready(let liveState) = model.state {
                hostPaymentManagementSheet(liveState)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $isReceiptImagePresented) {
            if case .ready(let liveState) = model.state,
               let urlString = liveState.receiptImageUrl,
               let url = URL(string: urlString) {
                receiptImageSheet(url: url)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(item: $paymentConfirmationPayload) { payload in
            if case .ready(let liveState) = model.state {
                hostPaymentConfirmationSheet(payload: payload, liveState: liveState)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
        .onReceive(notificationManager.$pendingPaymentConfirmation) { payload in
            guard let payload else { return }
            guard case .ready(let liveState) = model.state else { return }
            // Only present the confirmation sheet if this notification is for
            // the receipt currently being viewed and the viewer is the host.
            guard liveState.code == payload.receiptCode,
                  isViewerHost(in: liveState) else { return }
            paymentConfirmationPayload = payload
            notificationManager.pendingPaymentConfirmation = nil
        }
        .alert(
            "Action needed",
            isPresented: Binding(
                get: { model.actionErrorMessage != nil },
                set: { newValue in
                    if !newValue {
                        model.actionErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionErrorMessage ?? "")
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
        .onReceive(model.$state) { state in
            synchronizeTransientSheets(for: state)
        }
        .onChange(of: model.shareReceipt) { _, updatedReceipt in
            guard let updatedReceipt else { return }
            onReceiptUpdate(updatedReceipt)
        }
        .onChange(of: model.shouldExitToReceipts) { _, shouldExit in
            guard shouldExit, !hasRequestedExitToReceipts else { return }
            hasRequestedExitToReceipts = true
            isPaymentSheetPresented = false
            isHostPaymentSheetPresented = false
            isSettlementSheetPresented = false
            paymentConfirmationPayload = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000)
                onExitToReceipts()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastMessage)
    }

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: [SPLTColor.canvas, SPLTColor.canvasAccent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [SPLTColor.accent.opacity(0.24), .clear],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 360
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [SPLTColor.violet.opacity(0.18), .clear],
                center: .bottomLeading,
                startRadius: 30,
                endRadius: 320
            )
            .ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Who's in")
                    .font(SPLTType.display)
                    .foregroundStyle(SPLTColor.ink)
            }

            Spacer(minLength: 10)

            if let code = liveCode {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SPLTColor.ink.opacity(0.82))
                    Text(code)
                        .font(SPLTType.bodyBold)
                        .tracking(1.2)
                        .monospacedDigit()
                        .foregroundStyle(SPLTColor.ink)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(.thinMaterial)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(SPLTColor.subtle.opacity(0.9), lineWidth: 1)
                        )
                )
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(SPLTColor.ink)
            Text("Loading live receipt")
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .activityPanel(cornerRadius: 22)
    }

    private func errorState(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(SPLTType.body)
                .foregroundStyle(SPLTColor.ink)

            Button {
                Task {
                    await model.retry()
                }
            } label: {
                Text("Try again")
                    .font(SPLTType.bodyBold)
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

    private var removedState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.slash.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(SPLTColor.ink.opacity(0.45))

            Text("You've been removed")
                .font(SPLTType.title)
                .foregroundStyle(SPLTColor.ink)

            Text("The host removed you from this receipt. Your claimed items have been released.")
                .font(SPLTType.body)
                .foregroundStyle(SPLTColor.ink.opacity(0.62))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .activityPanel(cornerRadius: 22)
    }

    private func statusBanner(_ liveState: ReceiptLiveState) -> some View {
        HStack(spacing: 10) {
            LivePulseDot(size: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle(for: liveState))
                    .font(SPLTType.bodyBold)
                    .foregroundStyle(SPLTColor.ink)
                Text(statusDetail(for: liveState))
                    .font(SPLTType.caption)
                    .foregroundStyle(SPLTColor.ink.opacity(0.58))
            }
            Spacer()
        }
        .padding(14)
        .activityPanel(cornerRadius: 18)
    }

    private func participantStrip(liveState: ReceiptLiveState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("People")
                    .font(SPLTType.label)
                    .textCase(.uppercase)
                    .foregroundStyle(SPLTColor.ink.opacity(0.6))

                Spacer()

                Text("\(liveState.participants.count) joined")
                    .font(SPLTType.caption)
                    .foregroundStyle(SPLTColor.ink.opacity(0.56))
                    .monospacedDigit()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(liveState.participants) { participant in
                        participantToken(participant, liveState: liveState)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .activityPanel(cornerRadius: 22)
    }

    private func participantToken(_ participant: ReceiptLiveParticipant, liveState: ReceiptLiveState) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(participant.isCurrentUser ? SPLTColor.accent.opacity(0.18) : SPLTColor.canvas.opacity(0.45))

                Circle()
                    .stroke(participant.isCurrentUser ? SPLTColor.accent : SPLTColor.subtle.opacity(0.95), lineWidth: participant.isCurrentUser ? 2.2 : 1)

                participantAvatar(for: participant)
            }
            .frame(width: 64, height: 64)
            .overlay(alignment: .bottomTrailing) {
                if let indicator = participantIndicator(for: participant, liveState: liveState) {
                    let badgeColor: Color = {
                        switch indicator {
                        case .paid: return SPLTColor.mint
                        case .pendingPayment: return SPLTColor.sun
                        case .submitted: return SPLTColor.accent
                        }
                    }()
                    let badgeIcon: String = {
                        switch indicator {
                        case .paid: return "banknote.fill"
                        case .pendingPayment: return "clock.fill"
                        case .submitted: return "checkmark"
                        }
                    }()

                    Circle()
                        .fill(badgeColor)
                        .frame(width: 19, height: 19)
                        .overlay(
                            Image(systemName: badgeIcon)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(SPLTColor.canvas)
                        )
                        .shadow(color: SPLTColor.shadow.opacity(0.65), radius: 4, x: 0, y: 2)
                        .offset(x: 2, y: 2)
                }
            }

            Text(participantDisplayName(participant, liveState: liveState))
                .font(SPLTType.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(SPLTColor.ink.opacity(0.78))
        }
        .frame(width: 86)
        .contextMenu {
            if canRemoveParticipant(participant, liveState: liveState) {
                Button(role: .destructive) {
                    Task {
                        await model.removeParticipant(participantKey: participant.id)
                    }
                } label: {
                    Label("Remove participant", systemImage: "person.crop.circle.badge.minus")
                }
            }
        }
    }

    private func itemList(items: [ReceiptLiveItem], claimsLocked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Items")
                    .font(SPLTType.label)
                    .textCase(.uppercase)
                    .foregroundStyle(SPLTColor.ink.opacity(0.62))

                Spacer()

                Text("\(items.count) on receipt")
                    .font(SPLTType.caption)
                    .foregroundStyle(SPLTColor.ink.opacity(0.56))
                    .monospacedDigit()
            }

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                itemRow(item, claimsLocked: claimsLocked)
                if index < items.count - 1 {
                    Divider()
                        .overlay(SPLTColor.subtle.opacity(0.95))
                }
            }
        }
        .padding(16)
        .activityPanel(cornerRadius: 22)
    }

    private func itemRow(_ item: ReceiptLiveItem, claimsLocked: Bool) -> some View {
        let isPending = model.pendingItemKeys.contains(item.id)
        let isClaimable = item.remainingQuantity > 0
        let buttonTitle = claimsLocked ? "Locked" : (isClaimable ? "Claim" : "Full")
        let buttonFill: Color = {
            if claimsLocked { return mutedButtonFill }
            return isClaimable ? elevatedButtonFill : mutedButtonFill
        }()
        let buttonForeground: Color = {
            if claimsLocked { return mutedButtonForeground }
            return isClaimable ? elevatedButtonForeground : mutedButtonForeground
        }()

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.name)
                    .font(SPLTType.bodyBold)
                    .foregroundStyle(SPLTColor.ink)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    infoChip(
                        text: isClaimable ? "\(item.remainingQuantity) left" : "0 left",
                        tint: isClaimable ? SPLTColor.mint : SPLTColor.subtle
                    )
                    infoChip(text: "qty \(item.quantity)", tint: SPLTColor.subtle)
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
                        Text(buttonTitle)
                            .font(SPLTType.bodyBold)
                    }
                }
                .frame(minWidth: 92)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(buttonFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(SPLTColor.subtle.opacity(0.2), lineWidth: 1)
                        )
                )
                .foregroundStyle(buttonForeground)
            }
            .buttonStyle(.plain)
            .disabled(claimsLocked || !isClaimable || isPending)
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.2), value: claimsLocked)
    }

    private func infoChip(text: String, tint: Color) -> some View {
        Text(text)
            .font(SPLTType.caption)
            .foregroundStyle(SPLTColor.ink.opacity(0.74))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.16))
            )
    }

    private func hasReceiptFeeBreakdown(_ liveState: ReceiptLiveState) -> Bool {
        (liveState.tax ?? 0) > 0 || (liveState.gratuity ?? 0) > 0 || (liveState.otherFees ?? 0) > 0
    }

    private func receiptTotalsPanel(_ liveState: ReceiptLiveState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Receipt breakdown")
                    .font(SPLTType.label)
                    .textCase(.uppercase)
                    .foregroundStyle(SPLTColor.ink.opacity(0.52))
                Spacer()
                if liveState.receiptImageUrl != nil {
                    Button {
                        isReceiptImagePresented = true
                    } label: {
                        Image(systemName: "doc.text.image")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(SPLTColor.ink.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }

            let itemsTotal = liveState.items.reduce(0.0) { $0 + ($1.price ?? 0) }

            if itemsTotal > 0 {
                receiptTotalRow(label: "Subtotal", value: itemsTotal)
            }
            if let tax = liveState.tax, tax > 0 {
                receiptTotalRow(label: taxLabel(for: liveState), value: tax)
            }
            if let gratuity = liveState.gratuity, gratuity > 0 {
                if let pct = liveState.gratuityPercent, pct > 0 {
                    let formatted = pct.truncatingRemainder(dividingBy: 1) == 0
                        ? String(format: "%.0f", pct)
                        : String(format: "%.1f", pct)
                    receiptTotalRow(label: "Gratuity (\(formatted)%)", value: gratuity)
                } else {
                    receiptTotalRow(label: "Gratuity", value: gratuity)
                }
            }
            if let otherFees = liveState.otherFees, otherFees > 0.005 {
                receiptTotalRow(label: "Other fees", value: otherFees)
            }
            if liveState.extraFeesTotal > 0 {
                Divider().overlay(SPLTColor.subtle.opacity(0.6))
                receiptTotalRow(label: "Extra fees total", value: liveState.extraFeesTotal, dimmed: false)
            }
        }
        .padding(14)
        .activityPanel(cornerRadius: 18)
    }

    private func receiptTotalRow(label: String, value: Double, dimmed: Bool = true) -> some View {
        HStack {
            Text(label)
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(dimmed ? 0.56 : 0.72))
            Spacer()
            Text(activityCurrencyText(value))
                .font(SPLTType.caption)
                .monospacedDigit()
                .foregroundStyle(SPLTColor.ink.opacity(dimmed ? 0.62 : 0.78))
        }
    }

    private func hostPaymentsPanel(_ liveState: ReceiptLiveState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Payments")
                .font(SPLTType.label)
                .textCase(.uppercase)
                .foregroundStyle(SPLTColor.ink.opacity(0.62))

            // Notification hint
            HStack(spacing: 6) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SPLTColor.ink.opacity(0.4))
                Text("You'll get a notification when someone pays.")
                    .font(SPLTType.caption)
                    .foregroundStyle(SPLTColor.ink.opacity(0.52))
            }

            if liveState.hostPaymentQueue.isEmpty {
                Text("No guest payments pending.")
                    .font(SPLTType.caption)
                    .foregroundStyle(SPLTColor.ink.opacity(0.6))
            } else {
                ForEach(liveState.hostPaymentQueue) { queueItem in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(queueItem.name)
                                .font(SPLTType.bodyBold)
                                .foregroundStyle(SPLTColor.ink)
                            Text(activityCurrencyText(queueItem.amountDue))
                                .font(SPLTType.caption)
                                .foregroundStyle(SPLTColor.ink.opacity(0.58))
                            if let paymentMethod = queueItem.paymentMethod,
                               queueItem.paymentStatus == "pending" {
                                Text("Pending via \(paymentMethod.replacingOccurrences(of: "_", with: " ").capitalized)")
                                    .font(SPLTType.caption)
                                    .foregroundStyle(SPLTColor.ink.opacity(0.5))
                            }
                        }

                        Spacer()

                        switch queueItem.paymentStatus {
                        case "confirmed":
                            Text("Paid")
                                .font(SPLTType.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(SPLTColor.mint.opacity(0.16))
                                )
                        case "pending":
                            Button {
                                Task {
                                    await model.confirmPayment(participantKey: queueItem.id)
                                }
                            } label: {
                                Text("Confirm")
                                    .font(SPLTType.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(elevatedButtonFill)
                                    )
                                    .foregroundStyle(elevatedButtonForeground)
                            }
                            .buttonStyle(.plain)
                        default:
                            Text("Awaiting")
                                .font(SPLTType.caption)
                                .foregroundStyle(SPLTColor.ink.opacity(0.48))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .activityPanel(cornerRadius: 22)
    }

    private func bottomActionBar(liveState: ReceiptLiveState) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Claimed total")
                        .font(SPLTType.caption)
                        .foregroundStyle(SPLTColor.ink.opacity(0.58))
                    if claimedItemCount > 0 {
                        Text("•")
                            .font(SPLTType.caption)
                            .foregroundStyle(SPLTColor.ink.opacity(0.4))
                        Text("\(claimedItemCount) item\(claimedItemCount == 1 ? "" : "s")")
                            .font(SPLTType.caption)
                            .foregroundStyle(SPLTColor.ink.opacity(0.52))
                            .monospacedDigit()
                    }
                }

                Text(activityCurrencyText(liveState.claimedTotal))
                    .font(SPLTType.hero)
                    .foregroundStyle(SPLTColor.ink)
                    .monospacedDigit()
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    handlePrimaryAction(for: liveState)
                } label: {
                    Group {
                        if model.isPrimaryActionPending {
                            ProgressView()
                                .tint(elevatedButtonForeground)
                                .frame(minWidth: 84)
                        } else {
                            Text(primaryActionTitle(for: liveState))
                                .font(SPLTType.bodyBold)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(elevatedButtonFill)
                    )
                    .foregroundStyle(elevatedButtonForeground)
                }
                .buttonStyle(.plain)
                .disabled(isPrimaryActionDisabled(for: liveState))

                Button {
                    model.isClaimedSheetPresented = true
                } label: {
                    Text("Your items")
                        .font(SPLTType.caption)
                        .foregroundStyle(SPLTColor.ink.opacity(0.62))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(SPLTColor.subtle.opacity(0.95), lineWidth: 1)
                )
                .shadow(color: SPLTColor.shadow.opacity(0.6), radius: 14, x: 0, y: 6)
        )
    }

    private func settlementPreviewSheet(_ liveState: ReceiptLiveState) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("What you owe")
                    .font(SPLTType.title)
                    .foregroundStyle(SPLTColor.ink)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)

                if let viewerSettlement = liveState.viewerSettlement {
                    VStack(spacing: 10) {
                        settlementRow(title: "Items", value: viewerSettlement.itemSubtotal)

                        if viewerSettlement.extraFeesShare > 0 {
                            settlementFeeRow(viewerSettlement: viewerSettlement, liveState: liveState)
                        }

                        Divider()
                            .overlay(SPLTColor.subtle.opacity(0.9))
                        settlementRow(title: "Total due", value: viewerSettlement.totalDue, emphasized: true)
                    }
                    .padding(14)
                    .activityPanel(cornerRadius: 16)
                }

                // if let viewerSettlement = liveState.viewerSettlement, viewerSettlement.extraFeesShare > 0 {
                //     Text("Extra fees split proportionally")
                //         .font(SPLTType.caption)
                //         .foregroundStyle(SPLTColor.ink.opacity(0.58))
                // }

                Spacer(minLength: 0)

                // CTAs pinned to bottom with status + helper above
                VStack(spacing: 12) {
                    if isViewerHost(in: liveState) {
                        let blockers = finalizeBlockers(in: liveState)
                        if blockers.isEmpty {
                            HStack(spacing: 8) {
                                LivePulseDot(size: 7)
                                Text("Ready to finalize")
                                    .font(SPLTType.bodyBold)
                                    .foregroundStyle(SPLTColor.mint)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            hostWaitingSummary(liveState)
                        }
                    } else {
                        guestWaitingSummary(liveState)
                    }

                    Text(settlementHelperText(for: liveState))
                        .font(SPLTType.caption)
                        .foregroundStyle(SPLTColor.ink.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    Button {
                        Task {
                            await model.setSubmissionStatus(isSubmitted: false)
                        }
                    } label: {
                        Text("Unsubmit to edit")
                            .font(SPLTType.bodyBold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(elevatedButtonFill)
                            )
                            .foregroundStyle(elevatedButtonForeground)
                    }
                    .buttonStyle(.plain)

                    if shouldShowFinalizeCTA(in: liveState) {
                        Button {
                            handlePrimaryAction(for: liveState)
                        } label: {
                            Text("Finalize split")
                                .font(SPLTType.bodyBold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(canFinalize(in: liveState) ? SPLTColor.ink.opacity(0.1) : SPLTColor.ink.opacity(0.06))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(canFinalize(in: liveState) ? SPLTColor.subtle : SPLTColor.subtle.opacity(0.7), lineWidth: 1)
                                        )
                                )
                                .foregroundStyle(canFinalize(in: liveState) ? SPLTColor.ink : SPLTColor.ink.opacity(0.42))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canFinalize(in: liveState))
                    }
                }
            }
            .padding(20)
            .background(
                LinearGradient(
                    colors: [SPLTColor.canvas, SPLTColor.canvasAccent],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func receiptImageSheet(url: URL) -> some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .tint(SPLTColor.ink.opacity(0.5))
                                .frame(maxWidth: .infinity, minHeight: 300)
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: geometry.size.width)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        case .failure:
                            VStack(spacing: 10) {
                                Image(systemName: "photo.badge.exclamationmark")
                                    .font(.system(size: 28, weight: .medium))
                                    .foregroundStyle(SPLTColor.ink.opacity(0.4))
                                Text("Couldn't load receipt image")
                                    .font(SPLTType.caption)
                                    .foregroundStyle(SPLTColor.ink.opacity(0.5))
                            }
                            .frame(maxWidth: .infinity, minHeight: 200)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .padding(16)
                }
            }
            .background(
                LinearGradient(
                    colors: [SPLTColor.canvas, SPLTColor.canvasAccent],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isReceiptImagePresented = false
                    }
                    .font(SPLTType.bodyBold)
                    .foregroundStyle(SPLTColor.ink)
                }
            }
        }
    }

    @State private var paymentSheetToast: String?
    @State private var isPaymentMethodPickerExpanded = false
    @State private var pendingPaymentMethodOverride: PaymentActionMethod?

    private func paymentSheet(_ liveState: ReceiptLiveState) -> some View {
        let hostLabel = resolvedHostLabel(in: liveState)
        let isPending = liveState.viewerSettlement?.paymentStatus == "pending"
        let isConfirmed = liveState.viewerSettlement?.paymentStatus == "confirmed"
        let selectedMethodRaw = liveState.viewerSettlement?.paymentMethod
        let selectedMethod = selectedMethodRaw.flatMap { PaymentActionMethod(rawValue: $0) }
        let activeSelectedMethod = pendingPaymentMethodOverride ?? selectedMethod
        let methods = paymentActions(for: liveState)
        let visibleMethods = paymentVisibleMethods(
            allMethods: methods,
            isPending: isPending,
            isConfirmed: isConfirmed,
            selectedMethod: activeSelectedMethod
        )

        return NavigationStack {
            ZStack {
                paymentSheetBackground

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        if let viewerSettlement = liveState.viewerSettlement {
                            paymentHeroCard(
                                viewerSettlement: viewerSettlement,
                                hostLabel: hostLabel
                            )
                        }

                        if isConfirmed {
                            paymentFlowBanner(
                                icon: "checkmark.circle.fill",
                                tint: SPLTColor.mint,
                                text: "\(hostLabel.prefix(1).uppercased() + hostLabel.dropFirst()) confirmed your payment."
                            )
                        } else if isPending {
                            paymentFlowBanner(
                                icon: "hourglass",
                                tint: SPLTColor.sun,
                                text: "Waiting for \(hostLabel) to confirm your payment."
                            )
                        } else {
                            paymentFlowBanner(
                                icon: "arrow.down.circle.fill",
                                tint: SPLTColor.ink.opacity(0.56),
                                text: "Choose a method and send the exact amount above."
                            )
                        }

                        paymentItemizedSection(liveState)

                        if !isConfirmed {
                            VStack(spacing: 14) {
                                Text(
                                    isPending && !isPaymentMethodPickerExpanded
                                    ? "Selected payment method"
                                    : "Payment options"
                                )
                                .font(SPLTType.label)
                                .textCase(.uppercase)
                                .tracking(0.9)
                                .foregroundStyle(SPLTColor.ink.opacity(0.52))
                                .frame(maxWidth: .infinity, alignment: .center)

                                VStack(spacing: 10) {
                                    ForEach(methods, id: \.rawValue) { method in
                                        if visibleMethods.contains(method) {
                                            Group {
                                                if method == .cashApplePay {
                                                    cashApplePayOption(
                                                        liveState: liveState,
                                                        isSelected: activeSelectedMethod == .cashApplePay
                                                    )
                                                } else {
                                                    paymentActionButton(
                                                        method: method,
                                                        liveState: liveState,
                                                        isSelected: activeSelectedMethod == method
                                                    )
                                                }
                                            }
                                            .transition(
                                                .asymmetric(
                                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                                    removal: .scale(scale: 0.94, anchor: .top).combined(with: .opacity)
                                                )
                                            )
                                        }
                                    }
                                }
                                .animation(.spring(response: 0.34, dampingFraction: 0.86), value: visibleMethods)

                                if isPending, !isPaymentMethodPickerExpanded, activeSelectedMethod != nil {
                                    Button {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                            isPaymentMethodPickerExpanded = true
                                        }
                                    } label: {
                                        Text("Paying a different way?")
                                            .font(SPLTType.caption)
                                            .foregroundStyle(SPLTColor.ink.opacity(0.62))
                                            .underline()
                                            .frame(maxWidth: .infinity, alignment: .center)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }

                        Spacer().frame(height: 18)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 36)
                }

                if let toast = paymentSheetToast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(SPLTType.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(SPLTColor.ink.opacity(0.88))
                            )
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear {
                if !isPending || isConfirmed {
                    isPaymentMethodPickerExpanded = false
                    pendingPaymentMethodOverride = nil
                }
            }
            .onChange(of: isPending) { _, pending in
                if !pending {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPaymentMethodPickerExpanded = false
                        pendingPaymentMethodOverride = nil
                    }
                }
            }
            .onChange(of: isConfirmed) { _, confirmed in
                if confirmed {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPaymentMethodPickerExpanded = false
                        pendingPaymentMethodOverride = nil
                    }
                }
            }
            .onChange(of: selectedMethodRaw) { _, newRawValue in
                guard let newRawValue,
                      let syncedMethod = PaymentActionMethod(rawValue: newRawValue) else { return }
                if pendingPaymentMethodOverride == syncedMethod {
                    pendingPaymentMethodOverride = nil
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: paymentSheetToast)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var paymentSheetBackground: some View {
        LinearGradient(
            colors: [SPLTColor.canvas, SPLTColor.canvasAccent.opacity(0.55)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func paymentHeroCard(
        viewerSettlement: ReceiptViewerSettlement,
        hostLabel: String
    ) -> some View {
        VStack(spacing: 12) {
            Text("You owe \(hostLabel)")
                .font(SPLTType.title)
                .foregroundStyle(SPLTColor.ink.opacity(0.74))

            Text(activityCurrencyText(viewerSettlement.totalDue))
                .font(.system(size: 56, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(SPLTColor.ink)

            Text("Send this amount to payw your share.")
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.58))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private func paymentFlowBanner(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SPLTColor.ink.opacity(colorScheme == .dark ? 0.11 : 0.035))
        )
    }

    private func paymentVisibleMethods(
        allMethods: [PaymentActionMethod],
        isPending: Bool,
        isConfirmed: Bool,
        selectedMethod: PaymentActionMethod?
    ) -> [PaymentActionMethod] {
        if isConfirmed {
            return []
        }

        guard isPending else {
            return allMethods
        }

        if isPaymentMethodPickerExpanded {
            return allMethods
        }

        guard let selectedMethod else {
            return allMethods
        }

        return allMethods.filter { $0 == selectedMethod }
    }

    private func setSelectedPaymentMethod(_ method: PaymentActionMethod) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            pendingPaymentMethodOverride = method
            isPaymentMethodPickerExpanded = false
        }
    }

    private func showPaymentSheetToast(_ message: String) {
        withAnimation {
            paymentSheetToast = message
        }
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    paymentSheetToast = nil
                }
            }
        }
    }

    // MARK: - Host Payment Management Sheet

    private func hostPaymentManagementSheet(_ liveState: ReceiptLiveState) -> some View {
        let guests = liveState.hostPaymentQueue
        let confirmedCount = guests.filter { $0.paymentStatus == "confirmed" }.count
        let allConfirmed = !guests.isEmpty && confirmedCount == guests.count

        return NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    // — Summary header —
                    VStack(spacing: 8) {
                        Text(allConfirmed ? "All payments confirmed" : "\(confirmedCount) of \(guests.count) confirmed")
                            .font(SPLTType.title)
                            .foregroundStyle(SPLTColor.ink)

                        if !allConfirmed {
                            HStack(spacing: 6) {
                                Image(systemName: "bell.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(SPLTColor.ink.opacity(0.4))
                                Text("You'll get a notification when someone pays.")
                                    .font(SPLTType.caption)
                                    .foregroundStyle(SPLTColor.ink.opacity(0.55))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                    // — Progress bar —
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(SPLTColor.ink.opacity(0.08))
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(allConfirmed ? SPLTColor.mint : SPLTColor.accent)
                                .frame(width: guests.isEmpty ? 0 : geo.size.width * CGFloat(confirmedCount) / CGFloat(guests.count), height: 6)
                                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: confirmedCount)
                        }
                    }
                    .frame(height: 6)

                    // — Guest list —
                    VStack(spacing: 0) {
                        ForEach(Array(guests.enumerated()), id: \.element.id) { index, guest in
                            hostPaymentGuestRow(guest: guest, liveState: liveState)

                            if index < guests.count - 1 {
                                Divider()
                                    .overlay(SPLTColor.subtle.opacity(0.6))
                                    .padding(.leading, 56)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(SPLTColor.ink.opacity(0.03))
                    )

                    if guests.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "clock")
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(SPLTColor.ink.opacity(0.3))
                            Text("Waiting for guests to choose a payment method.")
                                .font(SPLTType.caption)
                                .foregroundStyle(SPLTColor.ink.opacity(0.5))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
            }
            .background(
                LinearGradient(
                    colors: [SPLTColor.canvas, SPLTColor.canvasAccent],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Payments")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func hostPaymentGuestRow(guest: ReceiptHostPaymentQueueItem, liveState: ReceiptLiveState) -> some View {
        let participant = liveState.participants.first(where: { $0.id == guest.id })
        let isConfirmed = guest.paymentStatus == "confirmed"
        let isPending = guest.paymentStatus == "pending"
        let isConfirming = model.pendingParticipantKeys.contains(guest.id)
        let methodLabel: String? = {
            guard let raw = guest.paymentMethod else { return nil }
            switch raw {
            case "venmo": return "Venmo"
            case "cash_app": return "Cash App"
            case "zelle": return "Zelle"
            case "cash_apple_pay": return "Cash / Apple Pay"
            default: return raw
            }
        }()

        return HStack(spacing: 12) {
            // Avatar
            if let participant {
                participantAvatar(for: participant)
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
            } else {
                fallbackAvatar(initialsText: initials(for: guest.name))
                    .frame(width: 40, height: 40)
            }

            // Name + details
            VStack(alignment: .leading, spacing: 2) {
                Text(guest.name)
                    .font(SPLTType.bodyBold)
                    .foregroundStyle(SPLTColor.ink)

                HStack(spacing: 4) {
                    Text(activityCurrencyText(guest.amountDue))
                        .font(SPLTType.caption)
                        .foregroundStyle(SPLTColor.ink.opacity(0.6))
                    if let methodLabel, isPending {
                        Text("·")
                            .foregroundStyle(SPLTColor.ink.opacity(0.35))
                        Text(methodLabel)
                            .font(SPLTType.caption)
                            .foregroundStyle(SPLTColor.ink.opacity(0.5))
                    }
                }
            }

            Spacer()

            // Action
            if isConfirmed {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Paid")
                        .font(SPLTType.label)
                }
                .foregroundStyle(SPLTColor.mint)
            } else if isPending {
                Button {
                    Task {
                        await model.confirmPayment(participantKey: guest.id)
                    }
                } label: {
                    Group {
                        if isConfirming {
                            ProgressView()
                                .tint(elevatedButtonForeground)
                        } else {
                            Text("Confirm")
                                .font(SPLTType.label)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(elevatedButtonFill)
                    )
                    .foregroundStyle(elevatedButtonForeground)
                }
                .buttonStyle(.plain)
                .disabled(isConfirming)
            } else {
                Text("Waiting")
                    .font(SPLTType.caption)
                    .foregroundStyle(SPLTColor.ink.opacity(0.4))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Host Payment Confirmation Sheet (from notification)

    private func hostPaymentConfirmationSheet(payload: PaymentConfirmationPayload, liveState: ReceiptLiveState) -> some View {
        let participant = liveState.participants.first(where: { $0.id == payload.participantKey })
        let displayName = participant?.name ?? payload.guestName
        let amount = participant?.totalDue ?? payload.amount
        let isConfirming = model.pendingParticipantKeys.contains(payload.participantKey)
        let alreadyConfirmed = participant?.paymentStatus == "confirmed"

        return NavigationStack {
            VStack(spacing: 0) {
                Spacer().frame(height: 28)

                // Guest avatar
                confirmationAvatar(name: displayName, avatarURL: participant?.avatarURL)
                    .frame(width: 72, height: 72)

                Spacer().frame(height: 14)

                // Guest name
                Text(displayName)
                    .font(SPLTType.title)
                    .foregroundStyle(SPLTColor.ink)

                Spacer().frame(height: 6)

                Text("is paying you")
                    .font(SPLTType.body)
                    .foregroundStyle(SPLTColor.ink.opacity(0.58))

                Spacer().frame(height: 20)

                // Amount
                Text(activityCurrencyText(amount))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(SPLTColor.ink)

                Spacer().frame(height: 10)

                // Payment method badge
                HStack(spacing: 6) {
                    Image(systemName: confirmationMethodIcon(payload.paymentMethod))
                        .font(.system(size: 12, weight: .semibold))
                    Text("via \(payload.paymentMethodLabel)")
                        .font(SPLTType.bodyBold)
                }
                .foregroundStyle(SPLTColor.ink.opacity(0.62))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    Capsule(style: .continuous)
                        .fill(SPLTColor.ink.opacity(0.06))
                )

                Spacer()

                // Confirm / Already Confirmed
                if alreadyConfirmed {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Payment Confirmed")
                            .font(SPLTType.bodyBold)
                    }
                    .foregroundStyle(SPLTColor.mint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(SPLTColor.mint.opacity(0.12))
                    )
                } else {
                    Button {
                        Task {
                            await model.confirmPayment(participantKey: payload.participantKey)
                            // Dismiss the sheet after confirmation.
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            paymentConfirmationPayload = nil
                        }
                    } label: {
                        Group {
                            if isConfirming {
                                ProgressView()
                                    .tint(elevatedButtonForeground)
                            } else {
                                Text("Confirm Payment")
                                    .font(SPLTType.bodyBold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(elevatedButtonFill)
                        )
                        .foregroundStyle(elevatedButtonForeground)
                    }
                    .buttonStyle(.plain)
                    .disabled(isConfirming)
                }

                Spacer().frame(height: 16)
            }
            .padding(.horizontal, 24)
            .background(
                LinearGradient(
                    colors: [SPLTColor.canvas, SPLTColor.canvasAccent],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func confirmationAvatar(name: String, avatarURL: String?) -> some View {
        let initialsText = initials(for: name)
        let fallback = Circle()
            .fill(SPLTColor.canvas.opacity(0.7))
            .overlay(
                Text(initialsText)
                    .font(SPLTType.hero)
                    .foregroundStyle(SPLTColor.ink)
            )
            .frame(width: 72, height: 72)

        if let avatarURL, let url = URL(string: avatarURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    fallback
                        .overlay {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(SPLTColor.ink.opacity(0.5))
                        }
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(Circle())
                case .failure:
                    fallback
                @unknown default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    private func confirmationMethodIcon(_ method: String) -> String {
        switch method {
        case "venmo": return "v.circle.fill"
        case "cash_app": return "dollarsign.circle.fill"
        case "zelle": return "z.circle.fill"
        case "cash_apple_pay": return "banknote.fill"
        default: return "creditcard.fill"
        }
    }

    private func paymentStatusBadge(title: String, tint: Color, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(SPLTType.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.14))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(tint.opacity(0.22), lineWidth: 1)
                )
        )
    }

    @State private var isPaymentItemsExpanded = false

    @ViewBuilder
    private func paymentItemizedSection(_ liveState: ReceiptLiveState) -> some View {
        let claimedItems = liveState.items.filter { $0.viewerClaimedQuantity > 0 }
        if !claimedItems.isEmpty {
            let quantityColumnWidth: CGFloat = 34
            let amountColumnWidth: CGFloat = 78

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        isPaymentItemsExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(isPaymentItemsExpanded ? "Hide your items" : "View your items")
                            .font(SPLTType.body)
                            .foregroundStyle(SPLTColor.ink.opacity(0.74))

                        Text("(\(claimedItems.count))")
                            .font(SPLTType.caption)
                            .foregroundStyle(SPLTColor.ink.opacity(0.42))

                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(SPLTColor.ink.opacity(0.32))
                            .rotationEffect(.degrees(isPaymentItemsExpanded ? 90 : 0))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isPaymentItemsExpanded {
                    VStack(spacing: 0) {
                        ForEach(Array(claimedItems.enumerated()), id: \.element.id) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.name)
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(SPLTColor.ink.opacity(0.78))
                                    .lineLimit(1)

                                Spacer(minLength: 8)

                                Text("×\(item.viewerClaimedQuantity)")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(SPLTColor.ink.opacity(0.46))
                                    .monospacedDigit()
                                    .frame(width: quantityColumnWidth, alignment: .trailing)

                                Text(activityCurrencyText(item.viewerClaimedTotal))
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(SPLTColor.ink.opacity(0.74))
                                    .monospacedDigit()
                                    .frame(width: amountColumnWidth, alignment: .trailing)
                            }
                            .padding(.vertical, 5)
                        }

                        if let viewerSettlement = liveState.viewerSettlement, viewerSettlement.extraFeesShare > 0 {
                            let hasBackendBreakdown = viewerSettlement.taxShare > 0 || viewerSettlement.gratuityShare > 0
                            let taxVal = hasBackendBreakdown ? viewerSettlement.taxShare : estimatedFeeShare(receiptFee: liveState.tax, viewerSettlement: viewerSettlement, liveState: liveState)
                            let gratVal = hasBackendBreakdown ? viewerSettlement.gratuityShare : estimatedFeeShare(receiptFee: liveState.gratuity, viewerSettlement: viewerSettlement, liveState: liveState)
                            let otherVal: Double = {
                                let o = viewerSettlement.extraFeesShare - taxVal - gratVal
                                return o > 0.005 ? o : 0
                            }()

                            VStack(spacing: 3) {
                                if taxVal > 0 || gratVal > 0 {
                                    if taxVal > 0 {
                                        paymentFeeBreakdownRow(
                                            title: taxLabel(for: liveState),
                                            value: taxVal,
                                            amountColumnWidth: amountColumnWidth
                                        )
                                    }
                                    if gratVal > 0 {
                                        paymentFeeBreakdownRow(
                                            title: gratuityLabel(for: liveState),
                                            value: gratVal,
                                            amountColumnWidth: amountColumnWidth
                                        )
                                    }
                                    if otherVal > 0 {
                                        paymentFeeBreakdownRow(
                                            title: "Other fees",
                                            value: otherVal,
                                            amountColumnWidth: amountColumnWidth
                                        )
                                    }
                                } else {
                                    paymentFeeBreakdownRow(
                                        title: "Extra fees",
                                        value: viewerSettlement.extraFeesShare,
                                        amountColumnWidth: amountColumnWidth
                                    )
                                }
                            }
                            .padding(.top, 4)
                            .padding(.bottom, 2)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(SPLTColor.ink.opacity(colorScheme == .dark ? 0.12 : 0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(SPLTColor.subtle.opacity(0.8), lineWidth: 1)
                    )
            )
        }
    }

    private func paymentFeeBreakdownRow(title: String, value: Double, amountColumnWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(SPLTColor.ink.opacity(0.56))
            Spacer(minLength: 8)
            Text(activityCurrencyText(value))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(SPLTColor.ink.opacity(0.72))
                .monospacedDigit()
                .frame(width: amountColumnWidth, alignment: .trailing)
        }
    }

    private func settlementRow(title: String, value: Double, emphasized: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(emphasized ? SPLTType.bodyBold : SPLTType.body)
                .foregroundStyle(SPLTColor.ink)
            Spacer()
            Text(activityCurrencyText(value))
                .font(emphasized ? SPLTType.bodyBold : SPLTType.body)
                .monospacedDigit()
                .foregroundStyle(SPLTColor.ink)
        }
    }

    @ViewBuilder
    private func settlementFeeRow(viewerSettlement: ReceiptViewerSettlement, liveState: ReceiptLiveState) -> some View {
        let hasBreakdown = viewerSettlement.taxShare > 0 || viewerSettlement.gratuityShare > 0
        let taxVal = hasBreakdown ? viewerSettlement.taxShare : estimatedFeeShare(receiptFee: liveState.tax, viewerSettlement: viewerSettlement, liveState: liveState)
        let gratVal = hasBreakdown ? viewerSettlement.gratuityShare : estimatedFeeShare(receiptFee: liveState.gratuity, viewerSettlement: viewerSettlement, liveState: liveState)
        let otherVal: Double = {
            if hasBreakdown {
                let o = viewerSettlement.extraFeesShare - viewerSettlement.taxShare - viewerSettlement.gratuityShare
                return o > 0.005 ? o : 0
            }
            let o = viewerSettlement.extraFeesShare - taxVal - gratVal
            return o > 0.005 ? o : 0
        }()
        let canExpand = taxVal > 0 || gratVal > 0 || otherVal > 0

        VStack(spacing: 0) {
            Button {
                guard canExpand else { return }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    isSettlementFeesExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Extra fees")
                        .font(SPLTType.body)
                        .foregroundStyle(SPLTColor.ink)
                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SPLTColor.ink.opacity(0.35))
                            .rotationEffect(.degrees(isSettlementFeesExpanded ? 90 : 0))
                    }
                    Spacer()
                    Text(activityCurrencyText(viewerSettlement.extraFeesShare))
                        .font(SPLTType.body)
                        .monospacedDigit()
                        .foregroundStyle(SPLTColor.ink)
                }
            }
            .buttonStyle(.plain)

            if isSettlementFeesExpanded && canExpand {
                VStack(spacing: 6) {
                    if taxVal > 0 {
                        feeBreakdownRow(title: taxLabel(for: liveState), value: taxVal)
                    }
                    if gratVal > 0 {
                        feeBreakdownRow(title: gratuityLabel(for: liveState), value: gratVal)
                    }
                    if otherVal > 0 {
                        feeBreakdownRow(title: "Other fees", value: otherVal)
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 8)
            }
        }
        .clipped()
    }

    private func taxLabel(for liveState: ReceiptLiveState, capitalized: Bool = true) -> String {
        guard let tax = liveState.tax, tax > 0 else { return capitalized ? "Tax" : "tax" }
        let subtotal = liveState.items.reduce(0.0) { $0 + ($1.price ?? 0) }
        guard subtotal > 0 else { return capitalized ? "Tax" : "tax" }
        let pct = (tax / subtotal) * 100
        let formatted = pct.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", pct)
            : String(format: "%.1f", pct)
        return capitalized ? "Tax (\(formatted)%)" : "tax (\(formatted)%)"
    }

    private func gratuityLabel(for liveState: ReceiptLiveState, capitalized: Bool = true) -> String {
        guard let pct = liveState.gratuityPercent, pct > 0 else {
            return capitalized ? "Gratuity" : "gratuity"
        }
        let formatted = pct.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", pct)
            : String(format: "%.1f", pct)
        return capitalized ? "Gratuity (\(formatted)%)" : "gratuity (\(formatted)%)"
    }

    private func estimatedFeeShare(receiptFee: Double?, viewerSettlement: ReceiptViewerSettlement, liveState: ReceiptLiveState) -> Double {
        guard let fee = receiptFee, fee > 0, liveState.extraFeesTotal > 0 else { return 0 }
        let ratio = fee / liveState.extraFeesTotal
        return (viewerSettlement.extraFeesShare * ratio * 100).rounded() / 100
    }

    private func extraFeesLabel(for liveState: ReceiptLiveState) -> String {
        var parts: [String] = []
        if (liveState.tax ?? 0) > 0 { parts.append(taxLabel(for: liveState, capitalized: false)) }
        if (liveState.gratuity ?? 0) > 0 {
            if let pct = liveState.gratuityPercent, pct > 0 {
                let formatted = pct.truncatingRemainder(dividingBy: 1) == 0
                    ? String(format: "%.0f", pct)
                    : String(format: "%.1f", pct)
                parts.append("gratuity (\(formatted)%)")
            } else {
                parts.append("gratuity")
            }
        }
        if (liveState.otherFees ?? 0) > 0.005 { parts.append("other") }
        if parts.isEmpty { return "Extra fees" }
        // Capitalize the first component, e.g. "Tax + gratuity"
        let joined = parts.joined(separator: " + ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    private func feeBreakdownRow(title: String, value: Double) -> some View {
        HStack {
            Text(title)
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.56))
            Spacer()
            Text(activityCurrencyText(value))
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.7))
                .monospacedDigit()
        }
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
                                .foregroundStyle(SPLTColor.ink.opacity(0.45))
                            Text("No claimed items yet")
                                .font(SPLTType.body)
                                .foregroundStyle(SPLTColor.ink.opacity(0.62))
                            Text("Claim from the main list to edit quantities here.")
                                .font(SPLTType.caption)
                                .foregroundStyle(SPLTColor.ink.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(claimedItems) { item in
                                HStack(spacing: 14) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name)
                                            .font(SPLTType.bodyBold)
                                            .foregroundStyle(SPLTColor.ink)

                                        Text(activityCurrencyText(item.viewerClaimedTotal))
                                            .font(SPLTType.caption)
                                            .foregroundStyle(SPLTColor.ink.opacity(0.58))
                                            .monospacedDigit()
                                    }

                                    Spacer()

                                    HStack(spacing: 10) {
                                        quantityButton(symbol: "minus", enabled: item.viewerClaimedQuantity > 0 && !isViewerClaimsLocked(in: liveState)) {
                                            Task {
                                                await model.adjustClaim(itemKey: item.id, delta: -1)
                                            }
                                        }

                                        Text("\(item.viewerClaimedQuantity)")
                                            .font(SPLTType.bodyBold)
                                            .frame(minWidth: 24)
                                            .monospacedDigit()

                                        quantityButton(symbol: "plus", enabled: item.remainingQuantity > 0 && !isViewerClaimsLocked(in: liveState)) {
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
                        .fill(enabled ? SPLTColor.ink : SPLTColor.ink.opacity(0.15))
                )
                .foregroundStyle(enabled ? SPLTColor.canvas : SPLTColor.ink.opacity(0.42))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func synchronizeTransientSheets(for state: ReceiptActivityViewModel.State) {
        guard case .ready(let liveState) = state else {
            isSettlementSheetPresented = false
            isPaymentSheetPresented = false
            isHostPaymentSheetPresented = false
            hasAutoPresentedPaymentSheet = false
            hasAutoPresentedHostPaymentSheet = false
            return
        }

        isSettlementSheetPresented = shouldPresentSettlementSheet(in: liveState)

        if liveState.settlementPhase != "finalized" {
            isPaymentSheetPresented = false
            isHostPaymentSheetPresented = false
            hasAutoPresentedPaymentSheet = false
            hasAutoPresentedHostPaymentSheet = false
            return
        }

        if isViewerHost(in: liveState) {
            isPaymentSheetPresented = false
            if !hasAutoPresentedHostPaymentSheet {
                isHostPaymentSheetPresented = true
                hasAutoPresentedHostPaymentSheet = true
            }
        } else {
            isHostPaymentSheetPresented = false
            if !hasAutoPresentedPaymentSheet {
                isPaymentSheetPresented = true
                hasAutoPresentedPaymentSheet = true
            }
        }
    }

    private func shouldPresentSettlementSheet(in liveState: ReceiptLiveState) -> Bool {
        liveState.settlementPhase == "claiming" && currentViewer(in: liveState)?.isSubmitted == true
    }

    private func currentViewer(in liveState: ReceiptLiveState) -> ReceiptLiveParticipant? {
        liveState.participants.first(where: { $0.isCurrentUser })
    }

    private func isViewerHost(in liveState: ReceiptLiveState) -> Bool {
        guard let viewerKey = liveState.viewerParticipantKey else { return false }
        return viewerKey == liveState.hostParticipantKey
    }

    private func isViewerClaimsLocked(in liveState: ReceiptLiveState) -> Bool {
        if liveState.settlementPhase == "finalized" {
            return true
        }
        return currentViewer(in: liveState)?.isSubmitted == true
    }

    private func claimsLocked(in liveState: ReceiptLiveState) -> Bool {
        isViewerClaimsLocked(in: liveState)
    }

    private func canRemoveParticipant(_ participant: ReceiptLiveParticipant, liveState: ReceiptLiveState) -> Bool {
        guard isViewerHost(in: liveState) else { return false }
        guard liveState.settlementPhase == "claiming" else { return false }
        guard participant.id != liveState.hostParticipantKey else { return false }
        return true
    }

    private func shouldShowFinalizeCTA(in liveState: ReceiptLiveState) -> Bool {
        isViewerHost(in: liveState) && liveState.settlementPhase == "claiming"
    }

    private func canFinalize(in liveState: ReceiptLiveState) -> Bool {
        liveState.allParticipantsSubmitted &&
        liveState.unclaimedItemCount == 0 &&
        liveState.hostHasPaymentOptions
    }

    private func primaryActionTitle(for liveState: ReceiptLiveState) -> String {
        let hostLabel = resolvedHostLabel(in: liveState)
        if liveState.settlementPhase == "finalized" {
            if isViewerHost(in: liveState) {
                return "View payments"
            }
            switch liveState.viewerSettlement?.paymentStatus {
            case "confirmed":
                return "Payment confirmed"
            case "pending":
                return "Waiting for \(hostLabel)"
            default:
                return "Pay now"
            }
        }

        if isViewerHost(in: liveState), liveState.allParticipantsSubmitted {
            if !liveState.hostHasPaymentOptions {
                return "Set up payment options"
            }
            if liveState.unclaimedItemCount > 0 {
                return "Claim remaining items"
            }
            return "Finalize split"
        }

        if currentViewer(in: liveState)?.isSubmitted == true {
            return "Unsubmit"
        }

        return "Submit claims"
    }

    private func isPrimaryActionDisabled(for liveState: ReceiptLiveState) -> Bool {
        if model.isPrimaryActionPending { return true }

        if liveState.settlementPhase == "finalized" {
            // Host can always tap to open payment management sheet
            if isViewerHost(in: liveState) { return false }
            if liveState.viewerSettlement?.paymentStatus == "confirmed" { return true }
            if liveState.viewerSettlement?.paymentStatus == "pending" { return true }
            return false
        }

        if isViewerHost(in: liveState), liveState.allParticipantsSubmitted {
            return liveState.unclaimedItemCount > 0
        }

        return false
    }

    private func handlePrimaryAction(for liveState: ReceiptLiveState) {
        if liveState.settlementPhase == "finalized" {
            if isViewerHost(in: liveState) {
                isHostPaymentSheetPresented = true
            } else {
                isPaymentSheetPresented = true
            }
            return
        }

        if isViewerHost(in: liveState), liveState.allParticipantsSubmitted {
            guard liveState.hostHasPaymentOptions else {
                model.actionErrorMessage = "Set up payment options in your Profile before finalizing."
                return
            }
            guard liveState.unclaimedItemCount == 0 else {
                model.actionErrorMessage = "All items need to be claimed before finalizing."
                return
            }
            Task {
                await model.finalizeSettlement()
            }
            return
        }

        let isSubmitted = currentViewer(in: liveState)?.isSubmitted == true
        Task {
            await model.setSubmissionStatus(isSubmitted: !isSubmitted)
        }
    }

    private func paymentActions(for liveState: ReceiptLiveState) -> [PaymentActionMethod] {
        guard let options = liveState.hostPaymentOptions else {
            return [.cashApplePay]
        }

        var methods: [PaymentActionMethod] = []
        if options.venmoEnabled, let username = options.venmoUsername, !username.isEmpty {
            methods.append(.venmo)
        }
        if options.cashAppEnabled, let cashtag = options.cashAppCashtag, !cashtag.isEmpty {
            methods.append(.cashApp)
        }
        if options.zelleEnabled, let contact = options.zelleContact, !contact.isEmpty {
            methods.append(.zelle)
        }
        if options.cashApplePayEnabled {
            methods.append(.cashApplePay)
        }

        if methods.isEmpty {
            return [.cashApplePay]
        }

        if let preferredRaw = options.preferredPaymentMethod,
           let preferred = PaymentActionMethod(rawValue: preferredRaw),
           methods.contains(preferred) {
            methods.removeAll(where: { $0 == preferred })
            methods.insert(preferred, at: 0)
        }

        return methods
    }

    private func handlePaymentTap(method: PaymentActionMethod, liveState: ReceiptLiveState) {
        Task {
            await model.markPaymentIntent(method: method.rawValue)
        }

        let hostLabel = resolvedHostLabel(in: liveState)
        let amount = String(format: "%.2f", liveState.viewerSettlement?.totalDue ?? 0)
        let note = "SPLT split \(liveState.code)"

        switch method {
        case .venmo:
            guard let username = liveState.hostPaymentOptions?.venmoUsername?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty else {
                model.actionErrorMessage = "\(hostLabel.prefix(1).uppercased() + hostLabel.dropFirst()) is missing a Venmo username."
                return
            }
            let encodedNote = note.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? note
            if let mobileURL = URL(string: "venmo://paycharge?txn=pay&recipients=\(username)&amount=\(amount)&note=\(encodedNote)") {
                openURL(mobileURL)
            } else if let webURL = URL(string: "https://venmo.com/u/\(username)?txn=pay&audience=private&amount=\(amount)&note=\(encodedNote)") {
                openURL(webURL)
            }
            showPaymentSheetToast("Opening Venmo…")
        case .cashApp:
            guard let cashtag = liveState.hostPaymentOptions?.cashAppCashtag?.trimmingCharacters(in: .whitespacesAndNewlines), !cashtag.isEmpty else {
                model.actionErrorMessage = "\(hostLabel.prefix(1).uppercased() + hostLabel.dropFirst()) is missing a Cash App cashtag."
                return
            }
            let cleanedCashtag = cashtag.trimmingCharacters(in: CharacterSet(charactersIn: "$") )
            if let url = URL(string: "https://cash.app/$\(cleanedCashtag)/\(amount)") {
                openURL(url)
            }
            showPaymentSheetToast("Opening Cash App…")
        case .zelle:
            guard let contact = liveState.hostPaymentOptions?.zelleContact?.trimmingCharacters(in: .whitespacesAndNewlines), !contact.isEmpty else {
                model.actionErrorMessage = "\(hostLabel.prefix(1).uppercased() + hostLabel.dropFirst()) is missing a Zelle contact."
                return
            }
            UIPasteboard.general.string = contact
            let contactType = contact.contains("@") ? "email" : "number"
            showPaymentSheetToast("Copied \(hostLabel)'s \(contactType) (\(contact))")
        case .cashApplePay:
            showPaymentSheetToast("Let \(hostLabel) know so they can confirm")
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    toastMessage = nil
                }
            }
        }
    }

    private func settlementHelperText(for liveState: ReceiptLiveState) -> String {
        if isViewerHost(in: liveState) {
            return "Unsubmit if you need to edit your claimed items."
        }
        return "You can unsubmit any time before finalization."
    }

    private func hostFinalizeGuidance(_ liveState: ReceiptLiveState) -> some View {
        let blockers = finalizeBlockers(in: liveState)
        return VStack(alignment: .leading, spacing: 8) {
            if blockers.isEmpty {
                Text("Everything is ready for finalization.")
                    .font(SPLTType.caption)
                    .foregroundStyle(SPLTColor.mint)
            } else {
                ForEach(blockers, id: \.self) { blocker in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SPLTColor.ink.opacity(0.46))
                            .padding(.top, 1)
                        Text(blocker)
                            .font(SPLTType.caption)
                            .foregroundStyle(SPLTColor.ink.opacity(0.7))
                    }
                }
            }
        }
        .padding(12)
        .activityPanel(cornerRadius: 14)
    }

    private func hostWaitingSummary(_ liveState: ReceiptLiveState) -> some View {
        let waitingParticipants = liveState.participants.filter { !$0.isSubmitted }
        let unclaimed = liveState.unclaimedItemCount

        var parts: [String] = []
        if !waitingParticipants.isEmpty {
            let count = waitingParticipants.count
            parts.append("waiting on \(count) \(count == 1 ? "person" : "people")")
        }
        if unclaimed > 0 {
            parts.append("\(unclaimed) \(unclaimed == 1 ? "item" : "items") unclaimed")
        }
        if !liveState.hostHasPaymentOptions {
            parts.append("payment options needed")
        }

        let summary = parts.joined(separator: "  ·  ")

        return HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SPLTColor.ink.opacity(0.4))
            Text(summary.prefix(1).uppercased() + summary.dropFirst())
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.55))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(SPLTColor.ink.opacity(0.06))
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func guestWaitingSummary(_ liveState: ReceiptLiveState) -> some View {
        let hostLabel = resolvedHostLabel(in: liveState)
        let waitingCount = liveState.participants.filter { !$0.isSubmitted }.count

        let summary: String
        if !liveState.allParticipantsSubmitted {
            if waitingCount == 1 {
                summary = "waiting on 1 other to submit"
            } else if waitingCount > 1 {
                summary = "waiting on \(waitingCount) others to submit"
            } else {
                summary = "waiting for \(hostLabel) to finalize"
            }
        } else {
            summary = "waiting for \(hostLabel) to finalize"
        }

        return HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SPLTColor.ink.opacity(0.4))
            Text(summary.prefix(1).uppercased() + summary.dropFirst())
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.55))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(SPLTColor.ink.opacity(0.06))
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func finalizeBlockers(in liveState: ReceiptLiveState) -> [String] {
        var blockers: [String] = []
        let waitingParticipants = liveState.participants.filter { !$0.isSubmitted }
        if !waitingParticipants.isEmpty {
            let names = waitingParticipants
                .prefix(2)
                .map { participantDisplayName($0, liveState: liveState) }
                .joined(separator: ", ")
            let suffix = waitingParticipants.count > 2 ? ", +\(waitingParticipants.count - 2) more" : ""
            blockers.append("Waiting on \(waitingParticipants.count) to submit (\(names)\(suffix)).")
        }
        if liveState.unclaimedItemCount > 0 {
            blockers.append("\(liveState.unclaimedItemCount) item\(liveState.unclaimedItemCount == 1 ? "" : "s") still unclaimed.")
        }
        if !liveState.hostHasPaymentOptions {
            blockers.append("Set up payment options in Profile to enable finalization.")
        }
        return blockers
    }

    private enum ParticipantIndicator {
        case submitted
        case paid
        case pendingPayment
    }

    private func participantIndicator(for participant: ReceiptLiveParticipant, liveState: ReceiptLiveState) -> ParticipantIndicator? {
        if participant.paymentStatus == "confirmed" {
            return .paid
        }
        if liveState.settlementPhase == "finalized" && participant.paymentStatus == "pending" {
            return .pendingPayment
        }
        if liveState.settlementPhase != "finalized" && participant.isSubmitted {
            return .submitted
        }
        return nil
    }

    @ViewBuilder
    private func participantAvatar(for participant: ReceiptLiveParticipant) -> some View {
        let fallback = fallbackAvatar(initialsText: initials(for: participantActualName(participant)))

        if let avatarURL = participant.avatarURL,
           let url = URL(string: avatarURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    fallback
                        .overlay {
                            ProgressView()
                                .scaleEffect(0.75)
                                .tint(SPLTColor.ink.opacity(0.5))
                        }
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 58, height: 58)
                        .clipShape(Circle())
                case .failure:
                    fallback
                @unknown default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    private func fallbackAvatar(initialsText: String) -> some View {
        Circle()
            .fill(SPLTColor.canvas.opacity(0.7))
            .overlay(
                Text(initialsText)
                    .font(SPLTType.bodyBold)
                    .foregroundStyle(SPLTColor.ink)
            )
            .frame(width: 58, height: 58)
    }

    /// The label shown beneath the avatar (returns "You" for the viewer).
    private func participantDisplayName(_ participant: ReceiptLiveParticipant, liveState: ReceiptLiveState) -> String {
        if participant.isCurrentUser {
            return "You"
        }
        return participantActualName(participant, isHost: participant.id == liveState.hostParticipantKey)
    }

    /// The real name used for avatar initials — never returns "You" or email.
    private func participantActualName(_ participant: ReceiptLiveParticipant, isHost: Bool = false) -> String {
        let trimmedName = participant.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedName = trimmedName.lowercased()
        let genericNames: Set<String> = ["you", "guest", "friend", "host"]

        if !trimmedName.isEmpty && !genericNames.contains(lowercasedName) {
            return trimmedName
        }

        // For the host, show "Host" instead of generic names
        if isHost {
            return "Host"
        }

        return "Guest"
    }

    private func paymentStatePill(title: String, tint: Color) -> some View {
        Text(title)
            .font(SPLTType.caption)
            .foregroundStyle(SPLTColor.canvas.opacity(0.95))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.38))
            )
    }

    private func paymentActionButton(
        method: PaymentActionMethod,
        liveState: ReceiptLiveState,
        isSelected: Bool = false
    ) -> some View {
        let brand = brandStyle(for: method)
        let subtitle = methodSubtitle(for: method, liveState: liveState)

        return Button {
            setSelectedPaymentMethod(method)
            handlePaymentTap(method: method, liveState: liveState)
        } label: {
            HStack(spacing: 12) {
                paymentMethodLeadingBadge(for: method)

                VStack(alignment: .leading, spacing: 2) {
                    Text(method.title)
                        .font(SPLTType.bodyBold)
                        .foregroundStyle(brand.foreground)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(brand.foreground.opacity(0.78))
                    }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: brand.gradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.white.opacity(isSelected ? 0.34 : 0.14), lineWidth: isSelected ? 1.5 : 1)
                    )
            )
            .shadow(color: brand.shadow, radius: isSelected ? 8 : 5, y: isSelected ? 5 : 3)
        }
        .buttonStyle(.plain)
        .disabled(model.isPrimaryActionPending)
    }

    private func cashApplePayOption(liveState: ReceiptLiveState, isSelected: Bool = false) -> some View {
        Button {
            setSelectedPaymentMethod(.cashApplePay)
            handlePaymentTap(method: .cashApplePay, liveState: liveState)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "banknote")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SPLTColor.ink.opacity(0.58))
                Text("I'm paying with cash or Apple Pay")
                    .font(SPLTType.body)
                    .foregroundStyle(SPLTColor.ink.opacity(0.68))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(SPLTColor.ink.opacity(colorScheme == .dark ? 0.11 : 0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                isSelected ? SPLTColor.sun.opacity(0.45) : SPLTColor.subtle.opacity(0.9),
                                lineWidth: isSelected ? 1.3 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isPrimaryActionPending)
    }

    private func methodSubtitle(for method: PaymentActionMethod, liveState: ReceiptLiveState) -> String {
        switch method {
        case .venmo:
            let username = liveState.hostPaymentOptions?.venmoUsername?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let username, !username.isEmpty {
                return "@\(username.trimmingCharacters(in: CharacterSet(charactersIn: "@")))"
            }
            return ""
        case .cashApp:
            let cashtag = liveState.hostPaymentOptions?.cashAppCashtag?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cashtag, !cashtag.isEmpty {
                let cleaned = cashtag.trimmingCharacters(in: CharacterSet(charactersIn: "$"))
                return "$\(cleaned)"
            }
            return ""
        case .zelle:
            let contact = liveState.hostPaymentOptions?.zelleContact?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let contact, !contact.isEmpty {
                return contact
            }
            return ""
        case .cashApplePay:
            return ""
        }
    }

    @ViewBuilder
    private func paymentMethodLeadingBadge(for method: PaymentActionMethod) -> some View {
        let assetName = paymentMethodLogoAssetName(for: method)

        ZStack {
            Circle()
                .fill(.white.opacity(0.18))

            if let assetName, UIImage(named: assetName) != nil {
                Image(assetName)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .padding(7)
            } else {
                Image(systemName: paymentMethodIcon(for: method))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 34, height: 34)
    }

    private func paymentMethodLogoAssetName(for method: PaymentActionMethod) -> String? {
        switch method {
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

    private func paymentMethodIcon(for method: PaymentActionMethod) -> String {
        switch method {
        case .venmo:
            return "v.circle.fill"
        case .cashApp:
            return "dollarsign.circle.fill"
        case .zelle:
            return "z.circle.fill"
        case .cashApplePay:
            return "banknote.fill"
        }
    }

    private struct PaymentBrandStyle {
        let gradient: [Color]
        let foreground: Color
        let shadow: Color
    }

    private func brandStyle(for method: PaymentActionMethod) -> PaymentBrandStyle {
        switch method {
        case .venmo:
            return PaymentBrandStyle(
                gradient: [
                    Color(red: 0.0, green: 140.0 / 255.0, blue: 1.0),
                    Color(red: 0.0, green: 140.0 / 255.0, blue: 1.0)
                ], // #008CFF
                foreground: .white,
                shadow: Color(red: 0.0, green: 140.0 / 255.0, blue: 1.0).opacity(0.2)
            )
        case .cashApp:
            return PaymentBrandStyle(
                gradient: [
                    Color(red: 0.0, green: 224.0 / 255.0, blue: 18.0 / 255.0),
                    Color(red: 0.0, green: 224.0 / 255.0, blue: 18.0 / 255.0)
                ], // #00E012
                foreground: .white,
                shadow: Color(red: 0.0, green: 224.0 / 255.0, blue: 18.0 / 255.0).opacity(0.2)
            )
        case .zelle:
            return PaymentBrandStyle(
                gradient: [
                    Color(red: 108.0 / 255.0, green: 28.0 / 255.0, blue: 211.0 / 255.0),
                    Color(red: 108.0 / 255.0, green: 28.0 / 255.0, blue: 211.0 / 255.0)
                ], // #6C1CD3
                foreground: .white,
                shadow: Color(red: 108.0 / 255.0, green: 28.0 / 255.0, blue: 211.0 / 255.0).opacity(0.2)
            )
        case .cashApplePay:
            return PaymentBrandStyle(
                gradient: [SPLTColor.ink.opacity(0.84), SPLTColor.ink.opacity(0.68)],
                foreground: .white,
                shadow: SPLTColor.ink.opacity(0.16)
            )
        }
    }

    private func resolvedHostLabel(in liveState: ReceiptLiveState) -> String {
        if let name = liveState.hostDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return "host"
    }

    private func statusTitle(for liveState: ReceiptLiveState) -> String {
        let hostLabel = resolvedHostLabel(in: liveState)
        if liveState.settlementPhase == "finalized" {
            if isViewerHost(in: liveState) {
                return "Splits finalized"
            }
            switch liveState.viewerSettlement?.paymentStatus {
            case "confirmed":
                return "Payment confirmed"
            case "pending":
                return "Waiting for \(hostLabel) to confirm"
            default:
                return "Ready to pay"
            }
        }

        if currentViewer(in: liveState)?.isSubmitted == true {
            if liveState.allParticipantsSubmitted {
                return isViewerHost(in: liveState) ? "Ready to finalize" : "Waiting for \(hostLabel)"
            }
            return "Waiting for others"
        }

        return "Claim your items"
    }

    private func statusDetail(for liveState: ReceiptLiveState) -> String {
        let hostLabel = resolvedHostLabel(in: liveState)
        if liveState.settlementPhase == "finalized" {
            if isViewerHost(in: liveState) {
                return "You'll be notified when guests pay. Tap them to confirm."
            }
            return "Tap your payment method. \(hostLabel.prefix(1).uppercased() + hostLabel.dropFirst()) will confirm payments."
        }

        // Viewer hasn't submitted yet — guide them to select items
        if currentViewer(in: liveState)?.isSubmitted != true {
            return "Select what you ordered, then submit when you're ready."
        }

        // Viewer submitted, waiting on others
        if !liveState.allParticipantsSubmitted {
            return "You can unsubmit any time before finalization."
        }

        if isViewerHost(in: liveState) {
            if !liveState.hostHasPaymentOptions {
                return "Set payment options in Profile before finalizing."
            }
            if liveState.unclaimedItemCount > 0 {
                return "Claim every remaining item before finalizing."
            }
            return "Finalize when everything looks right."
        }

        return "\(hostLabel.prefix(1).uppercased() + hostLabel.dropFirst()) will finalize once everything is reviewed."
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
        colorScheme == .dark ? .white : SPLTColor.ink
    }

    private var elevatedButtonForeground: Color {
        colorScheme == .dark ? Color.black.opacity(0.85) : SPLTColor.canvas
    }

    private var mutedButtonFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.15) : SPLTColor.ink.opacity(0.12)
    }

    private var mutedButtonForeground: Color {
        colorScheme == .dark ? Color.white.opacity(0.42) : SPLTColor.ink.opacity(0.38)
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

private struct LivePulseDot: View {
    var size: CGFloat = 8
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(SPLTColor.mint)
            .frame(width: size, height: size)
            .scaleEffect(pulse ? 1.26 : 0.84)
            .opacity(pulse ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true), value: pulse)
            .onAppear {
                pulse = true
            }
    }
}

private enum PaymentActionMethod: String, CaseIterable {
    case venmo = "venmo"
    case cashApp = "cash_app"
    case zelle = "zelle"
    case cashApplePay = "cash_apple_pay"

    var title: String {
        switch self {
        case .venmo:
            return "Pay with Venmo"
        case .cashApp:
            return "Pay with Cash App"
        case .zelle:
            return "Pay with Zelle"
        case .cashApplePay:
            return "Cash / Apple Pay"
        }
    }

    var shortLabel: String {
        switch self {
        case .venmo: return "Venmo"
        case .cashApp: return "Cash App"
        case .zelle: return "Zelle"
        case .cashApplePay: return "Cash / Apple Pay"
        }
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
                            .stroke(SPLTColor.subtle.opacity(0.9), lineWidth: 1)
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
    @Published var pendingParticipantKeys: Set<String> = []
    @Published var isPrimaryActionPending = false
    @Published var actionErrorMessage: String?
    @Published var shouldExitToReceipts = false

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
        shouldExitToReceipts = false

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
        shouldExitToReceipts = false
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
            actionErrorMessage = error.localizedDescription
        }
    }

    func setSubmissionStatus(isSubmitted: Bool) async {
        guard let code = activeCode else { return }
        guard !isPrimaryActionPending else { return }

        isPrimaryActionPending = true
        defer { isPrimaryActionPending = false }

        do {
            try await ConvexService.shared.setSubmissionStatus(receiptCode: code, isSubmitted: isSubmitted)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func removeParticipant(participantKey: String) async {
        guard let code = activeCode else { return }
        guard !pendingParticipantKeys.contains(participantKey) else { return }

        pendingParticipantKeys.insert(participantKey)
        defer { pendingParticipantKeys.remove(participantKey) }

        do {
            try await ConvexService.shared.removeParticipant(receiptCode: code, participantKey: participantKey)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func finalizeSettlement() async {
        guard let code = activeCode else { return }
        guard !isPrimaryActionPending else { return }

        isPrimaryActionPending = true
        defer { isPrimaryActionPending = false }

        do {
            try await ConvexService.shared.finalizeSettlement(receiptCode: code)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func markPaymentIntent(method: String) async {
        guard let code = activeCode else { return }
        do {
            try await ConvexService.shared.markPaymentIntent(receiptCode: code, method: method)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func confirmPayment(participantKey: String) async {
        guard let code = activeCode else { return }
        guard !pendingParticipantKeys.contains(participantKey) else { return }

        pendingParticipantKeys.insert(participantKey)
        defer { pendingParticipantKeys.remove(participantKey) }

        do {
            try await ConvexService.shared.confirmPayment(receiptCode: code, participantKey: participantKey)
        } catch {
            actionErrorMessage = error.localizedDescription
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
            canManageActions: seedReceipt.canManageActions,
            scannedTotal: seedReceipt.scannedTotal,
            scannedSubtotal: seedReceipt.scannedSubtotal,
            scannedTax: seedReceipt.scannedTax,
            scannedGratuity: seedReceipt.scannedGratuity,
            settlementPhase: seedReceipt.settlementPhase,
            archivedReason: seedReceipt.archivedReason,
            shareCode: code,
            remoteID: response.id
        )

        // Upload cached receipt image in the background
        let receiptID = seedReceipt.id
        Task.detached(priority: .utility) {
            guard let imageData = ReceiptImageCache.load(for: receiptID) else { return }
            do {
                try await ConvexService.shared.uploadReceiptImage(imageData, receiptCode: code)
                ReceiptImageCache.remove(for: receiptID)
            } catch {
                print("[ReceiptImageUpload] Failed: \(error.localizedDescription)")
            }
        }

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
                            self.state = .error("This receipt was archived.")
                            self.shouldExitToReceipts = true
                        }
                        return
                    }

                    let updatedReceipt = Receipt(
                        id: self.shareReceipt?.id ?? self.seedReceipt.id,
                        date: self.shareReceipt?.date ?? self.seedReceipt.date,
                        items: self.shareReceipt?.items ?? self.seedReceipt.items,
                        isActive: payload.isActive,
                        canManageActions: self.shareReceipt?.canManageActions ?? self.seedReceipt.canManageActions,
                        scannedTotal: self.shareReceipt?.scannedTotal,
                        scannedSubtotal: self.shareReceipt?.scannedSubtotal,
                        scannedTax: payload.tax ?? self.shareReceipt?.scannedTax,
                        scannedGratuity: payload.gratuity ?? self.shareReceipt?.scannedGratuity,
                        settlementPhase: payload.settlementPhase,
                        archivedReason: payload.archivedReason,
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
