import RemanenceCore
import SwiftUI

@main
struct RemanenceApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Remanence", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 640)
                // The paper palette is light only until dark mode gets its own design.
                .preferredColorScheme(.light)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Backup…") { model.chooseBackupToImport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(model.importProgress != nil)
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model

        Group {
            if let error = model.databaseError {
                ContentUnavailableView(
                    "Your library couldn’t be opened",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if model.isReady {
                LibraryView()
            } else {
                SetupView()
            }
        }
        .background(Theme.paper)
        .task { await model.refresh() }
        .task { await model.observeShelf() }
        .onChange(of: scenePhase) { _, phase in
            // Pick up tools installed in Terminal while the app was in the background.
            if phase == .active { Task { await model.refresh() } }
        }
        .alert(
            "Remanence",
            isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.message ?? "")
        }
    }
}

enum Theme {
    static let paper = Color(red: 0.941, green: 0.922, blue: 0.871)
    static let card = Color(red: 0.965, green: 0.949, blue: 0.906)
    static let board = Color(red: 0.788, green: 0.749, blue: 0.659)
    static let ink = Color(red: 0.106, green: 0.094, blue: 0.078)
    static let inkMuted = Color(red: 0.310, green: 0.282, blue: 0.239)
    static let accent = Color(red: 0.498, green: 0.329, blue: 0.125)
    static let good = Color(red: 0.184, green: 0.290, blue: 0.271)
    static let attention = Color(red: 0.604, green: 0.184, blue: 0.102)

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }
}

enum TimeLabel {
    /// `4:05`, or `1:02:09` past an hour.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    /// `7 hr 55 min`, or `12 min` under an hour.
    static func long(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    }
}
