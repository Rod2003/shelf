import AppKit

// NSApplication.shared triggers loading of NSPrincipalClass from Info.plist (= "ShelfApplication"),
// instantiating that subclass. The shared instance is what NSApplicationMain will run.
let app = NSApplication.shared

// AppDelegate is @MainActor-isolated; in Swift 5.9 strict concurrency, top-level main.swift
// is treated as a synchronous nonisolated context, so we must construct on MainActor explicitly.
// Stored as a top-level let to retain a strong reference (NSApplication.delegate is weak).
let _delegate: AppDelegate = MainActor.assumeIsolated {
    let d = AppDelegate()
    app.delegate = d
    return d
}

// Belt-and-suspenders: also set in AppDelegate.applicationDidFinishLaunching.
// Per Spike B findings, .accessory is REQUIRED so .nonactivatingPanel actually
// stays non-activating — without it, showing a shelf would steal focus.
app.setActivationPolicy(.accessory)

// Run via NSApplicationMain so AppKit performs its standard init sequence
// (reads NSPrincipalClass, calls finishLaunching, posts didFinishLaunching).
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
