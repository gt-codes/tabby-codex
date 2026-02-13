import SwiftUI

struct SPLTOnboardingView: View {
    @State private var selection = 0

    private let steps = OnboardingStep.allCases

    var onSignInWithApple: () async -> Bool = { false }
    var onFinish: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            let safeBottom = geo.safeAreaInsets.bottom
            let topInset = safeTop + 10
            let bottomInset = safeBottom + 80
            let currentStep = steps[safe: selection] ?? .hero

            ZStack {
                OnboardingBackground(
                    primary: currentStep.glowPrimary,
                    secondary: currentStep.glowSecondary,
                    selection: selection
                )
                    .ignoresSafeArea()

                TabView(selection: $selection) {
                    ForEach(steps) { step in
                        OnboardingPageView(step: step)
                            .tag(step.index)
                            .padding(.horizontal, 24)
                            .padding(.top, topInset)
                            .padding(.bottom, bottomInset)
                    }
                }
                .modifier(PageTabStyle())
                .animation(.easeInOut(duration: 0.35), value: selection)
                .frame(width: geo.size.width, height: geo.size.height)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    BottomBar(
                        step: currentStep,
                        selection: $selection,
                        total: steps.count,
                        onSignInWithApple: onSignInWithApple,
                        onFinish: onFinish
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, safeBottom + 12)
                }

            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

private struct OnboardingPageView: View {
    let step: OnboardingStep

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                if step == .ready {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(step.title)
                            .font(SPLTType.display)
                            .foregroundStyle(SPLTColor.ink)
                            .lineSpacing(2)
                        Text(step.subtitle)
                            .font(SPLTType.body)
                            .foregroundStyle(SPLTColor.ink.opacity(0.7))
                            .lineSpacing(3)
                    }
                    .padding(.top, 26)

                    GetStartedPanel()
                        .padding(.top, 8)
                } else {
                    HeroPanel(step: step)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(step.title)
                            .font(SPLTType.display)
                            .foregroundStyle(SPLTColor.ink)
                            .lineSpacing(2)
                        Text(step.subtitle)
                            .font(SPLTType.body)
                            .foregroundStyle(SPLTColor.ink.opacity(0.7))
                            .lineSpacing(3)
                    }
                    .padding(.bottom, 6)

                    FeatureList(bullets: step.bullets)

                    if let footnote = step.footnote {
                        Text(footnote)
                            .font(SPLTType.caption)
                            .foregroundStyle(SPLTColor.ink.opacity(0.55))
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct GetStartedPanel: View {
    @State private var rise = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [SPLTColor.canvasAccent.opacity(0.95), SPLTColor.canvas],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(SPLTColor.subtle, lineWidth: 1)
                )

            Circle()
                .fill(SPLTColor.accent.opacity(0.22))
                .frame(width: 170, height: 170)
                .blur(radius: 12)
                .offset(x: rise ? 18 : -6, y: rise ? -18 : -2)

            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to SPLT")
                    .font(SPLTType.hero)
                    .foregroundStyle(SPLTColor.ink)
                Text("Split your first receipt in under a minute.")
                    .font(SPLTType.body)
                    .foregroundStyle(SPLTColor.ink.opacity(0.68))
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(height: 230)
        .onAppear {
            withAnimation(.easeInOut(duration: 4.2).repeatForever(autoreverses: true)) {
                rise.toggle()
            }
        }
    }
}

private struct HeroPanel: View {
    let step: OnboardingStep
    @State private var float = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(step.accent.opacity(0.14))
                    .frame(width: 74, height: 74)
                Circle()
                    .stroke(step.accent.opacity(0.4), lineWidth: 1)
                    .frame(width: 74, height: 74)

                Image(systemName: step.heroSymbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(step.accent)
                    .rotationEffect(.degrees(float ? 2 : -2))
                    .offset(y: float ? -2 : 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(step.heroTitle)
                    .font(SPLTType.hero)
                    .foregroundStyle(SPLTColor.ink)
                Text(step.heroSubtitle)
                    .font(SPLTType.body)
                    .foregroundStyle(SPLTColor.ink.opacity(0.65))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .onAppear {
            withAnimation(.easeInOut(duration: 3.8).repeatForever(autoreverses: true)) {
                float.toggle()
            }
        }
    }
}

private struct FeatureList: View {
    let bullets: [OnboardingBullet]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(bullets.indices, id: \.self) { index in
                FeatureRow(bullet: bullets[index])
            }
        }
    }
}

private struct FeatureRow: View {
    let bullet: OnboardingBullet

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconBadge(icon: bullet.icon, tint: bullet.tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(bullet.title)
                    .font(SPLTType.bodyBold)
                    .foregroundStyle(SPLTColor.ink)
                Text(bullet.detail)
                    .font(SPLTType.caption)
                    .foregroundStyle(SPLTColor.ink.opacity(0.65))
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}

private struct BottomBar: View {
    let step: OnboardingStep
    @Binding var selection: Int
    let total: Int
    var onSignInWithApple: () async -> Bool
    var onFinish: () -> Void
    @State private var isSigningIn = false
    @State private var signInError: String?

