import ConvexMobile
import Foundation

enum ConvexConfig {
    static let deploymentUrl = "https://clever-narwhal-292.convex.cloud"
}

enum ReceiptShareError: LocalizedError {
    case invalidPayload
    case invalidShareCode

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "We couldn't prepare this receipt for sharing."
        case .invalidShareCode:
            return "The server returned an invalid share code."
        }
    }
}

struct ShareReceiptResponse: Decodable {
    let id: String
    let code: String
}

private struct RecentReceiptShareResponse: Decodable {
    let id: String
    let code: String
    let receiptJson: String
    let createdAt: Double
    let clientReceiptId: String?
}

final class ConvexService {
    static let shared = ConvexService()

    private let client: ConvexClient
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        client = ConvexClient(deploymentUrl: ConvexConfig.deploymentUrl)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func createReceiptShare(_ receipt: Receipt) async throws -> ShareReceiptResponse {
        let data = try encoder.encode(receipt)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ReceiptShareError.invalidPayload
        }
        let response: ShareReceiptResponse = try await client.mutation("receipts:create", with: [
            "clientReceiptId": receipt.id.uuidString,
            "receiptJson": json
        ])
        return response
    }

    func fetchReceiptShare(_ receiptCode: String) async throws -> Receipt? {
        let stream = client.subscribe(
            to: "receipts:get",
            with: ["code": receiptCode],
            yielding: String?.self
        ).values

        for try await payload in stream {
            guard let payload else { return nil }
            let data = Data(payload.utf8)
            return try decoder.decode(Receipt.self, from: data)
        }

        return nil
    }

    func fetchRecentReceipts(limit: Int = 20) async throws -> [Receipt] {
        let boundedLimit = max(1, min(limit, 100))
        let stream = client.subscribe(
            to: "receipts:listRecent",
            with: ["limit": Double(boundedLimit)],
            yielding: [RecentReceiptShareResponse].self
        ).values

        for try await payload in stream {
            return payload.compactMap { share in
                guard let data = share.receiptJson.data(using: .utf8),
                      let decodedReceipt = try? decoder.decode(Receipt.self, from: data) else {
                    return nil
                }

                let restoredId = UUID(uuidString: share.clientReceiptId ?? "") ?? decodedReceipt.id
                return Receipt(
                    id: restoredId,
                    date: Date(timeIntervalSince1970: share.createdAt / 1000),
                    items: decodedReceipt.items
                )
            }
        }

        return []
    }
}
