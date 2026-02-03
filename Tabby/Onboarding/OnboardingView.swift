import SwiftUI

struct TabbyOnboardingView: View {
    @State private var selection = 0
    @StateObject private var permissionCenter = PermissionCenter()

    private let steps = OnboardingStep.allCases

    var onTryDemo: () -> Void = {}
    var onScanReceipt: () -> Void = {}
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
                        OnboardingPageView(step: step, permissionCenter: permissionCenter)
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
                        permissionCenter: permissionCenter,
                        onTryDemo: onTryDemo,
                        onScanReceipt: onScanReceipt,
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
    @ObservedObject var permissionCenter: PermissionCenter

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HeroPanel(step: step)
                VStack(alignment: .leading, spacing: 10) {
                    Text(step.title)
                        .font(TabbyType.display)
                        .foregroundStyle(TabbyColor.ink)
                        .lineSpacing(2)
                    Text(step.subtitle)
                        .font(TabbyType.body)
                        .foregroundStyle(TabbyColor.ink.opacity(0.7))
                        .lineSpacing(3)
                }
                .padding(.bottom, 6)

                if step == .permissions {
                    PermissionsList(permissionCenter: permissionCenter)
                } else {
                    FeatureList(bullets: step.bullets)
                }

                if let footnote = step.footnote {
                    Text(footnote)
                        .font(TabbyType.caption)
                        .foregroundStyle(TabbyColor.ink.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    .font(TabbyType.hero)
                    .foregroundStyle(TabbyColor.ink)
                Text(step.heroSubtitle)
                    .font(TabbyType.body)
                    .foregroundStyle(TabbyColor.ink.opacity(0.65))
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
                    .font(TabbyType.bodyBold)
                    .foregroundStyle(TabbyColor.ink)
                Text(bullet.detail)
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.65))
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}

private struct PermissionsList: View {
    @ObservedObject var permissionCenter: PermissionCenter

    var body: some View {
        VStack(spacing: 12) {
            PermissionToggleRow(
                title: "Camera",
                detail: "Required to scan receipts",
                isRequired: true,
                isOn: Binding(
                    get: { permissionCenter.cameraEnabled },
                    set: { newValue in
                        if newValue {
                            permissionCenter.requestCamera()
                        } else {
                            permissionCenter.openSettings()
                        }
                    }
                )
            )
            PermissionToggleRow(
                title: "Contacts",
                detail: "Find friends fast",
                isRequired: false,
                isOn: Binding(
                    get: { permissionCenter.contactsEnabled },
                    set: { newValue in
                        if newValue {
                            permissionCenter.requestContacts()
                        } else {
                            permissionCenter.openSettings()
                        }
                    }
                )
            )
            PermissionToggleRow(
                title: "Location",
                detail: "Match restaurant names",
                isRequired: false,
                isOn: Binding(
                    get: { permissionCenter.locationEnabled },
                    set: { newValue in
                        if newValue {
                            permissionCenter.requestLocation()
                        } else {
                            permissionCenter.openSettings()
                        }
                    }
                )
            )
        }
    }
}

private struct PermissionToggleRow: View {
    let title: String
    let detail: String
    let isRequired: Bool
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(TabbyType.bodyBold)
                        .foregroundStyle(TabbyColor.ink)
                    if isRequired {
                        Text("Required")
                            .font(TabbyType.label)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(TabbyColor.sun)
                            )
                            .foregroundStyle(TabbyColor.ink)
                    }
                }
                Text(detail)
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(TabbyColor.accent)
        }
        .padding(12)
    }
}

private struct BottomBar: View {
    let step: OnboardingStep
    @Binding var selection: Int
    let total: Int
    @ObservedObject var permissionCenter: PermissionCenter
    var onTryDemo: () -> Void
    var onScanReceipt: () -> Void
    var onFinish: () -> Void

    var body: some View {
        let canContinue = step.primaryCTAEnabled(cameraEnabled: permissionCenter.cameraEnabled)
        VStack(spacing: 10) {
            if step == .permissions {
                Button {
                    handlePrimary()
                } label: {
                    Text("Scan Receipt")
                        .font(TabbyType.bodyBold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: canContinue
                                            ? [TabbyColor.ink, TabbyColor.ink.opacity(0.85)]
                                            : [TabbyColor.ink.opacity(0.35), TabbyColor.ink.opacity(0.35)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(TabbyColor.subtle, lineWidth: 1)
                                )
                        )
                }
                .foregroundStyle(TabbyColor.canvas)
                .disabled(!canContinue)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeOut(duration: 0.2), value: step == .permissions)
            }

            OnboardingPageIndicator(selection: $selection, total: total)
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
    }

    private func handlePrimary() {
        if step == .permissions {
            if step.primaryCTAEnabled(cameraEnabled: permissionCenter.cameraEnabled) {
                onScanReceipt()
                onFinish()
            }
        } else if selection < total - 1 {
            selection += 1
        } else {
            onFinish()
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
                        .fill(index == selection ? TabbyColor.ink : TabbyColor.ink.opacity(0.2))
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
        .accessibilityValue("Page \\(selection + 1) of \\(total)")
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
                    colors: [TabbyColor.canvas, TabbyColor.canvasAccent],
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
    case privacy
    case permissions

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
        case .privacy:
            return "Local-first by design"
        case .permissions:
            return "Enable permissions"
        }
    }

