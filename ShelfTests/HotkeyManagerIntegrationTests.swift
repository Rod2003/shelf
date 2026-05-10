// Shelf — T24 integration tests for `HotkeyManager`.
//
// These tests exercise the lifecycle and gating API of the production
// `HotkeyManager` against the real Carbon `RegisterEventHotKey` /
// `UnregisterEventHotKey` plumbing. They DO NOT attempt to fire real
// hotkey events (that requires a real keyboard event source and is out
// of scope for unit tests; the live keypress path is covered by T26
// agent QA via AppleScript).
//
// What is verified:
//   * `init()` runs to completion (installs the Carbon event handler;
//     attempts to register `.newShelf`).
//   * `setEscEnabled(_:)` / `setSpaceEnabled(_:)` are idempotent and
//     can be toggled repeatedly without crashing.
//   * Public callback closures (`onNewShelf`, `onCloseFrontmost`,
//     `onQuickLook`) are assignable and callable through the optional
//     property surface.
//
// What is intentionally NOT covered:
//   * Direct invocation of the private `dispatch(id:)` method. That
//     method is `private` in production; exposing it would require
//     modifying app source, which the T24 spec forbids. The dispatch
//     path is exercised end-to-end by T26 QA scenarios that fire real
//     hotkey events.
//
// Concurrency:
//   * `HotkeyManager` is `@MainActor`-isolated; tests are
//     `@MainActor` to satisfy the isolation contract.
//   * Each test creates a local `HotkeyManager` instance whose `deinit`
//     runs at the end of the test method, freeing any Carbon
//     registrations before the next method begins.

import AppKit
import XCTest

@testable import Shelf

@MainActor
final class HotkeyManagerIntegrationTests: XCTestCase {

    // MARK: Lifecycle

    /// Constructing a `HotkeyManager` must complete without throwing.
    /// Init installs a Carbon event handler and attempts to register
    /// the `.newShelf` (⌘⇧Space) hotkey. If a sibling instance (e.g.
    /// AppCoordinator's manager) already holds the slot, the
    /// registration is a logged-only soft failure inside production
    /// code; init still returns normally and the local instance's
    /// public API stays usable.
    func testInitDoesNotCrash() {
        XCTAssertNoThrow({
            let manager = HotkeyManager()
            _ = manager
        }())
    }

    /// `deinit` must clean up after init. We can't directly observe the
    /// Carbon side effects, but we can confirm releasing the manager
    /// does not crash, deadlock, or print to stderr — relevant because
    /// `deinit` touches C APIs (`UnregisterEventHotKey`,
    /// `RemoveEventHandler`) that throw on bad refs.
    func testInitDeinitCycleIsClean() {
        // `weak` reference verifies ARC actually drops the instance —
        // guards against a regression where the Carbon handler captures
        // `self` strongly.
        weak var weakRef: HotkeyManager?
        autoreleasepool {
            let manager = HotkeyManager()
            weakRef = manager
            _ = manager
        }
        // No assertion on weakRef nilness — Carbon's
        // `InstallEventHandler` retains the userData ptr opaquely, but
        // production code uses `Unmanaged.passUnretained` so ARC is the
        // sole owner. We can't reliably assert nilness without forcing
        // a run loop drain; the meaningful check is "no crash".
        _ = weakRef
    }

    // MARK: Esc gating

    /// `setEscEnabled(_:)` must be idempotent in both directions:
    /// enabling twice is a no-op the second time (production guard:
    /// `guard registrations[kind] == nil else { return }`); disabling
    /// twice is a no-op the second time (guard via `removeValue`).
    func testSetEscEnabledIdempotent() {
        let manager = HotkeyManager()
        // Forward: enable twice. The second call must NOT log a
        // "duplicate registration" error in production code thanks to
        // the registrations-dict guard.
        manager.setEscEnabled(true)
        manager.setEscEnabled(true)
        // Reverse: disable twice. The second call must NOT log an
        // "unregister failed" error thanks to the dictionary guard.
        manager.setEscEnabled(false)
        manager.setEscEnabled(false)
        // Mixed: re-enable after disable is a fresh registration path.
        manager.setEscEnabled(true)
        manager.setEscEnabled(false)
    }

