import Foundation

// MARK: - Payment Confirmation Payload

struct PaymentConfirmationPayload: Identifiable, Equatable {
    let id = UUID()
    let receiptCode: String
    let participantKey: String
    let guestName: String
    let amount: Double
    let paymentMethod: String

    init?(userInfo: [AnyHashable: Any]) {
        guard
            let receiptCode = userInfo["receiptCode"] as? String,
            let participantKey = userInfo["participantKey"] as? String,
            let guestName = userInfo["guestName"] as? String,
            let amount = userInfo["amount"] as? Double,
            let paymentMethod = userInfo["paymentMethod"] as? String
        else {
            return nil
        }

        self.receiptCode = receiptCode
        self.participantKey = participantKey
        self.guestName = guestName
        self.amount = amount
        self.paymentMethod = paymentMethod
    }

    var paymentMethodLabel: String {
        switch paymentMethod {
        case "venmo": return "Venmo"
        case "cash_app": return "Cash App"
        case "zelle": return "Zelle"
        case "cash_apple_pay": return "Cash / Apple Pay"
        default: return paymentMethod.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - App Link Router

final class AppLinkRouter: ObservableObject {
    @Published var joinReceiptId: String?
    /// Set when the host taps a payment notification. The receipt code routes
    /// navigation while `confirmParticipantKey` identifies which guest to confirm.
    @Published var pendingPaymentConfirmation: PaymentConfirmationPayload?

    func handle(url: URL) {
        guard let code = Self.extractJoinCode(from: url) else { return }
        joinReceiptId = code
    }

    func handlePaymentNotification(_ payload: PaymentConfirmationPayload) {
        pendingPaymentConfirmation = payload
        // Also trigger navigation to the receipt via the join flow.
        joinReceiptId = payload.receiptCode
    }

    static func extractJoinCode(from url: URL) -> String? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let queryKeys = ["rid", "code", "receipt", "receiptId", "shareCode"]
            for key in queryKeys {
                if let value = components.queryItems?.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame })?.value,
                   let normalized = normalizeCode(value) {
                    return normalized
                }
            }

            for pathComponent in components.path.split(separator: "/").reversed() {
                if let normalized = normalizeCode(String(pathComponent)) {
                    return normalized
                }
            }
        }

        if let normalized = firstSixDigitToken(in: url.absoluteString) {
            return normalized
        }

        return nil
    }

    private static func normalizeCode(_ value: String) -> String? {
        let digitsOnly = value.filter(\.isNumber)
        return digitsOnly.count == 6 ? digitsOnly : nil
    }

    private static func firstSixDigitToken(in value: String) -> String? {
        guard let range = value.range(of: #"(?<!\d)\d{6}(?!\d)"#, options: .regularExpression) else {
            return nil
        }
        return String(value[range])
    }
}
