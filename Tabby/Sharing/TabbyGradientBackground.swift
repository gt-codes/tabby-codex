import SwiftUI

struct TabbyGradientBackground: View {
    var body: some View {
        LinearGradient(
            colors: [TabbyColor.canvas, TabbyColor.canvasAccent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
