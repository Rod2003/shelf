import AppKit
import OSLog
import ShelfCore

/// Owns the NSStatusBar item for Shelf and its drop-down NSMenu.
///
/// MenuBarController is presentation-only. It exposes optional callbacks that
/// the AppCoordinator wires up at composition time. It does not instantiate
/// stores, register hotkeys, or persist any state.
///
/// Threading: NSStatusBar and NSMenu are main-thread-only, so this class is
/// `@MainActor`.
@MainActor
public final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let log = Logger(subsystem: "dev.rod.shelf", category: "core")

    // MARK: Callbacks (late-bound by AppCoordinator)

    /// Invoked when the user picks "New Shelf" from the menu.
    /// Note: the menu item shows ⌘⇧Space as a hint only. The actual global
    /// hotkey routing lives in `HotkeyManager` via Carbon
    /// `RegisterEventHotKey`. The menu key-equivalent and the Carbon hotkey
    /// are independent code paths that can coexist without conflict.
    public var onNewShelf: (() -> Void)?

    /// Invoked when the user picks an entry from the "Active Shelves" submenu.
    /// AppCoordinator wires this to bring the selected shelf's panel forward.
    public var onSelectActive: ((ShelfID) -> Void)?

    /// Invoked when the user picks "About Shelf".
    public var onAbout: (() -> Void)?

    /// Invoked when the user picks "Quit Shelf" (⌘Q).
    public var onQuit: (() -> Void)?

    // MARK: State

    /// Open shelves to surface in the "Active Shelves" submenu. Reassigning
    /// triggers a menu rebuild on the main actor. The controller does not
    /// query the window manager or the store — order and contents are the
    /// AppCoordinator's responsibility.
    public var activeShelves: [Shelf] = [] {
        didSet { rebuildMenu() }
    }

    // MARK: Lifecycle

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
        // Template images render as monochrome and adapt to the menu bar's
        // light/dark appearance (white in dark mode, black in light mode).
        // Without this flag, the SF Symbol would render in its default tint
        // and look out of place in dark menu bars.
        button.image?.isTemplate = true
        button.toolTip = "Shelf"
    }

    // MARK: Menu construction

    private func rebuildMenu() {
        let menu = NSMenu()

        // i18n: "New Shelf"
        let newItem = NSMenuItem(
            title: "New Shelf",
            action: #selector(handleNewShelf),
            keyEquivalent: " "
        )
        newItem.keyEquivalentModifierMask = [.command, .shift]
        newItem.target = self
        menu.addItem(newItem)

        menu.addItem(.separator())

        // i18n: "Active Shelves"
        let activeMenuItem = NSMenuItem(
            title: "Active Shelves",
            action: nil,
            keyEquivalent: ""
        )
        let activeSubmenu = NSMenu()
        if activeShelves.isEmpty {
            // i18n: "No Active Shelves"
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
                // representedObject is the AppKit-blessed channel for
                // carrying user data through to the selector handler.
                item.representedObject = shelf.id
                activeSubmenu.addItem(item)
            }
        }
        activeMenuItem.submenu = activeSubmenu
        menu.addItem(activeMenuItem)

        menu.addItem(.separator())

        // i18n: "About Shelf"
        let aboutItem = NSMenuItem(
            title: "About Shelf",
            action: #selector(handleAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        // i18n: "Quit Shelf"
        // ⌘Q is a menu shortcut (NSMenu key equivalent), distinct from the
        // Carbon RegisterEventHotKey path used for the global ⌘⇧Space hotkey.
        // No coordination with HotkeyManager is needed.
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

    // MARK: Title formatting

    /// Maximum displayed length of an Active-Shelves submenu row title before
    /// it gets truncated with an ellipsis. Tooltip carries the full content.
    private static let summaryMaxLength = 60

    static func summary(for shelf: Shelf) -> String {
        if shelf.items.isEmpty {
            return "Empty shelf"
        }
        let joined = shelf.items.map(\.displayName).joined(separator: ", ")
        if joined.count <= summaryMaxLength {
            return joined
        }
        return String(joined.prefix(summaryMaxLength - 1)) + "…"
    }

    static func tooltip(for shelf: Shelf) -> String {
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

    // MARK: Selectors

    @objc private func handleNewShelf() {
        log.info("New Shelf invoked from menu")
        onNewShelf?()
    }

    @objc private func handleActive(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? ShelfID else {
            log.error("handleActive invoked without a ShelfID representedObject")
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
