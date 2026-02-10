//
//  SPLTClipApp.swift
//  SPLTClip
//
//  Created by Garrett Tolbert on 2/3/26.
//

import SwiftUI
import UIKit

@main
struct SPLTClipApp: App {
    @State private var invocationURL: URL?

    var body: some Scene {
        WindowGroup {
            ContentView(invocationURL: invocationURL)
                .onOpenURL { url in
                    invocationURL = url
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    invocationURL = activity.webpageURL
                }
        }
    }
}
