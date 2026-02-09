import SwiftUI
import UIKit

struct ReceiptActivityView: View {
    let receipt: Receipt
    var onShareTap: (Receipt) -> Void
    var onReceiptUpdate: (Receipt) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @StateObject private var model: ReceiptActivityViewModel
    @State private var didAnimateIn = false
    @State private var isSettlementSheetPresented = false
    @State private var isPaymentSheetPresented = false
    @State private var isSettlementFeesExpanded = false
    @State private var hasAutoPresentedPaymentSheet = false
    @State private var toastMessage: String?

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
                        .font(TabbyType.caption)
                        .foregroundStyle(TabbyColor.canvas)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(TabbyColor.ink.opacity(0.92))
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
                        .foregroundStyle(TabbyColor.ink)
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
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.hidden)
            }
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
        .animation(.easeInOut(duration: 0.2), value: toastMessage)
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Who's in")
                    .font(TabbyType.display)
                    .foregroundStyle(TabbyColor.ink)
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

    private var removedState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.slash.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(TabbyColor.ink.opacity(0.45))

            Text("You've been removed")
                .font(TabbyType.title)
                .foregroundStyle(TabbyColor.ink)

            Text("The host removed you from this receipt. Your claimed items have been released.")
                .font(TabbyType.body)
                .foregroundStyle(TabbyColor.ink.opacity(0.62))
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
                    .font(TabbyType.bodyBold)
                    .foregroundStyle(TabbyColor.ink)
                Text(statusDetail(for: liveState))
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.58))
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
                    .font(TabbyType.label)
                    .textCase(.uppercase)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))

                Spacer()

                Text("\(liveState.participants.count) joined")
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.56))
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
                    .fill(participant.isCurrentUser ? TabbyColor.accent.opacity(0.18) : TabbyColor.canvas.opacity(0.45))

                Circle()
                    .stroke(participant.isCurrentUser ? TabbyColor.accent : TabbyColor.subtle.opacity(0.95), lineWidth: participant.isCurrentUser ? 2.2 : 1)

                participantAvatar(for: participant)
            }
            .frame(width: 64, height: 64)
            .overlay(alignment: .bottomTrailing) {
                if let indicator = participantIndicator(for: participant, liveState: liveState) {
                    Circle()
                        .fill(indicator == .paid ? TabbyColor.mint : TabbyColor.accent)
                        .frame(width: 19, height: 19)
                        .overlay(
                            Image(systemName: indicator == .paid ? "banknote.fill" : "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(TabbyColor.canvas)
                        )
                        .shadow(color: TabbyColor.shadow.opacity(0.65), radius: 4, x: 0, y: 2)
                        .offset(x: 2, y: 2)
                }
            }

            Text(participantDisplayName(participant, liveState: liveState))
                .font(TabbyType.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(TabbyColor.ink.opacity(0.78))
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
                itemRow(item, claimsLocked: claimsLocked)
                if index < items.count - 1 {
                    Divider()
                        .overlay(TabbyColor.subtle.opacity(0.95))
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
                        Text(buttonTitle)
                            .font(TabbyType.bodyBold)
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
                                .stroke(TabbyColor.subtle.opacity(0.2), lineWidth: 1)
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
            .font(TabbyType.caption)
            .foregroundStyle(TabbyColor.ink.opacity(0.74))
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
            Text("Receipt breakdown")
                .font(TabbyType.label)
                .textCase(.uppercase)
                .foregroundStyle(TabbyColor.ink.opacity(0.52))

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
                Divider().overlay(TabbyColor.subtle.opacity(0.6))
                receiptTotalRow(label: "Extra fees total", value: liveState.extraFeesTotal, dimmed: false)
            }
        }
        .padding(14)
        .activityPanel(cornerRadius: 18)
    }

    private func receiptTotalRow(label: String, value: Double, dimmed: Bool = true) -> some View {
        HStack {
            Text(label)
                .font(TabbyType.caption)
                .foregroundStyle(TabbyColor.ink.opacity(dimmed ? 0.56 : 0.72))
            Spacer()
            Text(activityCurrencyText(value))
                .font(TabbyType.caption)
                .monospacedDigit()
                .foregroundStyle(TabbyColor.ink.opacity(dimmed ? 0.62 : 0.78))
        }
    }

    private func hostPaymentsPanel(_ liveState: ReceiptLiveState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Payments")
                .font(TabbyType.label)
                .textCase(.uppercase)
                .foregroundStyle(TabbyColor.ink.opacity(0.62))

            if liveState.hostPaymentQueue.isEmpty {
                Text("No guest payments pending.")
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
            } else {
                ForEach(liveState.hostPaymentQueue) { queueItem in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(queueItem.name)
                                .font(TabbyType.bodyBold)
                                .foregroundStyle(TabbyColor.ink)
                            Text(activityCurrencyText(queueItem.amountDue))
                                .font(TabbyType.caption)
                                .foregroundStyle(TabbyColor.ink.opacity(0.58))
                            if let paymentMethod = queueItem.paymentMethod,
                               queueItem.paymentStatus == "pending" {
                                Text("Pending via \(paymentMethod.replacingOccurrences(of: "_", with: " ").capitalized)")
                                    .font(TabbyType.caption)
                                    .foregroundStyle(TabbyColor.ink.opacity(0.5))
                            }
                        }

                        Spacer()

                        switch queueItem.paymentStatus {
                        case "confirmed":
                            Text("Paid")
                                .font(TabbyType.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(TabbyColor.mint.opacity(0.16))
                                )
                        case "pending":
                            Button {
                                Task {
                                    await model.confirmPayment(participantKey: queueItem.id)
                                }
                            } label: {
                                Text("Confirm")
                                    .font(TabbyType.caption)
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
                                .font(TabbyType.caption)
                                .foregroundStyle(TabbyColor.ink.opacity(0.48))
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

                Text(activityCurrencyText(liveState.claimedTotal))
                    .font(TabbyType.hero)
                    .foregroundStyle(TabbyColor.ink)
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
                                .font(TabbyType.bodyBold)
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
                        .font(TabbyType.caption)
                        .foregroundStyle(TabbyColor.ink.opacity(0.62))
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
                        .stroke(TabbyColor.subtle.opacity(0.95), lineWidth: 1)
                )
                .shadow(color: TabbyColor.shadow.opacity(0.6), radius: 14, x: 0, y: 6)
        )
    }

    private func settlementPreviewSheet(_ liveState: ReceiptLiveState) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("What you owe")
                    .font(TabbyType.title)
                    .foregroundStyle(TabbyColor.ink)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)

                if let viewerSettlement = liveState.viewerSettlement {
                    VStack(spacing: 10) {
                        settlementRow(title: "Items", value: viewerSettlement.itemSubtotal)

                        if viewerSettlement.extraFeesShare > 0 {
                            settlementFeeRow(viewerSettlement: viewerSettlement, liveState: liveState)
                        }

                        if viewerSettlement.roundingAdjustment != 0 {
                            settlementRow(title: "Rounding", value: viewerSettlement.roundingAdjustment)
                        }
                        Divider()
                            .overlay(TabbyColor.subtle.opacity(0.9))
                        settlementRow(title: "Total due", value: viewerSettlement.totalDue, emphasized: true)
                    }
                    .padding(14)
                    .activityPanel(cornerRadius: 16)
                }

                if let viewerSettlement = liveState.viewerSettlement, viewerSettlement.extraFeesShare > 0 {
                    Text("Extra fees split proportionally by your items.")
                        .font(TabbyType.caption)
                        .foregroundStyle(TabbyColor.ink.opacity(0.58))
                }

                HStack(spacing: 8) {
                    LivePulseDot(size: 7)
                    Text(statusTitle(for: liveState))
                        .font(TabbyType.bodyBold)
                        .foregroundStyle(TabbyColor.ink)
                }

                if isViewerHost(in: liveState) {
                    hostFinalizeGuidance(liveState)
                }

                Text(settlementHelperText(for: liveState))
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.62))

                Spacer(minLength: 8)

                Button {
                    Task {
                        await model.setSubmissionStatus(isSubmitted: false)
                    }
                } label: {
                    Text("Unsubmit to edit")
                        .font(TabbyType.bodyBold)
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
                            .font(TabbyType.bodyBold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(canFinalize(in: liveState) ? TabbyColor.ink.opacity(0.1) : TabbyColor.ink.opacity(0.06))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(canFinalize(in: liveState) ? TabbyColor.subtle : TabbyColor.subtle.opacity(0.7), lineWidth: 1)
                                        )
                                )
                                .foregroundStyle(canFinalize(in: liveState) ? TabbyColor.ink : TabbyColor.ink.opacity(0.42))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canFinalize(in: liveState))
                }
            }
            .padding(20)
            .background(
                LinearGradient(
                    colors: [TabbyColor.canvas, TabbyColor.canvasAccent],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func paymentSheet(_ liveState: ReceiptLiveState) -> some View {
        let hostLabel = resolvedHostLabel(in: liveState)
        return NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Pay \(hostLabel)")
                        .font(TabbyType.title)
                        .foregroundStyle(TabbyColor.ink)
                        .frame(maxWidth: .infinity, alignment: .center)

                    if let viewerSettlement = liveState.viewerSettlement {
                        // — Hero amount card —
                        VStack(spacing: 14) {
                            Text("Amount due")
                                .font(TabbyType.caption)
                                .textCase(.uppercase)
                                .tracking(0.8)
                                .foregroundStyle(TabbyColor.ink.opacity(0.52))

                            Text(activityCurrencyText(viewerSettlement.totalDue))
                                .font(.system(size: 42, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(TabbyColor.ink)

                            if viewerSettlement.paymentStatus == "confirmed" {
                                paymentStatusBadge(title: "Payment confirmed", tint: TabbyColor.mint, icon: "checkmark.circle.fill")
                            } else if viewerSettlement.paymentStatus == "pending" {
                                paymentStatusBadge(title: "Waiting for \(hostLabel) to confirm", tint: TabbyColor.sun, icon: "clock.fill")
                            } else {
                                paymentStatusBadge(title: "Choose a method below", tint: TabbyColor.accent, icon: "arrow.down.circle.fill")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(TabbyColor.subtle.opacity(0.9), lineWidth: 1)
                                )
                        )
                    }

                    // — Inline itemized claims —
                    paymentItemizedSection(liveState)

                    VStack(spacing: 10) {
                        ForEach(paymentActions(for: liveState), id: \.rawValue) { method in
                            paymentActionCard(method: method, liveState: liveState)
                        }
                    }
                }
                .padding(20)
            }
            .background(
                LinearGradient(
                    colors: [TabbyColor.canvas, TabbyColor.canvasAccent],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func paymentStatusBadge(title: String, tint: Color, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(TabbyType.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }

    @ViewBuilder
    private func paymentItemizedSection(_ liveState: ReceiptLiveState) -> some View {
        let claimedItems = liveState.items.filter { $0.viewerClaimedQuantity > 0 }
        if !claimedItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your items")
                    .font(TabbyType.label)
                    .textCase(.uppercase)
                    .foregroundStyle(TabbyColor.ink.opacity(0.56))

                ForEach(Array(claimedItems.enumerated()), id: \.element.id) { index, item in
                    HStack {
                        Text(item.name)
                            .font(TabbyType.body)
                            .foregroundStyle(TabbyColor.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("×\(item.viewerClaimedQuantity)")
                            .font(TabbyType.caption)
                            .foregroundStyle(TabbyColor.ink.opacity(0.5))
                            .monospacedDigit()
                        Text(activityCurrencyText(item.viewerClaimedTotal))
                            .font(TabbyType.bodyBold)
                            .foregroundStyle(TabbyColor.ink)
                            .monospacedDigit()
                    }
                    if index < claimedItems.count - 1 {
                        Divider()
                            .overlay(TabbyColor.subtle.opacity(0.7))
                    }
                }

                if let viewerSettlement = liveState.viewerSettlement, viewerSettlement.extraFeesShare > 0 {
                    Divider().overlay(TabbyColor.subtle.opacity(0.7))
                    let hasBackendBreakdown = viewerSettlement.taxShare > 0 || viewerSettlement.gratuityShare > 0
                    let taxVal = hasBackendBreakdown ? viewerSettlement.taxShare : estimatedFeeShare(receiptFee: liveState.tax, viewerSettlement: viewerSettlement, liveState: liveState)
                    let gratVal = hasBackendBreakdown ? viewerSettlement.gratuityShare : estimatedFeeShare(receiptFee: liveState.gratuity, viewerSettlement: viewerSettlement, liveState: liveState)
                    let otherVal: Double = {
                        let o = viewerSettlement.extraFeesShare - taxVal - gratVal
                        return o > 0.005 ? o : 0
                    }()

                    if taxVal > 0 || gratVal > 0 {
                        if taxVal > 0 {
                            feeBreakdownRow(title: taxLabel(for: liveState), value: taxVal)
                        }
                        if gratVal > 0 {
                            feeBreakdownRow(title: "Gratuity", value: gratVal)
                        }
                        if otherVal > 0 {
                            feeBreakdownRow(title: "Other fees", value: otherVal)
                        }
                    } else {
                        feeBreakdownRow(title: "Extra fees", value: viewerSettlement.extraFeesShare)
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(TabbyColor.subtle.opacity(0.8), lineWidth: 1)
                    )
            )
        }
    }

    private func settlementRow(title: String, value: Double, emphasized: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(emphasized ? TabbyType.bodyBold : TabbyType.body)
                .foregroundStyle(TabbyColor.ink)
            Spacer()
            Text(activityCurrencyText(value))
                .font(emphasized ? TabbyType.bodyBold : TabbyType.body)
                .monospacedDigit()
                .foregroundStyle(TabbyColor.ink)
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
                        .font(TabbyType.body)
                        .foregroundStyle(TabbyColor.ink)
                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(TabbyColor.ink.opacity(0.35))
                            .rotationEffect(.degrees(isSettlementFeesExpanded ? 90 : 0))
                    }
                    Spacer()
                    Text(activityCurrencyText(viewerSettlement.extraFeesShare))
                        .font(TabbyType.body)
                        .monospacedDigit()
                        .foregroundStyle(TabbyColor.ink)
                }
            }
            .buttonStyle(.plain)

            if isSettlementFeesExpanded && canExpand {
                VStack(spacing: 6) {
                    if taxVal > 0 {
                        feeBreakdownRow(title: taxLabel(for: liveState), value: taxVal)
                    }
                    if gratVal > 0 {
                        let label: String = {
                            if let pct = liveState.gratuityPercent, pct > 0 {
                                let formatted = pct.truncatingRemainder(dividingBy: 1) == 0
                                    ? String(format: "%.0f", pct)
                                    : String(format: "%.1f", pct)
                                return "Gratuity (\(formatted)%)"
                            }
                            return "Gratuity"
                        }()
                        feeBreakdownRow(title: label, value: gratVal)
                    }
                    if otherVal > 0 {
                        feeBreakdownRow(title: "Other fees", value: otherVal)
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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
                .font(TabbyType.caption)
                .foregroundStyle(TabbyColor.ink.opacity(0.56))
            Spacer()
            Text(activityCurrencyText(value))
                .font(TabbyType.caption)
                .foregroundStyle(TabbyColor.ink.opacity(0.7))
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
                                        quantityButton(symbol: "minus", enabled: item.viewerClaimedQuantity > 0 && !isViewerClaimsLocked(in: liveState)) {
                                            Task {
                                                await model.adjustClaim(itemKey: item.id, delta: -1)
                                            }
                                        }

                                        Text("\(item.viewerClaimedQuantity)")
                                            .font(TabbyType.bodyBold)
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
                        .fill(enabled ? TabbyColor.ink : TabbyColor.ink.opacity(0.15))
                )
                .foregroundStyle(enabled ? TabbyColor.canvas : TabbyColor.ink.opacity(0.42))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func synchronizeTransientSheets(for state: ReceiptActivityViewModel.State) {
        guard case .ready(let liveState) = state else {
            isSettlementSheetPresented = false
            isPaymentSheetPresented = false
            hasAutoPresentedPaymentSheet = false
            return
        }

        isSettlementSheetPresented = shouldPresentSettlementSheet(in: liveState)

        if liveState.settlementPhase != "finalized" {
            isPaymentSheetPresented = false
            hasAutoPresentedPaymentSheet = false
            return
        }

        guard !isViewerHost(in: liveState) else {
            isPaymentSheetPresented = false
            return
        }

        if !hasAutoPresentedPaymentSheet {
            isPaymentSheetPresented = true
            hasAutoPresentedPaymentSheet = true
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
                return "Tracking payments"
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
            if isViewerHost(in: liveState) { return true }
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
            if !isViewerHost(in: liveState) {
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
        let note = "Tabby split \(liveState.code)"

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
        case .cashApp:
            guard let cashtag = liveState.hostPaymentOptions?.cashAppCashtag?.trimmingCharacters(in: .whitespacesAndNewlines), !cashtag.isEmpty else {
                model.actionErrorMessage = "\(hostLabel.prefix(1).uppercased() + hostLabel.dropFirst()) is missing a Cash App cashtag."
                return
            }
            let cleanedCashtag = cashtag.trimmingCharacters(in: CharacterSet(charactersIn: "$") )
            if let url = URL(string: "https://cash.app/$\(cleanedCashtag)/\(amount)") {
                openURL(url)
            }
        case .zelle:
            guard let contact = liveState.hostPaymentOptions?.zelleContact?.trimmingCharacters(in: .whitespacesAndNewlines), !contact.isEmpty else {
                model.actionErrorMessage = "\(hostLabel.prefix(1).uppercased() + hostLabel.dropFirst()) is missing a Zelle contact."
                return
            }
            UIPasteboard.general.string = contact
            showToast("Copied Zelle contact")
        case .cashApplePay:
            UIPasteboard.general.string = amount
            showToast("Copied amount to pay")
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
            return "Unsubmit if you need to edit your claims."
        }
        return "You can unsubmit any time before finalization."
    }

    private func hostFinalizeGuidance(_ liveState: ReceiptLiveState) -> some View {
        let blockers = finalizeBlockers(in: liveState)
        return VStack(alignment: .leading, spacing: 8) {
            if blockers.isEmpty {
                Text("Everything is ready for finalization.")
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.mint)
            } else {
                ForEach(blockers, id: \.self) { blocker in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TabbyColor.ink.opacity(0.46))
                            .padding(.top, 1)
                        Text(blocker)
                            .font(TabbyType.caption)
                            .foregroundStyle(TabbyColor.ink.opacity(0.7))
                    }
                }
            }
        }
        .padding(12)
        .activityPanel(cornerRadius: 14)
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
    }

    private func participantIndicator(for participant: ReceiptLiveParticipant, liveState: ReceiptLiveState) -> ParticipantIndicator? {
        if participant.paymentStatus == "confirmed" {
            return .paid
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
                                .tint(TabbyColor.ink.opacity(0.5))
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
            .fill(TabbyColor.canvas.opacity(0.7))
            .overlay(
                Text(initialsText)
                    .font(TabbyType.bodyBold)
                    .foregroundStyle(TabbyColor.ink)
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
            .font(TabbyType.caption)
            .foregroundStyle(TabbyColor.canvas.opacity(0.95))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.38))
            )
    }

    private func paymentActionCard(method: PaymentActionMethod, liveState: ReceiptLiveState) -> some View {
        let style = style(for: method)
        return Button {
            handlePaymentTap(method: method, liveState: liveState)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: style.iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(style.iconBackground)
                    )
                    .foregroundStyle(style.iconForeground)

                VStack(alignment: .leading, spacing: 2) {
                    Text(method.title)
                        .font(TabbyType.bodyBold)
                        .foregroundStyle(TabbyColor.ink)
                    Text(methodDetail(for: method, liveState: liveState))
                        .font(TabbyType.caption)
                        .foregroundStyle(TabbyColor.ink.opacity(0.58))
                }

                Spacer(minLength: 10)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(TabbyColor.ink.opacity(0.54))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(style.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(style.stroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isPrimaryActionPending)
    }

    private func methodDetail(for method: PaymentActionMethod, liveState: ReceiptLiveState) -> String {
        let hostLabel = resolvedHostLabel(in: liveState)
        switch method {
        case .venmo:
            let username = liveState.hostPaymentOptions?.venmoUsername?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let username, !username.isEmpty {
                return "@\(username.trimmingCharacters(in: CharacterSet(charactersIn: "@")))"
            }
            return "Open Venmo and prefill amount"
        case .cashApp:
            let cashtag = liveState.hostPaymentOptions?.cashAppCashtag?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cashtag, !cashtag.isEmpty {
                let cleaned = cashtag.trimmingCharacters(in: CharacterSet(charactersIn: "$"))
                return "$\(cleaned)"
            }
            return "Open Cash App and prefill amount"
        case .zelle:
            let contact = liveState.hostPaymentOptions?.zelleContact?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let contact, !contact.isEmpty {
                return "Copy \(contact)"
            }
            return "Copy \(hostLabel)'s Zelle contact"
        case .cashApplePay:
            return "Use cash or Apple Pay"
        }
    }

    private func style(for method: PaymentActionMethod) -> (
        iconName: String,
        iconForeground: Color,
        iconBackground: Color,
        background: Color,
        stroke: Color
    ) {
        switch method {
        case .venmo:
            return (
                iconName: "paperplane.circle.fill",
                iconForeground: Color(red: 0.03, green: 0.35, blue: 0.83),
                iconBackground: Color(red: 0.87, green: 0.92, blue: 1),
                background: Color(red: 0.97, green: 0.99, blue: 1),
                stroke: Color(red: 0.85, green: 0.9, blue: 0.98)
            )
        case .cashApp:
            return (
                iconName: "dollarsign.circle.fill",
                iconForeground: Color(red: 0.08, green: 0.55, blue: 0.32),
                iconBackground: Color(red: 0.87, green: 0.97, blue: 0.9),
                background: Color(red: 0.96, green: 0.99, blue: 0.97),
                stroke: Color(red: 0.84, green: 0.93, blue: 0.86)
            )
        case .zelle:
            return (
                iconName: "doc.on.doc.fill",
                iconForeground: Color(red: 0.7, green: 0.41, blue: 0.06),
                iconBackground: Color(red: 1, green: 0.94, blue: 0.83),
                background: Color(red: 1, green: 0.98, blue: 0.95),
                stroke: Color(red: 0.95, green: 0.89, blue: 0.78)
            )
        case .cashApplePay:
            return (
                iconName: "apple.logo",
                iconForeground: TabbyColor.canvas,
                iconBackground: TabbyColor.ink.opacity(0.84),
                background: TabbyColor.ink.opacity(0.07),
                stroke: TabbyColor.subtle
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
                return "Settlement finalized"
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
                return "Confirm each guest payment as it comes in."
            }
            return "Tap your payment method. \(hostLabel.prefix(1).uppercased() + hostLabel.dropFirst()) will confirm payments."
        }

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

private struct LivePulseDot: View {
    var size: CGFloat = 8
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(TabbyColor.mint)
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
            return "Use Zelle"
        case .cashApplePay:
            return "Cash / Apple Pay"
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
    @Published var pendingParticipantKeys: Set<String> = []
    @Published var isPrimaryActionPending = false
    @Published var actionErrorMessage: String?

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
                            self.state = .error("This receipt is no longer available.")
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