    var subtitle: String {
        switch self {
        case .hero:
            return "Tabby keeps the flow clean, fast, and social. No signup to start."
        case .scan:
            return "AI validation keeps the totals accurate. Tap any line item to fix it."
        case .share:
            return "QR is primary. Contacts and SMS are there when you need them."
        case .pay:
            return "Item split waits for host confirmation. Bill split is instant."
        case .privacy:
            return "All receipts stay on device. Upgrade later if you want sync."
        case .permissions:
            return "Turn on what you need. Camera is required to scan receipts."
        }
    }

    var heroTitle: String {
        switch self {
        case .hero:
            return "Tabby"
        case .scan:
            return "Scan"
        case .share:
            return "Share"
        case .pay:
            return "Pay"
        case .privacy:
            return "Private"
        case .permissions:
            return "Ready"
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
        case .privacy:
            return "Local by default"
        case .permissions:
            return "Enable access"
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
        case .privacy:
            return "lock.shield"
        case .permissions:
            return "checkmark.seal"
        }
    }

    var accent: Color {
        switch self {
        case .hero:
            return TabbyColor.accent
        case .scan:
            return TabbyColor.sun
        case .share:
            return TabbyColor.mint
        case .pay:
            return TabbyColor.violet
        case .privacy:
            return TabbyColor.brass
        case .permissions:
            return TabbyColor.ink
        }
    }

    var glowPrimary: Color {
        switch self {
        case .hero:
            return TabbyColor.accent
        case .scan:
            return TabbyColor.sun
        case .share:
            return TabbyColor.mint
        case .pay:
            return TabbyColor.violet
        case .privacy:
            return TabbyColor.brass
        case .permissions:
            return TabbyColor.accent
        }
    }

    var glowSecondary: Color {
        switch self {
        case .hero:
            return TabbyColor.sun
        case .scan:
            return TabbyColor.accent
        case .share:
            return TabbyColor.sun
        case .pay:
            return TabbyColor.mint
        case .privacy:
            return TabbyColor.sun
        case .permissions:
            return TabbyColor.sun
        }
    }

    var bullets: [OnboardingBullet] {
        switch self {
        case .hero:
            return [
                OnboardingBullet(icon: "doc.text.viewfinder", title: "Scan and review", detail: "Capture receipts and fix anything in seconds.", tint: TabbyColor.accent),
                OnboardingBullet(icon: "qrcode", title: "Share instantly", detail: "Let the table join with one QR scan.", tint: TabbyColor.accent),
                OnboardingBullet(icon: "creditcard", title: "Pay with confidence", detail: "Totals stay accurate and fair.", tint: TabbyColor.accent)
            ]
        case .scan:
            return [
                OnboardingBullet(icon: "doc.text.magnifyingglass", title: "AI-checked", detail: "Local OCR plus AI validation for accuracy.", tint: TabbyColor.sun),
                OnboardingBullet(icon: "slider.horizontal.3", title: "Quick edits", detail: "Tap any item or quantity to fix it.", tint: TabbyColor.sun),
                OnboardingBullet(icon: "percent", title: "Auto gratuity", detail: "Detects tips and taxes automatically.", tint: TabbyColor.sun)
            ]
        case .share:
            return [
                OnboardingBullet(icon: "qrcode", title: "QR first", detail: "Large, visible invite at the table.", tint: TabbyColor.mint),
                OnboardingBullet(icon: "person.2.fill", title: "Contacts", detail: "Add friends in one tap.", tint: TabbyColor.mint),
                OnboardingBullet(icon: "message.fill", title: "SMS link", detail: "Send a join link when needed.", tint: TabbyColor.mint)
            ]
        case .pay:
            return [
                OnboardingBullet(icon: "checkmark.seal", title: "Host confirm", detail: "Item split waits for host approval.", tint: TabbyColor.violet),
                OnboardingBullet(icon: "bolt.fill", title: "Bill split", detail: "Even or custom splits can pay immediately.", tint: TabbyColor.violet),
                OnboardingBullet(icon: "dollarsign.circle", title: "Pay links", detail: "Apple Pay, Venmo, Cash App, Zelle.", tint: TabbyColor.violet)
            ]
        case .privacy:
            return [
                OnboardingBullet(icon: "lock.fill", title: "No signup", detail: "Start splitting right away.", tint: TabbyColor.accent),
                OnboardingBullet(icon: "iphone", title: "On-device storage", detail: "Receipts stay local by default.", tint: TabbyColor.accent),
                OnboardingBullet(icon: "arrow.up.right", title: "Upgrade later", detail: "Optional account for sync and speed.", tint: TabbyColor.accent)
            ]
        case .permissions:
            return []
        }
    }

    var footnote: String? {
        switch self {
        case .hero:
            return "Swipe to see how it works"
        case .permissions:
            return "You can change permissions later in Settings."
        default:
            return nil
        }
    }

    var primaryCTA: String {
        switch self {
        case .permissions:
            return "Scan Receipt"
        default:
            return "Next"
        }
    }

    func primaryCTAEnabled(cameraEnabled: Bool) -> Bool {
        switch self {
        case .permissions:
            return cameraEnabled
        default:
            return true
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    TabbyOnboardingView()
}
