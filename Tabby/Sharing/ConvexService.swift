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
    private static let userIDKey = "tabby.apple.userID"
    private static let idTokenKey = "tabby.apple.idToken"

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
    private static let service = "com.tabbyapp.app"
    private static let account = "tabby.guest.device.id"
    private static let fallbackKey = "tabby.guest.device.id.fallback"

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

    private let authProvider: AppleAuthProvider
    private let client: ConvexClientWithAuth<AppleAuthSession>
    private let guestDeviceId: String

    var hasCachedSession: Bool {
        AppleAuthStorage.loadSession() != nil
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

                let authValid = await self.verifyAuthOrRelogin()
                if !authValid {
                    await self.handleStaleAuth()
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
            hostPaymentQueue: hostPaymentQueue
        )
    }

    private func upsertAuthenticatedUser() async {
        do {
            let _: MutationIdResponse = try await client.mutation("users:upsertMe")
        } catch {
            print("[Tabby] Failed to upsert user: \(error)")
        }
    }

    /// Tries `upsertMe` to verify the Convex auth token is valid.
    /// If it fails (expired JWT), checks Apple credential state and signs out if revoked.
    /// Returns `true` if auth is valid after this call.
    private func verifyAuthOrRelogin() async -> Bool {
        do {
            let _: MutationIdResponse = try await client.mutation("users:upsertMe")
            return true
        } catch {
            print("[Tabby] Cached auth token rejected: \(error)")
        }

        // The JWT was rejected — check if the Apple credential is still valid.
        // If the user's Apple ID credential is revoked, sign out.
        // Otherwise the token just expired — the user needs to re-login explicitly.
        guard let cachedSession = AppleAuthStorage.loadSession() else {
            return false
        }

        let credentialState = await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: cachedSession.userID) { state, _ in
                continuation.resume(returning: state)
            }
        }

        if credentialState == .revoked || credentialState == .notFound {
            print("[Tabby] Apple credential revoked or not found, signing out")
            return false
        }

        // Credential is still authorized with Apple but the JWT expired.
        // Clear the stale session so the user can sign in again cleanly.
        print("[Tabby] Apple credential valid but JWT expired, clearing stale session")
        return false
    }

    private func handleStaleAuth() async {
        print("[Tabby] Auth is stale, signing out")
        await client.logout()
        UserDefaults.standard.set(false, forKey: Self.authStateKey)
    }
}
