import Foundation
import Combine
import ShelfCore

@MainActor
public final class ShelfViewModel: ObservableObject {
    public let shelfID: ShelfGroupID
    @Published public var name: String
    @Published public var items: [ShelfItem]
    @Published public var selectedItemID: ItemID?
    @Published public var isExpanded: Bool
    @Published public var drawerSelection: Set<ItemID>
    @Published public var drawerActiveSelectionID: ItemID?

    public init(shelf: ShelfGroup) {
        self.shelfID = shelf.id
        self.name = shelf.name
        self.items = shelf.items
        self.selectedItemID = nil
        self.isExpanded = false
        self.drawerSelection = []
        self.drawerActiveSelectionID = nil
    }

    public func reload(from shelf: ShelfGroup) {
        self.name = shelf.name
        self.items = shelf.items
        if let sel = selectedItemID, !shelf.items.contains(where: { $0.id == sel }) {
            self.selectedItemID = nil
        }
        let liveIDs = Set(shelf.items.map(\.id))
        drawerSelection.formIntersection(liveIDs)
        if let active = drawerActiveSelectionID, !liveIDs.contains(active) {
            drawerActiveSelectionID = drawerSelection.first
        }
    }

    public func remove(itemID: ItemID) {
        items.removeAll { $0.id == itemID }
        if selectedItemID == itemID { selectedItemID = nil }
        drawerSelection.remove(itemID)
        if drawerActiveSelectionID == itemID {
            drawerActiveSelectionID = drawerSelection.first
        }
    }

    public func removeAll(itemIDs: Set<ItemID>) {
        guard !itemIDs.isEmpty else { return }
        items.removeAll { itemIDs.contains($0.id) }
        if let selectedItemID, itemIDs.contains(selectedItemID) {
            self.selectedItemID = nil
        }
        drawerSelection.subtract(itemIDs)
        if let active = drawerActiveSelectionID, itemIDs.contains(active) {
            drawerActiveSelectionID = drawerSelection.first
        }
    }

    public func selectOnly(_ itemID: ItemID) {
        drawerSelection = [itemID]
        drawerActiveSelectionID = itemID
        selectedItemID = itemID
    }

    public func toggle(_ itemID: ItemID) {
        if drawerSelection.contains(itemID) {
            drawerSelection.remove(itemID)
            if drawerActiveSelectionID == itemID {
                drawerActiveSelectionID = drawerSelection.first
            }
            if selectedItemID == itemID {
                selectedItemID = drawerActiveSelectionID
            }
        } else {
            drawerSelection.insert(itemID)
            drawerActiveSelectionID = itemID
            selectedItemID = itemID
        }
    }

    public func extendSelection(to itemID: ItemID) {
        guard
            let anchor = drawerActiveSelectionID,
            let anchorIdx = items.firstIndex(where: { $0.id == anchor }),
            let targetIdx = items.firstIndex(where: { $0.id == itemID })
        else {
            selectOnly(itemID)
            return
        }
        let range = anchorIdx <= targetIdx ? anchorIdx...targetIdx : targetIdx...anchorIdx
        drawerSelection = Set(items[range].map(\.id))
        drawerActiveSelectionID = itemID
        selectedItemID = itemID
    }

    public var quickLookTargetItem: ShelfItem? {
        let targetID: ItemID?
        if isExpanded {
            targetID = drawerActiveSelectionID ?? drawerSelection.first
        } else {
            targetID = selectedItemID
        }
        return targetID.flatMap { id in items.first(where: { $0.id == id }) } ?? items.first
    }

    public func reorder(from source: Int, to destination: Int) {
        guard items.indices.contains(source), destination >= 0, destination <= items.count else { return }
        let item = items.remove(at: source)
        let dest = destination > source ? destination - 1 : destination
        items.insert(item, at: dest)
    }
}
