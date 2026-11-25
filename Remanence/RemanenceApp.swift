import AppKit
import RemanenceCore
import SwiftUI

@main
struct RemanenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

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
                Button("Record a Tape") { model.openRecording() }
                    .keyboardShortcut("r")
                    .disabled(model.route == .record)
                Button("Import Backup…") { model.chooseBackupToImport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(model.importProgress != nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Search Tapes") { model.searchRequested = true }
                    .keyboardShortcut("f")
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(systemName: model.workingTapes.isEmpty ? "recordingtape" : "recordingtape.circle.fill")
                .accessibilityLabel("Remanence: \(model.pipelineSummary)")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?
    private var scrollMonitor: Any?

    /// Space and the arrow keys control playback everywhere except while typing.
    /// A plain button shortcut would catch the space bar inside text fields too.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Closing the window takes its screens down, so the place is saved first.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.rememberPosition() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let shift = modifiers == .shift
            let keyCode = event.keyCode
            let characters = event.charactersIgnoringModifiers ?? ""
            nonisolated(unsafe) let window = event.window

            if modifiers == .command || modifiers == [.command, .shift], characters.lowercased() == "z" {
                let handled = MainActor.assumeIsolated {
                    Self.handleUndo(redo: modifiers.contains(.shift), in: window)
                }
                return handled ? nil : event
            }

            guard modifiers.isEmpty || shift else { return event }
            let handled = MainActor.assumeIsolated {
                Self.handleKey(keyCode, characters: characters, shift: shift, in: window)
            }
            return handled ? nil : event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let horizontal = event.scrollingDeltaX
            let vertical = event.scrollingDeltaY
            let handled = MainActor.assumeIsolated { Self.handleScroll(horizontal: horizontal, vertical: vertical) }
            return handled ? nil : event
        }
    }

    @MainActor
    private static func handleKey(_ keyCode: UInt16, characters: String, shift: Bool, in window: NSWindow?) -> Bool {
        let model = AppModel.shared
        let player = model.player
        // The event's own window is the reliable one. NSApp.keyWindow can be empty,
        // and treating that as "not typing" would swallow spaces from text fields.
        let responder = (window ?? NSApp.keyWindow)?.firstResponder
        guard !(responder is NSText) else { return false }
        // Return in a dialog or a file panel belongs to its default button.
        if !shift, let window, window.attachedSheet == nil, window.sheetParent == nil,
           !(window is NSPanel), NSApp.modalWindow == nil,
           model.handleShelfKey(code: keyCode) { return true }
        if model.handleEditKey(code: keyCode, characters: characters, shift: shift) { return true }
        guard player.currentURL != nil else { return false }

        if model.handleReviewKey(code: keyCode, characters: characters, shift: shift) { return true }
        guard !shift else { return false }
        switch keyCode {
        case 49:
            player.togglePlayback()
        case 123:
            Task { await player.seek(to: max(0, player.currentTime - 5)) }
        case 124:
            Task { await player.seek(to: min(player.duration, player.currentTime + 5)) }
        default:
            return false
        }
        return true
    }

    /// Undo on the review screen covers markers and trims. Text fields keep their own.
    @MainActor
    private static func handleUndo(redo: Bool, in window: NSWindow?) -> Bool {
        let model = AppModel.shared
        let responder = (window ?? NSApp.keyWindow)?.firstResponder
        guard model.route == .review, !(responder is NSText) else { return false }
        if redo { model.reviewModel.redo() } else { model.reviewModel.undo() }
        return true
    }

    /// A sideways swipe pans the zoomed waveform on the review screen.
    @MainActor
    private static func handleScroll(horizontal: CGFloat, vertical: CGFloat) -> Bool {
        let model = AppModel.shared
        if model.route == .edit, abs(horizontal) > abs(vertical), horizontal != 0 {
            return model.editModel.scroll(by: Double(horizontal))
        }
        guard model.route == .review, abs(horizontal) > abs(vertical), horizontal != 0 else { return false }
        let review = model.reviewModel
        review.moveZoom(to: review.zoomStart - Double(horizontal) * review.zoomSpan / 800)
        return true
    }

    /// Closing the window leaves the menu bar item running, so work carries on.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Audio or folders dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in await AppModel.shared.add(urls) }
    }

    /// Stops tools cleanly so nothing is left running and no attempts are used up.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Saved first, while the screens are still up.
        AppModel.shared.rememberPosition()
        Task { @MainActor in
            await AppModel.shared.recordModel.stopForQuit()
            await AppModel.shared.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.pipelineSummary)
        ForEach(model.workingTapes) { tape in
            Text("\(model.activityText(for: tape) ?? "") \(tape.tape.title)")
        }
        Divider()
        Button("Open Remanence") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Toggle("Open at Login", isOn: Binding(
            get: { model.opensAtLogin },
            set: { model.setOpensAtLogin($0) }
        ))
        Divider()
        Button("Quit Remanence") { NSApp.terminate(nil) }
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
        .task { await model.observeShelf() }
        .task { await model.observeCollections() }
        .task { await model.refresh() }
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

enum TimeLabel {
    /// `4:05`, or `1:02:09` past an hour.
    static func clock(_ seconds: Double) -> String { TimeText.clock(seconds) }

    /// `7 hr 55 min`, or `12 min` under an hour.
    static func long(_ seconds: Double) -> String { TimeText.long(seconds) }
}
