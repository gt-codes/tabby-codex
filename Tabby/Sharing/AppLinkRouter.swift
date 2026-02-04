import Foundation

final class AppLinkRouter: ObservableObject {
    @Published var joinReceiptId: String?

    func handle(url: URL) {
        guard let code = Self.extractJoinCode(from: url) else { return }
        joinReceiptId = code
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
