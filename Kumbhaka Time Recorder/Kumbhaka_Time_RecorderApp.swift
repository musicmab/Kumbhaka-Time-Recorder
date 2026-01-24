import SwiftUI
import SwiftData

@main
struct Kumbhaka_Time_RecorderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: SessionRecord.self)
    }
}
