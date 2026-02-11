import SwiftUI
import UIKit

// MARK: - AppDelegate for Push Notifications

class SPLTAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Don't request notification permission here — it will be requested
        // after onboarding completes so the system dialog doesn't block the flow.
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationManager.shared.didRegisterForRemoteNotifications(withDeviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationManager.shared.didFailToRegisterForRemoteNotifications(withError: error)
    }
}

@MainActor
final class SPLTStartupStore: ObservableObject {
    private static let authStateKey = "isSignedIn"

    enum Phase {
        case idle
        case loading
        case ready
    }

    @Published private(set) var phase: Phase = .idle

    private var prefetchedReceipts: [Receipt] = []
    private var prefetchedProfile: UserProfile?
    private var didConsumeReceipts = false
    private var didConsumeProfile = false
    private var launchTask: Task<Void, Never>?

    var shouldShowSplash: Bool {
        phase != .ready
    }

    func setOnboardingState(_ hasOnboarded: Bool) {
        if !hasOnboarded {
            launchTask?.cancel()
            launchTask = nil
            clearPrefetch()
            phase = .idle
            return
        }
        startLaunchIfNeeded()
    }

    func consumePrefetchedReceipts() -> [Receipt] {
        guard !didConsumeReceipts else { return [] }
        didConsumeReceipts = true
        return prefetchedReceipts
    }

    func consumePrefetchedProfile() -> UserProfile? {
        guard !didConsumeProfile else { return nil }
        didConsumeProfile = true
        return prefetchedProfile
    }

    private func startLaunchIfNeeded() {
        guard launchTask == nil else { return }
        phase = .loading
        launchTask = Task { [weak self] in
            await self?.runStartupSequence()
        }
    }

    private func runStartupSequence() async {
        defer { launchTask = nil }

        let startupBeganAt = Date()
        let minimumSplashDuration: TimeInterval = 0.95
        let startupTimeout: TimeInterval = 2.2

        async let receiptsTask = fetchReceiptsWithTimeout(seconds: startupTimeout)
        async let profileTask = fetchProfileWithTimeout(seconds: startupTimeout)
        let (receipts, profile) = await (receiptsTask, profileTask)

        let elapsed = Date().timeIntervalSince(startupBeganAt)
        if elapsed < minimumSplashDuration {
            let remaining = minimumSplashDuration - elapsed
            let nanoseconds = UInt64((remaining * 1_000_000_000).rounded())
            try? await Task.sleep(nanoseconds: nanoseconds)
        }

        guard !Task.isCancelled else { return }
        if profile != nil {
            UserDefaults.standard.set(true, forKey: Self.authStateKey)
        }
        prefetchedReceipts = receipts
        prefetchedProfile = profile
        didConsumeReceipts = false
        didConsumeProfile = false

        withAnimation(.easeInOut(duration: 0.24)) {
            phase = .ready
        }
    }

    private func clearPrefetch() {
        prefetchedReceipts = []
        prefetchedProfile = nil
        didConsumeReceipts = false
        didConsumeProfile = false
    }

    private enum ReceiptsFetchResult {
        case value([Receipt])
        case timeout
    }

    private enum ProfileFetchResult {
        case value(UserProfile?)
        case timeout
    }

    private func fetchReceiptsWithTimeout(seconds: TimeInterval) async -> [Receipt] {
        let timeoutNanoseconds = UInt64((max(seconds, 0.1) * 1_000_000_000).rounded())
        return await withTaskGroup(of: ReceiptsFetchResult.self, returning: [Receipt].self) { group in
            group.addTask {
                do {
                    return .value(try await ConvexService.shared.fetchRecentReceipts(limit: 30))
                } catch {
                    print("[SPLT] Startup receipts prefetch failed: \(error)")
                    return .value([])
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timeout
            }

            for await result in group {
                switch result {
                case .value(let receipts):
                    group.cancelAll()
                    return receipts
                case .timeout:
                    print("[SPLT] Startup receipts prefetch timed out")
                    group.cancelAll()
                    return []
                }
            }
            return []
        }
    }

    private func fetchProfileWithTimeout(seconds: TimeInterval) async -> UserProfile? {
        let timeoutNanoseconds = UInt64((max(seconds, 0.1) * 1_000_000_000).rounded())
        return await withTaskGroup(of: ProfileFetchResult.self, returning: UserProfile?.self) { group in
            group.addTask {
                do {
                    return .value(try await ConvexService.shared.fetchMyProfile())
                } catch {
                    print("[SPLT] Startup profile prefetch failed: \(error)")
                    return .value(nil)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timeout
            }

            for await result in group {
                switch result {
                case .value(let profile):
                    group.cancelAll()
                    return profile
                case .timeout:
                    print("[SPLT] Startup profile prefetch timed out")
                    group.cancelAll()
                    return nil
                }
            }
            return nil
        }
    }
}

private struct SPLTSplashView: View {
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            Color(red: 0.925, green: 0.925, blue: 0.925)
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color.black.opacity(0.06),
                    Color.black.opacity(0.0)
                ],
                center: .top,
                startRadius: 20,
                endRadius: 360
            )
            .ignoresSafeArea()

