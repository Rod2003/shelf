import AppKit
import OSLog
import ShelfCore

@MainActor
public final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let log = Logger(subsystem: "dev.rod.shelf", category: "core")

    public var onNewShelf: (() -> Void)?

    public var onSelectActive: ((ShelfGroupID) -> Void)?

    public var onAbout: (() -> Void)?

    public var onQuit: (() -> Void)?

    public var activeShelves: [ShelfGroup] = [] {
        didSet { rebuildMenu() }
    }

    public override init() {
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
            title: "New Shelf",
            action: #selector(handleNewShelf),
            keyEquivalent: " "
        )
        newItem.keyEquivalentModifierMask = [.command, .shift]
        newItem.target = self
        menu.addItem(newItem)

        menu.addItem(.separator())

        let activeMenuItem = NSMenuItem(
            title: "Active Shelves",
            action: nil,
            keyEquivalent: ""
        )
        let activeSubmenu = NSMenu()
        if activeShelves.isEmpty {
            let empty = NSMenuItem(
                title: "No Active Shelves",
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            activeSubmenu.addItem(empty)
        } else {
            for shelf in activeShelves {
                let item = NSMenuItem(
                    title: Self.summary(for: shelf),
                    action: #selector(handleActive(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.toolTip = Self.tooltip(for: shelf)
                item.representedObject = shelf.id
                activeSubmenu.addItem(item)
            }
        }
        activeMenuItem.submenu = activeSubmenu
        menu.addItem(activeMenuItem)

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

    @objc private func handleNewShelf() {
        log.info("New Shelf invoked from menu")
        onNewShelf?()
    }

    @objc private func handleActive(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? ShelfGroupID else {
            log.error("handleActive invoked without a ShelfGroupID representedObject")
            return
        }
        log.info("Active shelf selected from menu")
        onSelectActive?(id)
    }

    @objc private func handleAbout() {
        log.info("About Shelf invoked from menu")
        onAbout?()
    }

    @objc private func handleQuit() {
        log.info("Quit invoked from menu")
        onQuit?()
    }
}
