import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            TabbyHomeBackground()
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tabby")
                        .font(TabbyType.hero)
                        .foregroundStyle(TabbyColor.ink)
                    Text("Split receipts fast. Keep the table moving.")
                        .font(TabbyType.body)
                        .foregroundStyle(TabbyColor.ink.opacity(0.7))
                }

                HStack(spacing: 12) {
                    HomeActionCard(
                        title: "New Receipt",
                        detail: "Scan and review",
                        symbol: "doc.text.viewfinder",
                        tint: TabbyColor.accent
                    )
                    HomeActionCard(
                        title: "Join Receipt",
                        detail: "Scan QR",
                        symbol: "qrcode",
                        tint: Color(red: 0.15, green: 0.55, blue: 0.55)
                    )
                }

                GlassPanel {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("History")
                            .font(TabbyType.bodyBold)
                            .foregroundStyle(TabbyColor.ink)
                        Text("Past receipts will appear here with location and totals.")
                            .font(TabbyType.caption)
                            .foregroundStyle(TabbyColor.ink.opacity(0.6))
                    }
                }

                Spacer()
            }
            .padding(24)
        }
    }
}

private struct HomeActionCard: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.2))
                        .frame(width: 46, height: 46)
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(TabbyType.bodyBold)
                    .foregroundStyle(TabbyColor.ink)
                Text(detail)
                    .font(TabbyType.caption)
                    .foregroundStyle(TabbyColor.ink.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(TabbyColor.ink.opacity(0.08), lineWidth: 1)
                    )
            )
            .shadow(color: TabbyColor.shadow, radius: 12, x: 0, y: 8)
    }
}

private struct TabbyHomeBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [TabbyColor.canvas, TabbyColor.canvasAccent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [TabbyColor.accent.opacity(0.1), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 300
            )
            .ignoresSafeArea()
        }
    }
}

#Preview {
    ContentView()
}
