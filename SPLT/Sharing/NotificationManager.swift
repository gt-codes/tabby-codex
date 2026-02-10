import Foundation
import UIKit
import UserNotifications

/// Manages push notification registration, token storage, and incoming
/// notification routing for the SPLT app.
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// Published so `AppLinkRouter` or views can react to incoming notification payloads.
    @Published var pendingPaymentConfirmation: PaymentConfirmationPayload?

    /// The most recently received APNs device token (hex string), kept in memory
    /// so we can re-register with the backend after auth state changes.
    private var cachedAPNsToken: String?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Permission & Registration

    /// Requests notification permission and registers for remote notifications.
    func requestPermissionAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("[Notifications] Permission error: \(error.localizedDescription)")
                return
            }

            guard granted else {
                print("[Notifications] Permission denied by user.")
                return
            }

            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    // MARK: - Token Handling

    /// Called from AppDelegate when APNs returns a device token.
    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[Notifications] APNs token: \(tokenString.prefix(16))…")
        cachedAPNsToken = tokenString

        Task {
            do {
                try await ConvexService.shared.registerPushToken(apnsToken: tokenString)
                print("[Notifications] Token registered with backend.")
            } catch {
                print("[Notifications] Failed to register token: \(error.localizedDescription)")
            }
        }
    }

    /// Re-registers the cached APNs token with the backend. Call this after
    /// auth state changes so the push token row gets the user's tokenIdentifier.
    func reregisterTokenIfNeeded() {
        guard let token = cachedAPNsToken else { return }
        Task {
            do {
                try await ConvexService.shared.registerPushToken(apnsToken: token)
                print("[Notifications] Token re-registered after auth change.")
            } catch {
                print("[Notifications] Failed to re-register token: \(error.localizedDescription)")
            }
        }
    }

    func didFailToRegisterForRemoteNotifications(withError error: Error) {
        print("[Notifications] Registration failed: \(error.localizedDescription)")
    }

    // MARK: - Incoming Notification (foreground)

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show the banner even when the app is in the foreground.
        completionHandler([.banner, .sound])
    }

    // MARK: - Notification Tap (background / killed)

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        if let payload = PaymentConfirmationPayload(userInfo: userInfo) {
            DispatchQueue.main.async {
                self.pendingPaymentConfirmation = payload
            }
        }

        completionHandler()
    }
}

// PaymentConfirmationPayload is defined in AppLinkRouter.swift so it's
// available before this file is added to the Xcode target.