    var body: some View {
        let isLastStep = selection == total - 1
        VStack(spacing: 10) {
            if step == .ready {
                Button {
                    beginAppleSignIn()
                } label: {
                    HStack(spacing: 8) {
                        if isSigningIn {
                            ProgressView()
                                .tint(SPLTColor.canvas)
                        } else {
                            Image(systemName: "apple.logo")
                                .font(.system(size: 16, weight: .semibold))
                        }

                        Text(isSigningIn ? "Signing in..." : "Sign in with Apple")
                            .font(SPLTType.bodyBold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: isSigningIn
                                        ? [SPLTColor.ink.opacity(0.45), SPLTColor.ink.opacity(0.45)]
                                        : [SPLTColor.ink, SPLTColor.ink.opacity(0.85)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(SPLTColor.subtle, lineWidth: 1)
                            )
                    )
                }
                .foregroundStyle(SPLTColor.canvas)
                .disabled(isSigningIn)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeOut(duration: 0.2), value: step == .ready)

                if let signInError {
                    Text(signInError)
                        .font(SPLTType.caption)
                        .foregroundStyle(Color.red.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
            }

            if isLastStep {
                Button("Continue without account") {
                    onFinish()
                }
                .font(SPLTType.caption)
                .foregroundStyle(SPLTColor.ink.opacity(0.5))
                .padding(.top, 4)
            }

            OnboardingPageIndicator(selection: $selection, total: total)
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
    }

    private func beginAppleSignIn() {
        signInError = nil
        isSigningIn = true

        Task {
            let signedIn = await onSignInWithApple()
            await MainActor.run {
                isSigningIn = false
                if !signedIn {
                    signInError = "Sign-in didn't finish. You can continue without an account."
                }
            }
        }
    }
}

private struct OnboardingPageIndicator: View {
    @Binding var selection: Int
    let total: Int

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let segment = width / max(1, CGFloat(total))

            HStack(spacing: 8) {
                ForEach(0..<total, id: \.self) { index in
                    Capsule()
                        .fill(index == selection ? SPLTColor.ink : SPLTColor.ink.opacity(0.2))
                        .frame(width: index == selection ? 16 : 6, height: 6)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: selection)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let clamped = min(max(0, value.location.x), width - 1)
                        let index = Int(clamped / segment)
                        if index != selection {
                            selection = index
                        }
                    }
            )
        }
        .frame(height: 12)
        .accessibilityLabel("Onboarding pages")
        .accessibilityValue("Page \(selection + 1) of \(total)")
    }
}

private struct OnboardingBackground: View {
    let primary: Color
    let secondary: Color
    let selection: Int
    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let offsetA = CGSize(
                width: drift ? -size.width * 0.12 : size.width * 0.16,
                height: drift ? -size.height * 0.16 : size.height * 0.12
            )
            let offsetB = CGSize(
                width: drift ? size.width * 0.14 : -size.width * 0.10,
                height: drift ? size.height * 0.10 : -size.height * 0.12
            )

            ZStack {
                LinearGradient(
                    colors: [SPLTColor.canvas, SPLTColor.canvasAccent],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Circle()
                    .fill(primary.opacity(0.18))
                    .frame(width: size.width * 0.9, height: size.width * 0.9)
                    .blur(radius: 70)
                    .offset(offsetA)
                    .animation(.easeInOut(duration: 18).repeatForever(autoreverses: true), value: drift)

                Circle()
                    .fill(secondary.opacity(0.14))
                    .frame(width: size.width * 0.75, height: size.width * 0.75)
                    .blur(radius: 80)
                    .offset(offsetB)
                    .animation(.easeInOut(duration: 22).repeatForever(autoreverses: true), value: drift)
            }
            .animation(.easeInOut(duration: 0.6), value: selection)
            .onAppear {
                drift.toggle()
            }
        }
    }
}
private struct IconBadge: View {
    let icon: String
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))
                .overlay(
                    Circle()
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                )
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 34, height: 34)
    }
}

private struct PageTabStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.tabViewStyle(.page(indexDisplayMode: .never))
        #else
        content
        #endif
    }
}

private struct OnboardingBullet: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
    let tint: Color
}

private enum OnboardingStep: Int, CaseIterable, Identifiable {
    case hero
    case scan
    case share
    case pay
    case ready

    var id: Int { rawValue }
    var index: Int { rawValue }

    var title: String {
        switch self {
        case .hero:
            return "Split receipts in seconds"
        case .scan:
            return "Scan and review"
        case .share:
            return "Invite the table"
        case .pay:
            return "Settle fast"
        case .ready:
            return "Get started"
        }
    }