            VStack(spacing: 66) {
                VStack(spacing: 58) {
                    HStack(spacing: 114) {
                        splashGlyph("S")
                        splashGlyph("P")
                    }

                    HStack(spacing: 112) {
                        splashGlyph("L")
                        splashGlyph("T")
                    }
                }
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.97)
                .animation(.spring(response: 0.45, dampingFraction: 0.84), value: hasAppeared)

                SplashLoadingDots()
                    .opacity(hasAppeared ? 1 : 0.55)
                    .animation(.easeInOut(duration: 0.35), value: hasAppeared)
            }
            .padding(.bottom, 26)
        }
        .onAppear {
            hasAppeared = true
        }
    }

    private func splashGlyph(_ letter: String) -> some View {
        Text(letter)
            .font(.custom("Avenir Next", size: 170).weight(.heavy))
            .tracking(4)
            .foregroundStyle(Color.black.opacity(0.98))
            .accessibilityHidden(true)
    }
}

private struct SplashLoadingDots: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.black.opacity(0.38))
                .frame(width: 8, height: 8)

            Circle()
                .fill(Color.black.opacity(0.86))
                .frame(width: 10, height: 10)
                .scaleEffect(pulse ? 1 : 0.78)
                .opacity(pulse ? 1 : 0.55)
                .animation(
                    .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                    value: pulse
                )

            Circle()
                .fill(Color.black.opacity(0.38))
                .frame(width: 8, height: 8)
        }
        .onAppear {
            pulse = true
        }
    }
}

// MARK: - App Entry Point

@main
struct SPLTApp: App {
    @UIApplicationDelegateAdaptor(SPLTAppDelegate.self) private var appDelegate
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage("shouldShowCameraPermissionNudge") private var shouldShowCameraPermissionNudge = false
    @AppStorage("appTheme") private var appTheme = "auto"
    @StateObject private var linkRouter = AppLinkRouter()
    @StateObject private var startupStore = SPLTStartupStore()

    var body: some Scene {
        WindowGroup {
            Group {
                if hasOnboarded {
                    ZStack {
                        ContentView()
                            .opacity(startupStore.shouldShowSplash ? 0 : 1)
                            .allowsHitTesting(!startupStore.shouldShowSplash)

                        if startupStore.shouldShowSplash {
                            SPLTSplashView()
                                .transition(
                                    .asymmetric(
                                        insertion: .opacity,
                                        removal: .opacity.combined(with: .scale(scale: 1.02))
                                    )
                                )
                        }
                    }
                    .animation(.easeInOut(duration: 0.34), value: startupStore.shouldShowSplash)
                } else {
                    SPLTOnboardingView(
                        onSignInWithApple: {
                            do {
                                try await ConvexService.shared.signInWithApple()
                                _ = try? await ConvexService.shared.migrateGuestDataToSignedInAccount()
                                await MainActor.run {
                                    shouldShowCameraPermissionNudge = true
                                    hasOnboarded = true
                                }
                                return true
                            } catch {
                                print("[SPLT] Apple sign in failed: \(error)")
                                return false
                            }
                        },
                        onFinish: { hasOnboarded = true }
                    )
                }
            }
            .environmentObject(linkRouter)
            .environmentObject(NotificationManager.shared)
            .environmentObject(startupStore)
            .onOpenURL { url in
                linkRouter.handle(url: url)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL else { return }
                linkRouter.handle(url: url)
            }
            .preferredColorScheme(preferredColorScheme)
            .onChange(of: hasOnboarded) { _, onboarded in
                startupStore.setOnboardingState(onboarded)
                if onboarded {
                    NotificationManager.shared.requestPermissionAndRegister()
                }
            }
            .onAppear {
                startupStore.setOnboardingState(hasOnboarded)
                // For users who already completed onboarding, register on launch.
                if hasOnboarded {
                    NotificationManager.shared.requestPermissionAndRegister()
                }
            }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appTheme {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return nil
        }
    }
}