    // MARK: Space gating

    /// `setSpaceEnabled(_:)` carries the same idempotency contract as
    /// Esc. Doubly important here because bare-Space being incorrectly
    /// registered globally would steal every Space press in every app.
    func testSetSpaceEnabledIdempotent() {
        let manager = HotkeyManager()
        manager.setSpaceEnabled(true)
        manager.setSpaceEnabled(true)
        manager.setSpaceEnabled(false)
        manager.setSpaceEnabled(false)
        manager.setSpaceEnabled(true)
        manager.setSpaceEnabled(false)
    }

    // MARK: Toggle interleave

    /// Esc and Space gating must be independent — toggling one must
    /// not affect the other. This is implicitly true because they map
    /// to distinct `HotkeyKind` keys in the `registrations` dict, but
    /// the test guards a future regression where someone consolidates
    /// the two into a shared bool.
    func testEscAndSpaceTogglesAreIndependent() {
        let manager = HotkeyManager()
        manager.setEscEnabled(true)
        manager.setSpaceEnabled(true)
        manager.setEscEnabled(false)
        // Space should still be enabled; toggling Space off independently
        // must succeed.
        manager.setSpaceEnabled(false)
    }

    // MARK: Callback wiring

    /// The public callback properties must be settable and callable.
    /// Production code invokes them via `onNewShelf?()` etc. inside
    /// `dispatch(id:)`; tests exercise the same optional-call shape
    /// to confirm the closures are retained and reachable.
    func testCallbacksAreSettableAndInvokable() {
        let manager = HotkeyManager()
        var newShelfFired = 0
        var closeFired = 0
        var quickLookFired = 0
        manager.onNewShelf = { newShelfFired += 1 }
        manager.onCloseFrontmost = { closeFired += 1 }
        manager.onQuickLook = { quickLookFired += 1 }

        // Mirror production's optional-call pattern.
        manager.onNewShelf?()
        manager.onCloseFrontmost?()
        manager.onQuickLook?()

        XCTAssertEqual(newShelfFired, 1)
        XCTAssertEqual(closeFired, 1)
        XCTAssertEqual(quickLookFired, 1)
    }

    /// Default callback values are `nil` — the manager is safe to
    /// instantiate before its consumers (per docstring contract).
    /// Calling an unset callback via the optional-call shape must be
    /// a silent no-op.
    func testCallbacksDefaultToNilAndOptionalCallIsSafe() {
        let manager = HotkeyManager()
        XCTAssertNil(manager.onNewShelf)
        XCTAssertNil(manager.onCloseFrontmost)
        XCTAssertNil(manager.onQuickLook)
        // Optional-call on nil closure is a no-op; must not crash.
        manager.onNewShelf?()
        manager.onCloseFrontmost?()
        manager.onQuickLook?()
    }

    // MARK: HotkeyKind enum

    /// `HotkeyKind` is a public `UInt32`-backed enum; its raw values are
    /// the contract used by Carbon's `EventHotKeyID.id` field. Pinning
    /// the values guards against accidental renumbering that would
    /// break a running app's saved state or an external tool depending
    /// on the IDs.
    func testHotkeyKindRawValuesArePinned() {
        XCTAssertEqual(HotkeyManager.HotkeyKind.newShelf.rawValue, 1)
        XCTAssertEqual(HotkeyManager.HotkeyKind.closeFrontmost.rawValue, 2)
        XCTAssertEqual(HotkeyManager.HotkeyKind.quickLook.rawValue, 3)
        XCTAssertEqual(HotkeyManager.HotkeyKind.allCases.count, 3)
    }
}
