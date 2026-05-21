import AppKit

let app = NSApplication.shared

let _delegate: AppDelegate = MainActor.assumeIsolated {
    let d = AppDelegate()
    app.delegate = d
    return d
}

app.setActivationPolicy(.accessory)

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
