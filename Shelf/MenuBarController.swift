import AppKit
import OSLog
import ShelfCore

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let log = Logger(subsystem: "dev.rod.shelf", category: "core")

    var onShowShelf: (() -> Void)?

    var onFocusShelf: (() -> Void)?

    var onAbout: (() -> Void)?

    var onQuit: (() -> Void)?

    var activeShelf: ShelfGroup? {
        didSet { rebuildMenu() }
    }

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureStatusItem()
        rebuildMenu()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            log.error("NSStatusItem has no button; menu bar UI will be missing")
            return
        }
        button.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "Shelf")
        button.image?.isTemplate = true
        button.toolTip = "Shelf"
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let newItem = NSMenuItem(
            title: "Show Shelf",
            action: #selector(handleShowShelf),
            keyEquivalent: " "
        )
        newItem.keyEquivalentModifierMask = [.command, .shift]
        newItem.target = self
        menu.addItem(newItem)

        if let activeShelf {
            menu.addItem(.separator())
            let focusItem = NSMenuItem(
                title: Self.summary(for: activeShelf),
                action: #selector(handleFocusShelf),
                keyEquivalent: ""
            )
            focusItem.target = self
            focusItem.toolTip = Self.tooltip(for: activeShelf)
            menu.addItem(focusItem)
        }

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "About Shelf",
            action: #selector(handleAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Shelf",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private static let summaryMaxLength = 60

    static func summary(for shelf: ShelfGroup) -> String {
        if shelf.items.isEmpty {
            return "Empty shelf"
        }
        let joined = shelf.items.map(\.displayName).joined(separator: ", ")
        if joined.count <= summaryMaxLength {
            return joined
        }
        return String(joined.prefix(summaryMaxLength - 1)) + "…"
    }

    static func tooltip(for shelf: ShelfGroup) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let timeStr = "Created \(formatter.string(from: shelf.createdAt))"
        if shelf.items.isEmpty {
            return timeStr
        }
        let allNames = shelf.items.map(\.displayName).joined(separator: "\n")
        return "\(timeStr)\n\n\(allNames)"
    }

    @objc private func handleShowShelf() {
        log.info("Show Shelf invoked from menu")
        onShowShelf?()
    }

    @objc private func handleFocusShelf() {
        log.info("Focus shelf invoked from menu")
        onFocusShelf?()
    }

    @objc private func handleAbout() {
        log.info("About Shelf invoked from menu")
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.onAbout?()
        }
    }

    @objc private func handleQuit() {
        log.info("Quit invoked from menu")
        onQuit?()
    }
}
