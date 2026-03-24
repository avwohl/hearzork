import SwiftUI

@main
struct HearZorkApp: App {
    @State private var voice = VoiceCoordinator()

    var body: some Scene {
        WindowGroup {
            LibraryView(voice: voice)
        }
    }
}
