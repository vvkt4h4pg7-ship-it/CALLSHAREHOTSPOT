import SwiftUI

@main
struct J7BridgeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .onChange(of: scenePhase) { phase in
                    // Keep a timestamped breadcrumb to correlate app backgrounding
                    // with NWConnection failures/cancellations after returning.
                    app.log("[APP] SCENE_PHASE \(String(describing: phase)) call=\(app.callStatus) voice=\(app.voiceStatus)")
                }
        }
    }
}
