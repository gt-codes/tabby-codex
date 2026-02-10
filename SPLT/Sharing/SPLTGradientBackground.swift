import SwiftUI

struct SPLTGradientBackground: View {
    var body: some View {
        LinearGradient(
            colors: [SPLTColor.canvas, SPLTColor.canvasAccent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
