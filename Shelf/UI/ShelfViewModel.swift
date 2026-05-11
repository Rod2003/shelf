// UI presentation layer for a single shelf's contents.
// Bridges ShelfCore value types to SwiftUI via Combine's ObservableObject.
//
// This view model is intentionally a thin, optimistic-state container:
// - It does not call ShelfStore directly. The AppCoordinator owns the
//   store and pushes updates in via `reload(from:)`.
// - The mutating helpers (`remove`, `reorder`) produce local optimistic
//   updates so drag-OUT and shake-evict feel instant; the call site is
//   responsible for persisting the change.

import Foundation
import Combine
import ShelfCore

/// Observable presentation state for one `Shelf`.
///
/// Construction is cheap; rebind via `reload(from:)` whenever the
/// underlying `Shelf` value changes upstream (e.g. from `ShelfStore.onChange`
/// in the App Coordinator).
@MainActor
public final class ShelfViewModel: ObservableObject {
    public let shelfID: ShelfID
    @Published public var name: String
    @Published public var items: [ShelfItem]
    /// Currently-selected item, used by the AppCoordinator to drive the
    /// Quick Look coordinator and by `ShelfItemView` to render its selection
    /// background. `nil` means no selection. Mutating here is purely a
    /// presentation-state change; persistence is not involved.
    @Published public var selectedItemID: ItemID?

    public init(shelf: Shelf) {
        self.shelfID = shelf.id
        self.name = shelf.name
        self.items = shelf.items
        self.selectedItemID = nil
    }

    /// Reapply state from an updated `Shelf` value. The `shelfID` is fixed at
    /// init time and is not changed here; callers must build a new view model
    /// if they want to show a different shelf.
    public func reload(from shelf: Shelf) {
        self.name = shelf.name
        self.items = shelf.items
        // Drop the selection if the upstream value no longer contains it.
        if let sel = selectedItemID, !shelf.items.contains(where: { $0.id == sel }) {
            self.selectedItemID = nil
        }
    }

    /// Optimistically remove an item from the local list. Persistence via
    /// `ShelfStore.update(...)` is the call site's responsibility.
    public func remove(itemID: ItemID) {
        items.removeAll { $0.id == itemID }
        if selectedItemID == itemID { selectedItemID = nil }
    }

    /// Optimistically reorder the items array. Indices follow SwiftUI's
    /// `onMove(perform:)` convention: `destination` is the index BEFORE the
    /// move where the item should land, so a forward move adjusts by -1.
    public func reorder(from source: Int, to destination: Int) {
        guard items.indices.contains(source), destination >= 0, destination <= items.count else { return }
        let item = items.remove(at: source)
        let dest = destination > source ? destination - 1 : destination
        items.insert(item, at: dest)
    }
}
