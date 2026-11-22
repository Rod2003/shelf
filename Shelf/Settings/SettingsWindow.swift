import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var replay: ReplayController

    var body: some View {
        Form {
            Section {
                Toggle("Enable Replay", isOn: $replay.isEnabled)
                LabeledContent("Save last 30 seconds", value: HotkeyManager.saveReplayShortcutLabel)
                if let status = replay.status {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Replay")
            } footer: {
                Text("Keeps the last 30 seconds of your main display in memory. Saved clips go to Movies › Shelf Replays and open in the shelf.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

enum SettingsWindow {
    static func make(replay: ReplayController) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(replay: replay)))
        window.title = "Shelf Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
