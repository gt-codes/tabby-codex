import AuthenticationServices
import ConvexMobile
import Foundation
import Security
import UIKit

enum ConvexConfig {
    static let deploymentUrl = "https://clever-narwhal-292.convex.cloud"
}

enum ConvexAuthError: LocalizedError {
    case invalidCredential
    case missingIdentityToken
    case noCachedSession

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return "Sign in with Apple did not return a valid credential."
        case .missingIdentityToken:
            return "Sign in with Apple did not return an identity token."
        case .noCachedSession:
            return "No cached Apple sign-in session exists."
        }
    }
}

enum ReceiptShareError: LocalizedError {
    case invalidShareCode

    var errorDescription: String? {
        switch self {
        case .invalidShareCode:
            return "The server returned an invalid share code."
        }
    }
}

enum ProfilePhotoUploadError: LocalizedError {
    case invalidUploadUrl
    case uploadFailed(statusCode: Int, responseBody: String?)
    case missingStorageId

    var errorDescription: String? {
        switch self {
        case .invalidUploadUrl:
            return "Could not create a profile photo upload URL."
        case .uploadFailed(let statusCode, let responseBody):
            if let responseBody, !responseBody.isEmpty {
                return "Profile photo upload failed (\(statusCode)): \(responseBody)"
            }
            return "Profile photo upload failed (\(statusCode))."
        case .missingStorageId:
            return "Upload completed, but no file id was returned."
        }
    }
}

struct ShareReceiptResponse: Decodable {
    let id: String
    let code: String
}

struct UserProfile {
    let name: String?
    let email: String?
    let pictureURL: String?
    let preferredPaymentMethod: String?
    let absorbExtraCents: Bool
    let venmoEnabled: Bool
    let venmoUsername: String?
    let cashAppEnabled: Bool
    let cashAppCashtag: String?
    let zelleEnabled: Bool
    let zelleContact: String?
    let cashApplePayEnabled: Bool
}

struct BillUsageSummary {
    let freeLimit: Int
    let freeUsed: Int
    let freeRemaining: Int
    let periodStartAt: Date
    let periodEndAt: Date
    let billCreditsBalance: Int
    let canHostNewBill: Bool
}

struct CreditPurchaseRedemption {
    let applied: Bool
    let transactionId: String
    let creditsGranted: Int
    let billCreditsBalance: Int
}

struct ReceiptLiveParticipant: Identifiable, Hashable {
    let id: String
    let name: String
    let email: String?
    let avatarURL: String?
    let joinedAt: Date
    let isCurrentUser: Bool
    let isSubmitted: Bool
    let paymentStatus: String?
    let paymentMethod: String?
    let paymentAmount: Double?
    let itemSubtotal: Double
    let taxShare: Double
    let gratuityShare: Double
    let extraFeesShare: Double
    let roundingAdjustment: Double
    let totalDue: Double
}

struct ReceiptLiveItem: Identifiable, Hashable {
    let id: String
    let name: String
    let quantity: Int
    let remainingQuantity: Int
    let viewerClaimedQuantity: Int
    let price: Double?

    var unitPrice: Double? {
        guard let price else { return nil }
        return price / Double(max(quantity, 1))
    }

    var viewerClaimedTotal: Double {
        (unitPrice ?? 0) * Double(viewerClaimedQuantity)
    }
}

struct ReceiptLiveState: Hashable {
    let remoteId: String
    let code: String
    let createdAt: Date
    let isActive: Bool
    let settlementPhase: String
    let archivedReason: String?
    let viewerParticipantKey: String?
    let viewerRemoved: Bool
    let hostParticipantKey: String?
    let hostDisplayName: String?
    let hostHasPaymentOptions: Bool
    let hostPaymentOptions: ReceiptHostPaymentOptions?
    let allParticipantsSubmitted: Bool
    let unclaimedItemCount: Int
    let extraFeesTotal: Double
    let tax: Double?
    let gratuity: Double?
    let otherFees: Double?
    let gratuityPercent: Double?
    let participants: [ReceiptLiveParticipant]
    let items: [ReceiptLiveItem]
    let viewerSettlement: ReceiptViewerSettlement?
    let hostPaymentQueue: [ReceiptHostPaymentQueueItem]
    let receiptImageUrl: String?

    var claimedTotal: Double {
        items.reduce(0) { partial, item in
            partial + item.viewerClaimedTotal
        }
    }
}

struct ReceiptHostPaymentOptions: Hashable {
    let preferredPaymentMethod: String?
    let venmoEnabled: Bool
    let venmoUsername: String?
    let cashAppEnabled: Bool
    let cashAppCashtag: String?
    let zelleEnabled: Bool
    let zelleContact: String?
    let cashApplePayEnabled: Bool
}

struct ReceiptViewerSettlement: Hashable {
    let itemSubtotal: Double
    let taxShare: Double
    let gratuityShare: Double
    let extraFeesShare: Double
    let roundingAdjustment: Double
    let totalDue: Double
    let canPay: Bool
    let paymentStatus: String?
    let paymentMethod: String?
}

struct ReceiptHostPaymentQueueItem: Identifiable, Hashable {
    let id: String
    let name: String
    let amountDue: Double
    let paymentStatus: String?
    let paymentMethod: String?
    let paymentAmount: Double?
}

private struct RemoteReceiptItemResponse: Decodable {
    let clientItemId: String?
    let name: String
    let quantity: Double
    let price: Double?
    let sortOrder: Double
}

private struct RemoteReceiptResponse: Decodable {
    let id: String
    let code: String
    let items: [RemoteReceiptItemResponse]
    let createdAt: Double
    let clientReceiptId: String?
    let isActive: Bool?
    let settlementPhase: String?
    let finalizedAt: Double?
    let archivedReason: String?
    let receiptTotal: Double?
    let subtotal: Double?
    let tax: Double?
    let gratuity: Double?
    let extraFeesTotal: Double?
    let canManage: Bool?
    let wasArchivedEver: Bool?
}

