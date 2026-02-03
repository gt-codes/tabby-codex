import SwiftUI

enum TabbyType {
    static let display = Font.custom("Avenir Next", size: 30).weight(.semibold)
    static let hero = Font.custom("Avenir Next", size: 24).weight(.semibold)
    static let title = Font.custom("Avenir Next", size: 20).weight(.semibold)
    static let body = Font.custom("Avenir Next", size: 16).weight(.regular)
    static let bodyBold = Font.custom("Avenir Next", size: 16).weight(.semibold)
    static let caption = Font.custom("Avenir Next", size: 12).weight(.medium)
    static let label = Font.custom("Avenir Next", size: 12).weight(.semibold)
}

enum TabbyColor {
    static let canvas = Color(red: 0.99, green: 0.98, blue: 0.96)
    static let canvasAccent = Color(red: 0.96, green: 0.97, blue: 0.99)
    static let ink = Color(red: 0.09, green: 0.09, blue: 0.11)
    static let subtle = Color.black.opacity(0.06)
    static let accent = Color(red: 0.98, green: 0.42, blue: 0.26)
    static let sun = Color(red: 0.97, green: 0.78, blue: 0.32)
    static let mint = Color(red: 0.18, green: 0.68, blue: 0.62)
    static let violet = Color(red: 0.36, green: 0.40, blue: 0.90)
    static let brass = Color(red: 0.62, green: 0.50, blue: 0.30)
    static let shadow = Color.black.opacity(0.08)
}
