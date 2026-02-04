import SwiftUI

struct JoinReceiptView: View {
    let receiptId: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: JoinReceiptViewModel

    init(receiptId: String) {
        self.receiptId = receiptId
        _model = StateObject(wrappedValue: JoinReceiptViewModel(receiptCode: receiptId))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TabbyGradientBackground()
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Receipt from a friend")
                                .font(TabbyType.display)
                                .foregroundStyle(TabbyColor.ink)
                            Text("Review the items and claim what you ordered.")
                                .font(TabbyType.body)
                                .foregroundStyle(TabbyColor.ink.opacity(0.65))
                        }

                        content
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await model.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                    .tint(TabbyColor.ink)
                Text("Fetching receipt")
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(TabbyColor.subtle, lineWidth: 1)
                    )
            )
        case .error(let message):
            VStack(spacing: 12) {
                Text(message)
                    .font(TabbyType.body)
                    .foregroundStyle(TabbyColor.ink)
                Button("Try again") {
                    Task { await model.load(force: true) }
                }
                .font(TabbyType.bodyBold)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(TabbyColor.subtle, lineWidth: 1)
                    )
            )
        case .ready(let receipt):
            ReceiptDetailCard(receipt: receipt)

            Button {
                // TODO: claim flow
            } label: {
                Text("Claim items")
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
                    .foregroundStyle(TabbyColor.canvas)
            }
        }
    }
}

final class JoinReceiptViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case ready(Receipt)
        case error(String)
    }

    @Published private(set) var state: State = .idle
    private let receiptCode: String

    init(receiptCode: String) {
        self.receiptCode = receiptCode
    }

    @MainActor
    func load(force: Bool = false) async {
        if case .ready = state, !force { return }
        state = .loading
        do {
            if let receipt = try await ConvexService.shared.fetchReceiptShare(receiptCode) {
                state = .ready(receipt)
            } else {
                state = .error("We couldn't find that receipt.")
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}

private struct ReceiptDetailCard: View {
    let receipt: Receipt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Items")
                    .font(TabbyType.label)
                    .textCase(.uppercase)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
                Spacer()
                Text("\(receipt.items.count) total")
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
            }

            ForEach(receipt.items) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(TabbyType.bodyBold)
                            .foregroundStyle(TabbyColor.ink)
                        Text("Qty \(item.quantity)")
                            .font(TabbyType.caption)
                            .foregroundStyle(TabbyColor.ink.opacity(0.6))
                    }
                    Spacer()
                    Text(priceText(for: item))
                        .font(TabbyType.bodyBold)
                        .foregroundStyle(TabbyColor.ink)
                        .monospacedDigit()
                }
                if item.id != receipt.items.last?.id {
                    Divider()
                        .overlay(TabbyColor.subtle)
                }
            }

            HStack {
                Text("Total")
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
                Spacer()
                Text(currencyText(receipt.total))
                    .font(TabbyType.bodyBold)
                    .foregroundStyle(TabbyColor.ink)
                    .monospacedDigit()
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
        )
    }

    private func priceText(for item: ReceiptItem) -> String {
        guard let price = item.price else { return "—" }
        return String(format: "$%.2f", price)
    }
}

private let tabbyCurrencyCode = Locale.current.currencyCode ?? "USD"

private func currencyText(_ value: Double) -> String {
    value.formatted(.currency(code: tabbyCurrencyCode))
}
