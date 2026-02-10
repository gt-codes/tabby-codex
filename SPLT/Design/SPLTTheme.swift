import SwiftUI

enum SPLTType {
    static let display = Font.custom("Avenir Next", size: 30).weight(.semibold)
    static let hero = Font.custom("Avenir Next", size: 24).weight(.semibold)
    static let title = Font.custom("Avenir Next", size: 20).weight(.semibold)
    static let body = Font.custom("Avenir Next", size: 16).weight(.regular)
    static let bodyBold = Font.custom("Avenir Next", size: 16).weight(.semibold)
    static let caption = Font.custom("Avenir Next", size: 12).weight(.medium)
    static let label = Font.custom("Avenir Next", size: 12).weight(.semibold)
}

enum SPLTColor {
    static let canvas = Color("Canvas")
    static let canvasAccent = Color("CanvasAccent")
    static let ink = Color("Ink")
    static let subtle = Color("Subtle")
    static let accent = Color("Accent")
    static let sun = Color("Sun")
    static let mint = Color("Mint")
    static let violet = Color("Violet")
    static let brass = Color("Brass")
    static let shadow = Color.black.opacity(0.08)
}