private struct RemoteReceiptLiveParticipantResponse: Decodable {
    let participantKey: String
    let displayName: String
    let participantEmail: String?
    let avatarUrl: String?
    let joinedAt: Double
    let isSubmitted: Bool?
    let submittedAt: Double?
    let paymentStatus: String?
    let paymentMethod: String?
    let paymentAmount: Double?
    let itemSubtotal: Double?
    let taxShare: Double?
    let gratuityShare: Double?
    let extraFeesShare: Double?
    let roundingAdjustment: Double?
    let totalDue: Double?
}

private struct RemoteReceiptLiveItemResponse: Decodable {
    let key: String
    let clientItemId: String?
    let name: String
    let quantity: Double
    let price: Double?
    let sortOrder: Double
    let claimedQuantity: Double
    let viewerClaimedQuantity: Double
    let remainingQuantity: Double
}

private struct RemoteReceiptLiveResponse: Decodable {
    let id: String
    let code: String
    let createdAt: Double
    let isActive: Bool?
    let settlementPhase: String?
    let archivedReason: String?
    let receiptTotal: Double?
    let subtotal: Double?
    let tax: Double?
    let gratuity: Double?
    let extraFeesTotal: Double?
    let otherFees: Double?
    let gratuityPercent: Double?
    let viewerParticipantKey: String?
    let viewerRemoved: Bool?
    let hostParticipantKey: String?
    let hostDisplayName: String?
    let hostHasPaymentOptions: Bool?
    let hostPaymentOptions: RemoteReceiptLiveHostPaymentOptionsResponse?
    let allParticipantsSubmitted: Bool?
    let unclaimedItemCount: Double?
    let participants: [RemoteReceiptLiveParticipantResponse]
    let items: [RemoteReceiptLiveItemResponse]
    let viewerSettlement: RemoteReceiptLiveViewerSettlementResponse?
    let hostPaymentQueue: [RemoteReceiptLiveHostQueueResponse]?
    let receiptImageUrl: String?
}

private struct RemoteReceiptLiveViewerSettlementResponse: Decodable {
    let itemSubtotal: Double?
    let taxShare: Double?
    let gratuityShare: Double?
    let extraFeesShare: Double?
    let roundingAdjustment: Double?
    let totalDue: Double?
    let canPay: Bool?
    let paymentStatus: String?
    let paymentMethod: String?
}

private struct RemoteReceiptLiveHostQueueResponse: Decodable {
    let participantKey: String
    let displayName: String
    let amountDue: Double?
    let paymentStatus: String?
    let paymentMethod: String?
    let paymentAmount: Double?
}

private struct RemoteReceiptLiveHostPaymentOptionsResponse: Decodable {
    let preferredPaymentMethod: String?
    let venmoEnabled: Bool?
    let venmoUsername: String?
    let cashAppEnabled: Bool?
    let cashAppCashtag: String?
    let zelleEnabled: Bool?
    let zelleContact: String?
    let cashApplePayEnabled: Bool?
}

private struct RemoteClaimUpdateResponse: Decodable {
    let appliedDelta: Double
    let quantity: Double
}

private struct RemoteSubmissionStatusResponse: Decodable {
    let isSubmitted: Bool
}

private struct RemoteFinalizeSettlementResponse: Decodable {
    let finalized: Bool
}

private struct RemoteRemoveParticipantResponse: Decodable {
    let removed: Bool
}

private struct RemoteMarkPaymentIntentResponse: Decodable {
    let marked: Bool
    let paymentStatus: String?
    let paymentAmount: Double?
    let paymentMethod: String?
}

private struct RemoteConfirmPaymentResponse: Decodable {
    let confirmed: Bool
    let archived: Bool?
}

private struct RemoteUpdateDisplayNameResponse: Decodable {
    let updated: Bool
}

private struct RemoteArchiveReceiptResponse: Decodable {
    let archived: Bool
}

private struct RemoteUnarchiveReceiptResponse: Decodable {
    let unarchived: Bool
}

private struct RemoteDestroyReceiptResponse: Decodable {
    let deleted: Bool
}

private struct RemoteUserResponse: Decodable {
    let name: String?
    let email: String?
    let pictureUrl: String?
    let preferredPaymentMethod: String?
    let absorbExtraCents: Bool?
    let venmoEnabled: Bool?
    let venmoUsername: String?
    let cashAppEnabled: Bool?
    let cashAppCashtag: String?
    let zelleEnabled: Bool?
    let zelleContact: String?
    let cashApplePayEnabled: Bool?
}

private struct RemoteBillingUsageSummaryResponse: Decodable {
    let freeLimit: Double
    let freeUsed: Double
    let freeRemaining: Double
    let periodStartAt: Double
    let periodEndAt: Double
    let billCreditsBalance: Double
    let canHostNewBill: Bool
}

private struct RemoteCreditPurchaseRedemptionResponse: Decodable {
    let applied: Bool
    let transactionId: String
    let creditsGranted: Double
    let billCreditsBalance: Double
}

private struct MutationIdResponse: Decodable {
    let id: String
}

private struct StorageUploadResponse: Decodable {
    let storageId: String
}

private struct GuestMigrationResponse: Decodable {
    let migratedCount: Int
}

private struct AppleAuthSession {
    let userID: String
    let idToken: String
}

private enum AppleAuthStorage {
    private static let userIDKey = "splt.apple.userID"
    private static let idTokenKey = "splt.apple.idToken"

    static func save(session: AppleAuthSession) {
        UserDefaults.standard.set(session.userID, forKey: userIDKey)
        UserDefaults.standard.set(session.idToken, forKey: idTokenKey)
    }

    static func loadSession() -> AppleAuthSession? {
        guard
            let userID = UserDefaults.standard.string(forKey: userIDKey),
            let idToken = UserDefaults.standard.string(forKey: idTokenKey),
            !userID.isEmpty,
            !idToken.isEmpty
        else {
            return nil
        }
        return AppleAuthSession(userID: userID, idToken: idToken)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: userIDKey)
        UserDefaults.standard.removeObject(forKey: idTokenKey)
    }
}

