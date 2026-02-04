//
//  ContentView.swift
//  TabbyClip
//
//  Created by Garrett Tolbert on 2/3/26.
//

import SwiftUI

struct ContentView: View {
    let invocationURL: URL?
    @Environment(\.openURL) private var openURL

    private var joinCode: String? {
        ClipLinkParser.extractJoinCode(from: invocationURL)
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                Text("Opening Tabby")
                    .font(.largeTitle.weight(.bold))

                if let joinCode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Receipt code")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(joinCode)
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                } else {
                    Text("No valid 6-digit code was found in this link.")
                        .foregroundStyle(.secondary)
                }

                Button {
                    guard let joinCode else { return }
                    guard let url = URL(string: "https://tabby-api.vercel.app/clip?code=\(joinCode)") else { return }
                    openURL(url)
                } label: {
                    Text("Open in Tabby")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(joinCode == nil)

                Text("If the full app does not open, install Tabby and enter the code in Join.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(24)
        }
    }
}

#Preview {
    ContentView(invocationURL: URL(string: "https://tabby-api.vercel.app/clip?code=123456"))
}

private enum ClipLinkParser {
    static func extractJoinCode(from url: URL?) -> String? {
        guard let url else { return nil }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let queryKeys = ["rid", "code", "receipt", "receiptId", "shareCode"]
            for key in queryKeys {
                if let value = components.queryItems?.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame })?.value,
                   let normalized = normalizeCode(value) {
                    return normalized
                }
            }

            for pathComponent in components.path.split(separator: "/").reversed() {
                if let normalized = normalizeCode(String(pathComponent)) {
                    return normalized
                }
            }
        }

        guard let range = url.absoluteString.range(of: #"(?<!\d)\d{6}(?!\d)"#, options: .regularExpression) else {
            return nil
        }
        return String(url.absoluteString[range])
    }

    private static func normalizeCode(_ value: String) -> String? {
        let digitsOnly = value.filter(\.isNumber)
        return digitsOnly.count == 6 ? digitsOnly : nil
    }
}
