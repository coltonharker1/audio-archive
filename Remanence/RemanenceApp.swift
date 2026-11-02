import SwiftUI

@main
struct RemanenceApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Remanence", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 640)
                // The paper palette is light only until dark mode gets its own design.
                .preferredColorScheme(.light)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let error = model.databaseError {
                ContentUnavailableView(
                    "Your library couldn’t be opened",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if model.isReady {
                ShelfPlaceholderView()
            } else {
                SetupView()
            }
        }
        .background(Theme.paper)
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            // Pick up tools installed in Terminal while the app was in the background.
            if phase == .active { Task { await model.refresh() } }
        }
    }
}

struct ShelfPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Your shelf is empty")
                .font(.system(size: 34, weight: .regular, design: .serif))
                .foregroundStyle(Theme.ink)
            Text("Everything’s set up. Your tapes will appear here.")
                .foregroundStyle(Theme.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum Theme {
    static let paper = Color(red: 0.941, green: 0.922, blue: 0.871)
    static let card = Color(red: 0.965, green: 0.949, blue: 0.906)
    static let ink = Color(red: 0.106, green: 0.094, blue: 0.078)
    static let inkMuted = Color(red: 0.310, green: 0.282, blue: 0.239)
    static let good = Color(red: 0.184, green: 0.290, blue: 0.271)
    static let attention = Color(red: 0.604, green: 0.184, blue: 0.102)
}