private enum GuestDeviceStorage {
    private static let service = "com.splt.money"
    private static let account = "splt.guest.device.id"
    private static let fallbackKey = "splt.guest.device.id.fallback"

    static func loadOrCreateDeviceID() -> String {
        if let keychainValue = loadFromKeychain() {
            return keychainValue
        }

        if
            let fallbackValue = UserDefaults.standard.string(forKey: fallbackKey),
            isValidDeviceID(fallbackValue)
        {
            _ = saveToKeychain(fallbackValue)
            return fallbackValue
        }

        let generated = UUID().uuidString.lowercased()
        if saveToKeychain(generated) {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
        } else {
            UserDefaults.standard.set(generated, forKey: fallbackKey)
        }
        return generated
    }

    private static func loadFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard
            status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8),
            isValidDeviceID(value)
        else {
            return nil
        }

        return value
    }

    @discardableResult
    private static func saveToKeychain(_ value: String) -> Bool {
        guard let encoded = value.data(using: .utf8) else {
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let insertPayload: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: encoded
        ]

        let addStatus = SecItemAdd(insertPayload as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return true
        }

        guard addStatus == errSecDuplicateItem else {
            return false
        }

        let updatePayload = [kSecValueData as String: encoded]
        let updateStatus = SecItemUpdate(query as CFDictionary, updatePayload as CFDictionary)
        return updateStatus == errSecSuccess
    }

    private static func isValidDeviceID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private final class AppleAuthProvider: NSObject, AuthProvider, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var onIdToken: (@Sendable (String?) -> Void)?
    private var continuation: CheckedContinuation<AppleAuthSession, Error>?

    func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> AppleAuthSession {
        self.onIdToken = onIdToken

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.continuation = continuation
                let request = ASAuthorizationAppleIDProvider().createRequest()
                request.requestedScopes = [.fullName, .email]

                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        }
    }

    func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> AppleAuthSession {
        self.onIdToken = onIdToken

        guard let cachedSession = AppleAuthStorage.loadSession() else {
            throw ConvexAuthError.noCachedSession
        }

        onIdToken(cachedSession.idToken)
        return cachedSession
    }

    func logout() async throws {
        AppleAuthStorage.clear()
        onIdToken?(nil)
    }

    func extractIdToken(from authResult: AppleAuthSession) -> String {
        authResult.idToken
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            finish(with: .failure(ConvexAuthError.invalidCredential))
            return
        }

        guard
            let tokenData = credential.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8),
            !idToken.isEmpty
        else {
            finish(with: .failure(ConvexAuthError.missingIdentityToken))
            return
        }

        let session = AppleAuthSession(userID: credential.user, idToken: idToken)
        AppleAuthStorage.save(session: session)
        onIdToken?(idToken)
        finish(with: .success(session))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(with: .failure(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let keyWindow = activeScene?.windows.first(where: { $0.isKeyWindow }) ?? activeScene?.windows.first
        return keyWindow ?? ASPresentationAnchor()
    }

    private func finish(with result: Result<AppleAuthSession, Error>) {
        let continuation = continuation
        self.continuation = nil

        switch result {
        case .success(let session):
            continuation?.resume(returning: session)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

final class ConvexService {
    static let shared = ConvexService()
    private static let authStateKey = "isSignedIn"

    private enum AuthVerificationResult {
        case valid
        case invalid
        case inconclusive
    }

    private let authProvider: AppleAuthProvider
    private let client: ConvexClientWithAuth<AppleAuthSession>
    private let guestDeviceId: String

    var hasCachedSession: Bool {
        AppleAuthStorage.loadSession() != nil
    }

    var analyticsAnonymousID: String {
        guestDeviceId
    }

    private init() {
        guestDeviceId = GuestDeviceStorage.loadOrCreateDeviceID()
        authProvider = AppleAuthProvider()
        client = ConvexClientWithAuth(deploymentUrl: ConvexConfig.deploymentUrl, authProvider: authProvider)
        let cachedSession = AppleAuthStorage.loadSession()
        UserDefaults.standard.set(cachedSession != nil, forKey: Self.authStateKey)

        if cachedSession != nil {
            Task {
                let cachedLogin = await client.loginFromCache()
                guard case .success = cachedLogin else {
                    await self.handleStaleAuth()
                    return
                }

                let authVerification = await self.verifyAuthOrRelogin()
                if authVerification == .invalid {
                    await self.handleStaleAuth()
                } else if authVerification == .valid {
                    // Auth is established — re-register the push token so the
                    // backend row gets our tokenIdentifier (it may have been
                    // registered before auth was ready).
                    NotificationManager.shared.reregisterTokenIfNeeded()
                }
            }
        }
    }

    @discardableResult
    func signInWithApple() async throws -> Bool {
        switch await client.login() {
        case .success:
            UserDefaults.standard.set(true, forKey: Self.authStateKey)
            await upsertAuthenticatedUser()
            // Re-register push token now that auth identity is available.
            NotificationManager.shared.reregisterTokenIfNeeded()
            return true
        case .failure(let error):
            throw error
        }
    }

    func signOut() async {
        await client.logout()
        UserDefaults.standard.set(false, forKey: Self.authStateKey)
    }

    func createReceiptShare(_ receipt: Receipt) async throws -> ShareReceiptResponse {
        let encodedItems: [ConvexEncodable?] = receipt.items.enumerated().map { index, item in
            var encodedItem: [String: ConvexEncodable?] = [
                "clientItemId": item.id.uuidString,
                "name": item.name,
                "quantity": Double(item.quantity),
                "sortOrder": Double(index)
            ]
            if let price = item.price {
                encodedItem["price"] = price
            }
            return encodedItem
        }

        var args: [String: ConvexEncodable?] = [
            "clientReceiptId": receipt.id.uuidString,
            "items": encodedItems,
            "guestDeviceId": guestDeviceId
        ]
        if let total = receipt.scannedTotal { args["receiptTotal"] = total }
        if let subtotal = receipt.scannedSubtotal { args["subtotal"] = subtotal }
        if let tax = receipt.scannedTax { args["tax"] = tax }
        if let gratuity = receipt.scannedGratuity { args["gratuity"] = gratuity }

        let response: ShareReceiptResponse = try await client.mutation("receipts:create", with: args)
        return response
    }

    func fetchReceiptShare(_ receiptCode: String) async throws -> Receipt? {
        let stream = client.subscribe(
            to: "receipts:get",
            with: ["code": receiptCode],
            yielding: RemoteReceiptResponse?.self
        ).values

        for try await payload in stream {
            guard let payload else { return nil }
            return toLocalReceipt(payload)
        }

        return nil
    }

    func joinReceipt(withCode receiptCode: String) async throws -> Receipt? {
        let payload: RemoteReceiptResponse? = try await client.mutation(
            "receipts:join",
            with: [
                "code": receiptCode,
                "guestDeviceId": guestDeviceId
            ]
        )
        guard let payload else { return nil }
        return toLocalReceipt(payload)
    }

    func observeReceiptLive(receiptCode: String) -> AsyncThrowingStream<ReceiptLiveState?, Error> {
        let stream = client.subscribe(
            to: "receipts:live",
            with: [
                "code": receiptCode,
                "guestDeviceId": guestDeviceId
            ],
            yielding: RemoteReceiptLiveResponse?.self
        ).values

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await payload in stream {
                        if let payload {
                            continuation.yield(self.toLocalReceiptLive(payload))
                        } else {
                            continuation.yield(nil)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func updateClaim(receiptCode: String, itemKey: String, delta: Int) async throws {
        let _: RemoteClaimUpdateResponse = try await client.mutation(
            "receipts:updateClaim",
            with: [
                "code": receiptCode,
                "itemKey": itemKey,
                "delta": Double(delta),
                "guestDeviceId": guestDeviceId
            ]
        )
    }

    func setSubmissionStatus(receiptCode: String, isSubmitted: Bool) async throws {
        let _: RemoteSubmissionStatusResponse = try await client.mutation(
            "receipts:setSubmissionStatus",
            with: [
                "code": receiptCode,
                "isSubmitted": isSubmitted,
                "guestDeviceId": guestDeviceId
            ]
        )
    }

    func removeParticipant(receiptCode: String, participantKey: String) async throws {
        let _: RemoteRemoveParticipantResponse = try await client.mutation(
            "receipts:removeParticipant",
            with: [
                "code": receiptCode,
                "participantKey": participantKey,
                "guestDeviceId": guestDeviceId
            ]
        )
    }

    func finalizeSettlement(receiptCode: String) async throws {
        let _: RemoteFinalizeSettlementResponse = try await client.mutation(
            "receipts:finalizeSettlement",
            with: [
                "code": receiptCode,
                "guestDeviceId": guestDeviceId
            ]
        )
    }

    func markPaymentIntent(receiptCode: String, method: String) async throws {
        let _: RemoteMarkPaymentIntentResponse = try await client.mutation(
            "receipts:markPaymentIntent",
            with: [
                "code": receiptCode,
                "method": method,
                "guestDeviceId": guestDeviceId
            ]
        )
    }

    func confirmPayment(receiptCode: String, participantKey: String) async throws {
        let _: RemoteConfirmPaymentResponse = try await client.mutation(
            "receipts:confirmPayment",
            with: [
                "code": receiptCode,
                "participantKey": participantKey,
                "guestDeviceId": guestDeviceId
            ]
        )
    }

    func updateParticipantDisplayName(receiptCode: String, displayName: String) async throws {
        let _: RemoteUpdateDisplayNameResponse = try await client.mutation(
            "receipts:updateParticipantDisplayName",
            with: [
                "code": receiptCode,
                "displayName": displayName,
                "guestDeviceId": guestDeviceId
            ]
        )
    }

    func fetchRecentReceipts(limit: Int = 20) async throws -> [Receipt] {
        let boundedLimit = max(1, min(limit, 100))
        let stream = client.subscribe(
            to: "receipts:listRecent",
            with: [
                "limit": Double(boundedLimit),
                "includeArchived": true,
                "guestDeviceId": guestDeviceId
            ],
            yielding: [RemoteReceiptResponse].self
        ).values

        for try await payload in stream {
            return payload.map(toLocalReceipt)
        }

        return []
    }

    func archiveReceipt(clientReceiptId: String) async throws -> Bool {
        let response: RemoteArchiveReceiptResponse = try await client.mutation(
            "receipts:archive",
            with: [
                "clientReceiptId": clientReceiptId,
                "guestDeviceId": guestDeviceId
            ]
        )

        return response.archived
    }

    func unarchiveReceipt(clientReceiptId: String) async throws -> Bool {
        let response: RemoteUnarchiveReceiptResponse = try await client.mutation(
            "receipts:unarchive",
            with: [
                "clientReceiptId": clientReceiptId,
                "guestDeviceId": guestDeviceId
            ]
        )

        return response.unarchived
    }

    func destroyReceipt(clientReceiptId: String) async throws -> Bool {
        let response: RemoteDestroyReceiptResponse = try await client.mutation(
            "receipts:destroy",
            with: [
                "clientReceiptId": clientReceiptId,
                "guestDeviceId": guestDeviceId
            ]
        )

        return response.deleted
    }

    func registerPushToken(apnsToken: String) async throws {
        let _: MutationIdResponse = try await client.mutation(
            "notifications:registerPushToken",
            with: [
                "apnsToken": apnsToken,
                "guestDeviceId": guestDeviceId
            ]
        )
    }

    func migrateGuestDataToSignedInAccount() async throws -> Int {
        let response: GuestMigrationResponse = try await client.mutation(
            "receipts:migrateGuestData",
            with: ["guestDeviceId": guestDeviceId]
        )
        return response.migratedCount
    }

    func fetchMyProfile() async throws -> UserProfile? {
        let stream = client.subscribe(
            to: "users:me",
            yielding: RemoteUserResponse?.self
        ).values

        for try await payload in stream {
            guard let payload else { return nil }
            return UserProfile(
                name: payload.name,
                email: payload.email,
                pictureURL: payload.pictureUrl,
                preferredPaymentMethod: payload.preferredPaymentMethod,
                absorbExtraCents: payload.absorbExtraCents ?? false,
                venmoEnabled: payload.venmoEnabled ?? false,
                venmoUsername: payload.venmoUsername,
                cashAppEnabled: payload.cashAppEnabled ?? false,
                cashAppCashtag: payload.cashAppCashtag,
                zelleEnabled: payload.zelleEnabled ?? false,
                zelleContact: payload.zelleContact,
                cashApplePayEnabled: payload.cashApplePayEnabled ?? false
            )
        }

        return nil
    }

    func fetchBillingUsageSummary() async throws -> BillUsageSummary {
        let stream = client.subscribe(
            to: "billing:getUsageSummary",
            yielding: RemoteBillingUsageSummaryResponse?.self
        ).values

        for try await payload in stream {
            guard let payload else { continue }
            return BillUsageSummary(
                freeLimit: max(0, Int(payload.freeLimit.rounded())),
                freeUsed: max(0, Int(payload.freeUsed.rounded())),
                freeRemaining: max(0, Int(payload.freeRemaining.rounded())),
                periodStartAt: Date(timeIntervalSince1970: payload.periodStartAt / 1000),
                periodEndAt: Date(timeIntervalSince1970: payload.periodEndAt / 1000),
                billCreditsBalance: max(0, Int(payload.billCreditsBalance.rounded())),
                canHostNewBill: payload.canHostNewBill
            )
        }

        throw NSError(domain: "ConvexService", code: 404, userInfo: [
            NSLocalizedDescriptionKey: "Billing usage summary not available."
        ])
    }

    func redeemCreditPurchase(
        transactionId: String,
        productId: String,
        purchasedAt: Date?
    ) async throws -> CreditPurchaseRedemption {
        var args: [String: ConvexEncodable?] = [
            "transactionId": transactionId,
            "productId": productId
        ]
        if let purchasedAt {
            args["purchasedAt"] = purchasedAt.timeIntervalSince1970 * 1000
        }
        let response: RemoteCreditPurchaseRedemptionResponse = try await client.mutation(
            "billing:redeemCreditPurchase",
            with: args
        )
        return CreditPurchaseRedemption(
            applied: response.applied,
            transactionId: response.transactionId,
            creditsGranted: max(0, Int(response.creditsGranted.rounded())),
            billCreditsBalance: max(0, Int(response.billCreditsBalance.rounded()))
        )
    }

    func updateMyProfile(
        name: String?,
        preferredPaymentMethod: String?,
        absorbExtraCents: Bool? = nil,
        venmoEnabled: Bool? = nil,
        venmoUsername: String? = nil,
        cashAppEnabled: Bool? = nil,
        cashAppCashtag: String? = nil,
        zelleEnabled: Bool? = nil,
        zelleContact: String? = nil,
        cashApplePayEnabled: Bool? = nil
    ) async throws {
        var args: [String: ConvexEncodable?] = [:]
        if let name { args["name"] = name }
        if let preferredPaymentMethod { args["preferredPaymentMethod"] = preferredPaymentMethod }
        if let absorbExtraCents { args["absorbExtraCents"] = absorbExtraCents }
        if let venmoEnabled { args["venmoEnabled"] = venmoEnabled }
        if let venmoUsername { args["venmoUsername"] = venmoUsername }
        if let cashAppEnabled { args["cashAppEnabled"] = cashAppEnabled }
        if let cashAppCashtag { args["cashAppCashtag"] = cashAppCashtag }
        if let zelleEnabled { args["zelleEnabled"] = zelleEnabled }
        if let zelleContact { args["zelleContact"] = zelleContact }
        if let cashApplePayEnabled { args["cashApplePayEnabled"] = cashApplePayEnabled }
        let _: MutationIdResponse = try await client.mutation(
            "users:updateProfile",
            with: args
        )
    }

    func uploadMyProfilePhoto(_ data: Data, contentType: String = "image/jpeg") async throws {
        let uploadUrl: String = try await client.mutation("users:generateProfilePhotoUploadUrl")
        guard let url = URL(string: uploadUrl) else {
            throw ProfilePhotoUploadError.invalidUploadUrl
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (responseData, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProfilePhotoUploadError.uploadFailed(statusCode: -1, responseBody: nil)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: responseData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProfilePhotoUploadError.uploadFailed(statusCode: httpResponse.statusCode, responseBody: body)
        }

        guard let storageId = parseStorageId(from: responseData) else {
            throw ProfilePhotoUploadError.missingStorageId
        }

        let _: MutationIdResponse = try await client.mutation(
            "users:setProfilePhoto",
            with: ["storageId": storageId]
        )
    }

    func uploadReceiptImage(_ imageData: Data, receiptCode: String, contentType: String = "image/jpeg") async throws {
        let uploadUrl: String = try await client.mutation(
            "receipts:generateReceiptImageUploadUrl",
            with: ["code": receiptCode, "guestDeviceId": guestDeviceId]
        )
        guard let url = URL(string: uploadUrl) else {
            throw ProfilePhotoUploadError.invalidUploadUrl
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (responseData, response) = try await URLSession.shared.upload(for: request, from: imageData)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProfilePhotoUploadError.uploadFailed(statusCode: -1, responseBody: nil)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: responseData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProfilePhotoUploadError.uploadFailed(statusCode: httpResponse.statusCode, responseBody: body)
        }

        guard let storageId = parseStorageId(from: responseData) else {
            throw ProfilePhotoUploadError.missingStorageId
        }

        let _: MutationIdResponse = try await client.mutation(
            "receipts:setReceiptImage",
            with: ["code": receiptCode, "storageId": storageId, "guestDeviceId": guestDeviceId]
        )
    }

    private func parseStorageId(from data: Data) -> String? {
        if let payload = try? JSONDecoder().decode(StorageUploadResponse.self, from: data),
           !payload.storageId.isEmpty {
            return payload.storageId
        }

        guard
            let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let storageId = jsonObject["storageId"] as? String,
            !storageId.isEmpty
        else {
            return nil
        }

        return storageId
    }

    private func toLocalReceipt(_ remote: RemoteReceiptResponse) -> Receipt {
        let items = remote.items
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { item in
                ReceiptItem(
                    id: UUID(uuidString: item.clientItemId ?? "") ?? UUID(),
                    name: item.name,
                    quantity: max(1, Int(item.quantity.rounded())),
                    price: item.price
                )
            }

        return Receipt(
            id: UUID(uuidString: remote.clientReceiptId ?? "") ?? UUID(),
            date: Date(timeIntervalSince1970: remote.createdAt / 1000),
            items: items,
            isActive: remote.isActive ?? true,
            canManageActions: remote.canManage ?? true,
            scannedTotal: remote.receiptTotal,
            scannedSubtotal: remote.subtotal,
            scannedTax: remote.tax,
            scannedGratuity: remote.gratuity,
            settlementPhase: remote.settlementPhase ?? "claiming",
            archivedReason: remote.archivedReason,
            wasArchivedEver: remote.wasArchivedEver ?? false,
            shareCode: remote.code,
            remoteID: remote.id
        )
    }

    private func toLocalReceiptLive(_ remote: RemoteReceiptLiveResponse) -> ReceiptLiveState {
        let viewerKey = remote.viewerParticipantKey

        let participants = remote.participants.map { participant in
            ReceiptLiveParticipant(
                id: participant.participantKey,
                name: participant.displayName,
                email: participant.participantEmail,
                avatarURL: participant.avatarUrl,
                joinedAt: Date(timeIntervalSince1970: participant.joinedAt / 1000),
                isCurrentUser: participant.participantKey == viewerKey,
                isSubmitted: participant.isSubmitted ?? false,
                paymentStatus: participant.paymentStatus,
                paymentMethod: participant.paymentMethod,
                paymentAmount: participant.paymentAmount,
                itemSubtotal: participant.itemSubtotal ?? 0,
                taxShare: participant.taxShare ?? 0,
                gratuityShare: participant.gratuityShare ?? 0,
                extraFeesShare: participant.extraFeesShare ?? 0,
                roundingAdjustment: participant.roundingAdjustment ?? 0,
                totalDue: participant.totalDue ?? 0
            )
        }

        let items = remote.items
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { item in
                ReceiptLiveItem(
                    id: item.key,
                    name: item.name,
                    quantity: max(0, Int(item.quantity.rounded())),
                    remainingQuantity: max(0, Int(item.remainingQuantity.rounded())),
                    viewerClaimedQuantity: max(0, Int(item.viewerClaimedQuantity.rounded())),
                    price: item.price
                )
            }

        let viewerSettlement: ReceiptViewerSettlement? = {
            guard let payload = remote.viewerSettlement else { return nil }
            return ReceiptViewerSettlement(
                itemSubtotal: payload.itemSubtotal ?? 0,
                taxShare: payload.taxShare ?? 0,
                gratuityShare: payload.gratuityShare ?? 0,
                extraFeesShare: payload.extraFeesShare ?? 0,
                roundingAdjustment: payload.roundingAdjustment ?? 0,
                totalDue: payload.totalDue ?? 0,
                canPay: payload.canPay ?? false,
                paymentStatus: payload.paymentStatus,
                paymentMethod: payload.paymentMethod
            )
        }()

        let hostPaymentQueue = (remote.hostPaymentQueue ?? []).map { queueItem in
            ReceiptHostPaymentQueueItem(
                id: queueItem.participantKey,
                name: queueItem.displayName,
                amountDue: queueItem.amountDue ?? 0,
                paymentStatus: queueItem.paymentStatus,
                paymentMethod: queueItem.paymentMethod,
                paymentAmount: queueItem.paymentAmount
            )
        }

        let hostPaymentOptions: ReceiptHostPaymentOptions? = {
            guard let options = remote.hostPaymentOptions else { return nil }
            return ReceiptHostPaymentOptions(
                preferredPaymentMethod: options.preferredPaymentMethod,
                venmoEnabled: options.venmoEnabled ?? false,
                venmoUsername: options.venmoUsername,
                cashAppEnabled: options.cashAppEnabled ?? false,
                cashAppCashtag: options.cashAppCashtag,
                zelleEnabled: options.zelleEnabled ?? false,
                zelleContact: options.zelleContact,
                cashApplePayEnabled: options.cashApplePayEnabled ?? false
            )
        }()

        return ReceiptLiveState(
            remoteId: remote.id,
            code: remote.code,
            createdAt: Date(timeIntervalSince1970: remote.createdAt / 1000),
            isActive: remote.isActive ?? true,
            settlementPhase: remote.settlementPhase ?? "claiming",
            archivedReason: remote.archivedReason,
            viewerParticipantKey: viewerKey,
            viewerRemoved: remote.viewerRemoved ?? false,
            hostParticipantKey: remote.hostParticipantKey,
            hostDisplayName: remote.hostDisplayName,
            hostHasPaymentOptions: remote.hostHasPaymentOptions ?? false,
            hostPaymentOptions: hostPaymentOptions,
            allParticipantsSubmitted: remote.allParticipantsSubmitted ?? false,
            unclaimedItemCount: max(0, Int((remote.unclaimedItemCount ?? 0).rounded())),
            extraFeesTotal: remote.extraFeesTotal ?? 0,
            tax: remote.tax,
            gratuity: remote.gratuity,
            otherFees: remote.otherFees,
            gratuityPercent: remote.gratuityPercent,
            participants: participants,
            items: items,
            viewerSettlement: viewerSettlement,
            hostPaymentQueue: hostPaymentQueue,
            receiptImageUrl: remote.receiptImageUrl
        )
    }

    private func upsertAuthenticatedUser() async {
        do {
            let _: MutationIdResponse = try await client.mutation("users:upsertMe")
        } catch {
            print("[SPLT] Failed to upsert user: \(error)")
        }
    }

    /// Tries `upsertMe` to verify the Convex auth token is valid.
    /// If it fails, checks Apple credential state and only invalidates the
    /// local session when the credential is revoked or missing.
    private func verifyAuthOrRelogin() async -> AuthVerificationResult {
        do {
            let _: MutationIdResponse = try await client.mutation("users:upsertMe")
            return .valid
        } catch {
            print("[SPLT] Cached auth token rejected: \(error)")
        }

        guard let cachedSession = AppleAuthStorage.loadSession() else {
            return .invalid
        }

        let credentialState = await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: cachedSession.userID) { state, _ in
                continuation.resume(returning: state)
            }
        }

        if credentialState == .revoked || credentialState == .notFound {
            print("[SPLT] Apple credential revoked or not found, signing out")
            return .invalid
        }

        print("[SPLT] Apple credential is still valid; preserving signed-in state")
        return .inconclusive
    }

    private func handleStaleAuth() async {
        print("[SPLT] Auth is stale, signing out")
        await client.logout()
        UserDefaults.standard.set(false, forKey: Self.authStateKey)
    }
}

private enum IngestEventName: String {
    case billCreated = "bill.created"
    case billShareCreated = "bill.share_created"
    case billGuestJoined = "bill.guest_joined"
    case settlementFinalized = "settlement.finalized"
    case paymentIntentMarked = "payment.intent_marked"
    case billCreditsViewed = "bill.credits_viewed"
    case billCreditsPurchased = "bill.credits_purchased"

    var channel: IngestChannel {
        switch self {
        case .billCreated, .billShareCreated:
            return .funnelHosting
        case .billGuestJoined:
            return .funnelCollaboration
        case .settlementFinalized, .paymentIntentMarked:
            return .funnelSettlement
        case .billCreditsViewed, .billCreditsPurchased:
            return .monetizationCredits
        }
    }
}

private enum IngestChannel: String {
    case funnelHosting = "funnel_hosting"
    case funnelCollaboration = "funnel_collaboration"
    case funnelSettlement = "funnel_settlement"
    case monetizationCredits = "monetization_credits"
}

private enum IngestSource: String {
    case ios
}

private enum IngestRole: String {
    case host
    case guest
}

private enum IngestValue: Encodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        }
    }
}

private struct IngestActorPayload: Encodable {
    let userId: String?
    let anonymousId: String?
    let role: String?
}

private struct IngestContextPayload: Encodable {
    let billId: String?
    let billCode: String?
    let sessionId: String?
    let requestId: String?
    let platform: String
    let appVersion: String?
    let buildNumber: String?
}

private struct IngestEventPayload: Encodable {
    let eventId: String
    let eventName: String
    let channel: String
    let occurredAt: String
    let source: String
    let actor: IngestActorPayload
    let context: IngestContextPayload
    let properties: [String: IngestValue]
}

private struct IngestEnvelopePayload: Encodable {
    let schemaVersion: String
    let sentAt: String
    let source: String
    let events: [IngestEventPayload]
}

private actor IngestAnalyticsTransport {
    static let shared = IngestAnalyticsTransport()

    private static let blockedPropertyFragments = ["email", "phone", "mobile", "contact"]
    private static let sessionId = UUID().uuidString.lowercased()
    private static let probeSentKey = "ingestValidationProbeSent"
    private static let productionIngestURLString = "https://splt.money/ingest"

    private var pendingEvents: [IngestEventPayload] = []
    private var flushTask: Task<Void, Never>?

    func track(name: IngestEventName, role: IngestRole?, context: IngestContextPayload, properties: [String: IngestValue]) {
        let sanitized = sanitize(properties: properties)
        let now = Date()
        let payload = IngestEventPayload(
            eventId: UUID().uuidString.lowercased(),
            eventName: name.rawValue,
            channel: name.channel.rawValue,
            occurredAt: Self.iso8601(now),
            source: IngestSource.ios.rawValue,
            actor: IngestActorPayload(
                userId: nil,
                anonymousId: ConvexService.shared.analyticsAnonymousID,
                role: role?.rawValue
            ),
            context: context,
            properties: sanitized
        )
        pendingEvents.append(payload)
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            await self?.flush()
        }
    }

    private func flush() async {
        flushTask = nil
        guard !pendingEvents.isEmpty else { return }
        let eventsToSend = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)

        let envelope = IngestEnvelopePayload(
            schemaVersion: "1.0",
            sentAt: Self.iso8601(Date()),
            source: IngestSource.ios.rawValue,
            events: eventsToSend
        )
        await postEnvelope(envelope, logPrefix: "[SPLT][Analytics]")
    }

    func sendValidationProbeIfNeeded() async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.probeSentKey) {
            return
        }
        defaults.set(true, forKey: Self.probeSentKey)

        let probeEvent = IngestEventPayload(
            eventId: "b098721c-d1d4-46b2-ba78-51704d2b8377",
            eventName: "bill.credits_viewed",
            channel: "monetization_credits",
            occurredAt: Self.iso8601(Date()),
            source: "ios",
            actor: IngestActorPayload(userId: "user_123", anonymousId: nil, role: nil),
            context: IngestContextPayload(
                billId: nil,
                billCode: nil,
                sessionId: nil,
                requestId: nil,
                platform: "ios",
                appVersion: nil,
                buildNumber: nil
            ),
            properties: [:]
        )

        let envelope = IngestEnvelopePayload(
            schemaVersion: "1.0",
            sentAt: Self.iso8601(Date()),
            source: "ios",
            events: [probeEvent]
        )
        await postEnvelope(envelope, logPrefix: "[SPLT][Analytics][Probe]")
    }

    private func sanitize(properties: [String: IngestValue]) -> [String: IngestValue] {
        properties.reduce(into: [String: IngestValue]()) { partialResult, entry in
            let lowered = entry.key.lowercased()
            let blocked = Self.blockedPropertyFragments.contains { lowered.contains($0) }
            if !blocked {
                partialResult[entry.key] = entry.value
            }
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func postEnvelope(_ envelope: IngestEnvelopePayload, logPrefix: String) async {
        let endpoints = Self.ingestEndpoints()
        do {
            let body = try JSONEncoder().encode(envelope)
            if let bodyString = String(data: body, encoding: .utf8) {
                print("\(logPrefix) Request payload: \(bodyString)")
            }
            print("\(logPrefix) Endpoint candidates: \(endpoints.map(\.absoluteString).joined(separator: ", "))")

            for endpoint in endpoints {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 10
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body

                do {
                    print("\(logPrefix) Attempting endpoint: \(endpoint.absoluteString)")
                    let (responseData, response) = try await URLSession.shared.data(for: request)
                    if let responseBody = String(data: responseData, encoding: .utf8), !responseBody.isEmpty {
                        print("\(logPrefix) Response body: \(responseBody)")
                    }
                    if let httpResponse = response as? HTTPURLResponse {
                        print("\(logPrefix) Status: \(httpResponse.statusCode) (\(endpoint.absoluteString))")
                        if (200...299).contains(httpResponse.statusCode) {
                            return
                        }
                    }
                } catch {
                    print("\(logPrefix) Endpoint failed (\(endpoint.absoluteString)): \(error.localizedDescription)")
                }
            }

            print("\(logPrefix) All ingest endpoints failed.")
        } catch {
            print("\(logPrefix) Failed to encode envelope: \(error.localizedDescription)")
        }
    }

    private static func ingestEndpoints() -> [URL] {
        if let configured = configuredIngestURL() {
            return [configured]
        }

        guard let production = URL(string: productionIngestURLString) else {
            return []
        }
        return [production]
    }

    private static func configuredIngestURL() -> URL? {
        let raw = ProcessInfo.processInfo.environment["SPLT_INGEST_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    static func defaultContext(billId: String?, billCode: String?) -> IngestContextPayload {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        return IngestContextPayload(
            billId: billId,
            billCode: billCode,
            sessionId: sessionId,
            requestId: nil,
            platform: "ios",
            appVersion: version,
            buildNumber: build
        )
    }
}

enum IngestAnalytics {
    static func trackBillCreated(receipt: Receipt) {
        let context = IngestAnalyticsTransport.defaultContext(
            billId: receipt.remoteID ?? receipt.id.uuidString,
            billCode: receipt.shareCode
        )
        let properties: [String: IngestValue] = [
            "itemCount": .int(receipt.items.count),
            "receiptTotal": .double(receipt.total)
        ]
        Task {
            await IngestAnalyticsTransport.shared.track(
                name: .billCreated,
                role: .host,
                context: context,
                properties: properties
            )
        }
    }

    static func trackBillShareCreated(billId: String, billCode: String?) {
        let context = IngestAnalyticsTransport.defaultContext(billId: billId, billCode: billCode)
        Task {
            await IngestAnalyticsTransport.shared.track(
                name: .billShareCreated,
                role: .host,
                context: context,
                properties: [:]
            )
        }
    }

    static func trackBillGuestJoined(receipt: Receipt) {
        let context = IngestAnalyticsTransport.defaultContext(
            billId: receipt.remoteID ?? receipt.id.uuidString,
            billCode: receipt.shareCode
        )
        Task {
            await IngestAnalyticsTransport.shared.track(
                name: .billGuestJoined,
                role: .guest,
                context: context,
                properties: [:]
            )
        }
    }

    static func trackSettlementFinalized(liveState: ReceiptLiveState) {
        let context = IngestAnalyticsTransport.defaultContext(
            billId: liveState.remoteId,
            billCode: liveState.code
        )
        let properties: [String: IngestValue] = [
            "participantCount": .int(liveState.participants.count)
        ]
        Task {
            await IngestAnalyticsTransport.shared.track(
                name: .settlementFinalized,
                role: .host,
                context: context,
                properties: properties
            )
        }
    }

    static func trackPaymentIntentMarked(liveState: ReceiptLiveState, method: String) {
        let context = IngestAnalyticsTransport.defaultContext(
            billId: liveState.remoteId,
            billCode: liveState.code
        )
        let properties: [String: IngestValue] = [
            "paymentMethod": .string(method)
        ]
        Task {
            await IngestAnalyticsTransport.shared.track(
                name: .paymentIntentMarked,
                role: .guest,
                context: context,
                properties: properties
            )
        }
    }

    static func trackBillCreditsViewed(freeRemaining: Int?, billCreditsBalance: Int?) {
        let context = IngestAnalyticsTransport.defaultContext(billId: nil, billCode: nil)
        var properties: [String: IngestValue] = [:]
        if let freeRemaining {
            properties["freeRemaining"] = .int(freeRemaining)
        }
        if let billCreditsBalance {
            properties["billCreditsBalance"] = .int(billCreditsBalance)
        }
        Task {
            await IngestAnalyticsTransport.shared.sendValidationProbeIfNeeded()
            await IngestAnalyticsTransport.shared.track(
                name: .billCreditsViewed,
                role: .host,
                context: context,
                properties: properties
            )
        }
    }

    static func trackBillCreditsPurchased(
        transactionId: String,
        productId: String,
        creditsPurchased: Int,
        amountCents: Int,
        currency: String,
        billCreditsBalance: Int
    ) {
        let context = IngestAnalyticsTransport.defaultContext(billId: nil, billCode: nil)
        let properties: [String: IngestValue] = [
            "transactionId": .string(transactionId),
            "productId": .string(productId),
            "creditsPurchased": .int(creditsPurchased),
            "amountCents": .int(amountCents),
            "currency": .string(currency.uppercased()),
            "billCreditsBalance": .int(billCreditsBalance)
        ]
        Task {
            await IngestAnalyticsTransport.shared.track(
                name: .billCreditsPurchased,
                role: .host,
                context: context,
                properties: properties
            )
        }
    }
}
