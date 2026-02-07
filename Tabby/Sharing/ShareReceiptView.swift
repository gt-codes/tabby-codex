import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct ShareReceiptView: View {
    let receipt: Receipt
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ReceiptShareViewModel
    @State private var didCopyLink = false
    @State private var copyResetTask: Task<Void, Never>?

    init(receipt: Receipt) {
        self.receipt = receipt
        _model = StateObject(wrappedValue: ReceiptShareViewModel(receipt: receipt))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TabbyGradientBackground()
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Share receipt")
                                .font(TabbyType.display)
                                .foregroundStyle(TabbyColor.ink)
                            Text("Let friends scan the QR code to claim their items.")
                                .font(TabbyType.body)
                                .foregroundStyle(TabbyColor.ink.opacity(0.65))
                        }

                        shareCard

                        ReceiptPreviewCard(receipt: receipt)
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
            await model.start()
        }
        .onDisappear {
            copyResetTask?.cancel()
        }
    }

    @ViewBuilder
    private var shareCard: some View {
        VStack(spacing: 16) {
            switch model.state {
            case .idle, .loading:
                ProgressView()
                    .tint(TabbyColor.ink)
                Text("Preparing your share link")
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
            case .error(let message):
                Text(message)
                    .font(TabbyType.body)
                    .foregroundStyle(TabbyColor.ink)
                Button("Try again") {
                    Task { await model.start(force: true) }
                }
                .font(TabbyType.bodyBold)
            case .ready(let payload):
                if let qrImage = QRCodeGenerator.image(from: payload.url.absoluteString) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.white)
                        )
                }

                VStack(spacing: 6) {
                    Text("Share code")
                        .font(TabbyType.label)
                        .foregroundStyle(TabbyColor.ink.opacity(0.6))
                        .textCase(.uppercase)
                    Text(payload.code)
                        .font(TabbyType.title)
                        .foregroundStyle(TabbyColor.ink)
                        .tracking(2)
                    
                }

                HStack(spacing: 12) {
                    Button {
                        copyLink(payload.url.absoluteString)
                    } label: {
                        Label(didCopyLink ? "Copied" : "Copy link", systemImage: didCopyLink ? "checkmark" : "link")
                            .font(TabbyType.bodyBold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(TabbyColor.canvas)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(TabbyColor.subtle, lineWidth: 1)
                                    )
                            )
                            .contentTransition(.opacity)
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.2), value: didCopyLink)

                    ShareLink(item: payload.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(TabbyType.bodyBold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(TabbyColor.ink)
                            )
                            .foregroundStyle(TabbyColor.canvas)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(TabbyColor.subtle, lineWidth: 1)
                )
        )
    }

    private func copyLink(_ value: String) {
        UIPasteboard.general.string = value
        copyResetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            didCopyLink = true
        }
        copyResetTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    didCopyLink = false
                }
            }
        }
    }
}

final class ReceiptShareViewModel: ObservableObject {
    enum ShareState {
        case idle
        case loading
        case ready(SharePayload)
        case error(String)
    }

    struct SharePayload {
        let id: String
        let code: String
        let url: URL
    }

    @Published private(set) var state: ShareState = .idle

    private let receipt: Receipt

    init(receipt: Receipt) {
        self.receipt = receipt
    }

    @MainActor
    func start(force: Bool = false) async {
        if case .ready = state, !force { return }
        state = .loading
        do {
            let existingCode = receipt.shareCode?.filter(\.isNumber) ?? ""
            if existingCode.count == 6 {
                let url = AppClipLink.url(for: existingCode)
                state = .ready(
                    SharePayload(
                        id: receipt.remoteID ?? receipt.id.uuidString,
                        code: existingCode,
                        url: url
                    )
                )
                return
            }

            let response = try await ConvexService.shared.createReceiptShare(receipt)
            let code = response.code.filter { $0.isNumber }
            guard code.count == 6 else {
                throw ReceiptShareError.invalidShareCode
            }
            let url = AppClipLink.url(for: code)
            state = .ready(SharePayload(id: response.id, code: code, url: url))
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}

enum AppClipLink {
    static let baseURL = URL(string: "https://tabby-api.vercel.app/clip")!

    static func url(for receiptCode: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "rid", value: receiptCode)]
        return components?.url ?? baseURL
    }
}

enum QRCodeGenerator {
    private static let context = CIContext()
    private static let filter = CIFilter.qrCodeGenerator()

    static func image(from text: String) -> UIImage? {
        filter.message = Data(text.utf8)
        guard let outputImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: transform)
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct ReceiptPreviewCard: View {
    let receipt: Receipt

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Receipt summary")
                    .font(TabbyType.label)
                    .textCase(.uppercase)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
                Spacer()
                Text(receipt.date.formatted(date: .abbreviated, time: .shortened))
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
            }

            ForEach(receipt.items.prefix(4)) { item in
                HStack {
                    Text(item.name)
                        .font(TabbyType.caption)
                    Spacer()
                    Text("x\(item.quantity)")
                        .font(TabbyType.caption)
                        .foregroundStyle(TabbyColor.ink.opacity(0.6))
                }
            }

            if receipt.items.count > 4 {
                Text("+ \(receipt.items.count - 4) more items")
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
            }

            Divider()
                .overlay(TabbyColor.subtle)

            HStack {
                Text("Total")
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
                Spacer()
                Text(currencyText(receipt.total))
                    .font(TabbyType.bodyBold)
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
}

private let tabbyCurrencyCode = Locale.current.currencyCode ?? "USD"

private func currencyText(_ value: Double) -> String {
    value.formatted(.currency(code: tabbyCurrencyCode))
}