    var subtitle: String {
        switch self {
        case .hero:
            return "SPLT keeps the flow clean, fast, and social. No signup to start."
        case .scan:
            return "AI validation keeps the totals accurate. Tap any line item to fix it."
        case .share:
            return "QR is primary. Copy link and Share are there when you need them."
        case .pay:
            return "Item split waits for host confirmation. Bill split is instant."
        case .ready:
            return "Sign in now, or keep going and create an account later."
        }
    }

    var heroTitle: String {
        switch self {
        case .hero:
            return "SPLT"
        case .scan:
            return "Scan"
        case .share:
            return "Share"
        case .pay:
            return "Pay"
        case .ready:
            return "Let's go"
        }
    }

    var heroSubtitle: String {
        switch self {
        case .hero:
            return "Receipts made simple"
        case .scan:
            return "Review with confidence"
        case .share:
            return "QR at the table"
        case .pay:
            return "Fast settlement"
        case .ready:
            return "Start splitting"
        }
    }

    var heroSymbol: String {
        switch self {
        case .hero:
            return "sparkles"
        case .scan:
            return "doc.text.viewfinder"
        case .share:
            return "qrcode"
        case .pay:
            return "creditcard"
        case .ready:
            return "sparkles"
        }
    }

    var accent: Color {
        switch self {
        case .hero:
            return SPLTColor.accent
        case .scan:
            return SPLTColor.sun
        case .share:
            return SPLTColor.mint
        case .pay:
            return SPLTColor.violet
        case .ready:
            return SPLTColor.accent
        }
    }

    var glowPrimary: Color {
        switch self {
        case .hero:
            return SPLTColor.accent
        case .scan:
            return SPLTColor.sun
        case .share:
            return SPLTColor.mint
        case .pay:
            return SPLTColor.violet
        case .ready:
            return SPLTColor.accent
        }
    }

    var glowSecondary: Color {
        switch self {
        case .hero:
            return SPLTColor.sun
        case .scan:
            return SPLTColor.accent
        case .share:
            return SPLTColor.sun
        case .pay:
            return SPLTColor.mint
        case .ready:
            return SPLTColor.mint
        }
    }

    var bullets: [OnboardingBullet] {
        switch self {
        case .hero:
            return [
                OnboardingBullet(icon: "doc.text.viewfinder", title: "Scan and review", detail: "Capture receipts and fix anything in seconds.", tint: SPLTColor.accent),
                OnboardingBullet(icon: "qrcode", title: "Share instantly", detail: "Let the table join with one QR scan.", tint: SPLTColor.accent),
                OnboardingBullet(icon: "creditcard", title: "Pay with confidence", detail: "Totals stay accurate and fair.", tint: SPLTColor.accent)
            ]
        case .scan:
            return [
                OnboardingBullet(icon: "doc.text.magnifyingglass", title: "AI-checked", detail: "Local OCR plus AI validation for accuracy.", tint: SPLTColor.sun),
                OnboardingBullet(icon: "slider.horizontal.3", title: "Quick edits", detail: "Tap any item or quantity to fix it.", tint: SPLTColor.sun),
                OnboardingBullet(icon: "percent", title: "Auto gratuity", detail: "Detects tips and taxes automatically.", tint: SPLTColor.sun)
            ]
        case .share:
            return [
                OnboardingBullet(icon: "qrcode", title: "QR first", detail: "Large, visible invite at the table.", tint: SPLTColor.mint),
                OnboardingBullet(icon: "link", title: "Copy link", detail: "Paste the join link anywhere.", tint: SPLTColor.mint),
                OnboardingBullet(icon: "message.fill", title: "SMS link", detail: "Send a join link when needed.", tint: SPLTColor.mint)
            ]
        case .pay:
            return [
                OnboardingBullet(icon: "checkmark.seal", title: "Host confirm", detail: "Item split waits for host approval.", tint: SPLTColor.violet),
                OnboardingBullet(icon: "bolt.fill", title: "Bill split", detail: "Even or custom splits can pay immediately.", tint: SPLTColor.violet),
                OnboardingBullet(icon: "dollarsign.circle", title: "Pay links", detail: "Apple Pay, Venmo, Cash App, Zelle.", tint: SPLTColor.violet)
            ]
        case .ready:
            return []
        }
    }

    var footnote: String? {
        switch self {
        case .hero:
            return "Swipe to see how it works"
        default:
            return nil
        }
    }

}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct OnboardingPreviewHost: View {
    @State private var finished = false

    var body: some View {
        if finished {
            ContentView()
        } else {
            SPLTOnboardingView(
                onSignInWithApple: { true },
                onFinish: { finished = true }
            )
        }
    }
}

#Preview {
    OnboardingPreviewHost()
}
