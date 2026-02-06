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
}

private struct RemoteUserResponse: Decodable {
    let name: String?
    let email: String?
    let pictureUrl: String?
    let preferredPaymentMethod: String?
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
                if case .success = cachedLogin {
                    await upsertAuthenticatedUser()
                } else {
                    UserDefaults.standard.set(false, forKey: Self.authStateKey)
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

        let response: ShareReceiptResponse = try await client.mutation("receipts:create", with: [
            "clientReceiptId": receipt.id.uuidString,
            "items": encodedItems,
            "guestDeviceId": guestDeviceId
        ])
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

    func fetchRecentReceipts(limit: Int = 20) async throws -> [Receipt] {
        let boundedLimit = max(1, min(limit, 100))
        let stream = client.subscribe(
            to: "receipts:listRecent",
            with: [
                "limit": Double(boundedLimit),
                "guestDeviceId": guestDeviceId
            ],
            yielding: [RemoteReceiptResponse].self
        ).values

        for try await payload in stream {
            return payload.map(toLocalReceipt)
        }

        return []
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
                preferredPaymentMethod: payload.preferredPaymentMethod
            )
        }

        return nil
    }

    func updateMyProfile(name: String?, preferredPaymentMethod: String?) async throws {
        let _: MutationIdResponse = try await client.mutation(
            "users:updateProfile",
            with: [
                "name": name,
                "preferredPaymentMethod": preferredPaymentMethod
            ]
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
            isActive: remote.isActive ?? true
        )
    }

    private func upsertAuthenticatedUser() async {
        do {
            let _: MutationIdResponse = try await client.mutation("users:upsertMe")
        } catch {
            print("[Tabby] Failed to upsert user: \(error)")
        }
    }
}
