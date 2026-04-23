// FCKCRS
// Spec: Specs/features/01-main-layout.md

import SwiftUI
import MapboxMaps

@main
struct FCKCRSApp: App {

    init() {
        if let token = Bundle.main.object(forInfoDictionaryKey: "MapboxAccessToken") as? String {
            MapboxOptions.accessToken = token
        }
    }

    @StateObject private var contentViewModel = ContentViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(contentViewModel)
                .preferredColorScheme(.dark)
        }
    }
}
