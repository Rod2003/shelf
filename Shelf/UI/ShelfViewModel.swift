import Foundation
import Combine
import SwiftUI
import ShelfCore

public enum ShelfAnimation {
    public static let expansionDuration: TimeInterval = 0.32
    public static let collapseDuration: TimeInterval = 0.48
    public static let expansion: Animation = .timingCurve(0.32, 0.94, 0.36, 1.0, duration: 0.32)
    public static let collapse: Animation = .timingCurve(0.22, 0.88, 0.24, 1.0, duration: 0.48)
    public static let pillFade: Animation = .easeOut(duration: 0.08)
}

@MainActor
public final class ShelfViewModel: ObservableObject {
    public let shelfID: ShelfGroupID
    @Published public var name: String
    @Published public var items: [ShelfItem]
    @Published public var selectedItemID: ItemID?
    @Published public var isExpanded: Bool
    @Published public private(set) var showsCollapsedPill: Bool
    @Published public private(set) var hidesDrawerLabels: Bool
    @Published public var drawerSelection: Set<ItemID>
    @Published public var drawerActiveSelectionID: ItemID?
    @Published public var isDropTargeted: Bool

    public var animateWindow: ((_ expanded: Bool, _ duration: TimeInterval, _ completion: @escaping () -> Void) -> Void)?

    public init(shelf: ShelfGroup) {
        self.shelfID = shelf.id
        self.name = shelf.name
        self.items = shelf.items
        self.selectedItemID = nil
        self.isExpanded = false
        self.showsCollapsedPill = true
        self.hidesDrawerLabels = false
        self.drawerSelection = []
        self.drawerActiveSelectionID = nil
        self.isDropTargeted = false
    }

    public func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        guard let animateWindow else {
            if expanded {
                hidesDrawerLabels = false
                withAnimation(ShelfAnimation.pillFade) {
                    showsCollapsedPill = false
                } completion: {
                    withAnimation(ShelfAnimation.expansion) { self.isExpanded = true }
                }
            } else {
                hidesDrawerLabels = true
                withAnimation(ShelfAnimation.collapse) {
                    showsCollapsedPill = true
                    isExpanded = false
                } completion: {
                    self.hidesDrawerLabels = false
                }
            }
            return
        }
        if expanded {
            hidesDrawerLabels = false
            withAnimation(ShelfAnimation.expansion) {
                showsCollapsedPill = false
                isExpanded = true
            }
            animateWindow(true, ShelfAnimation.expansionDuration) {}
        } else {
            hidesDrawerLabels = true
            withAnimation(ShelfAnimation.collapse) {
                showsCollapsedPill = true
                isExpanded = false
            }
            animateWindow(false, ShelfAnimation.collapseDuration) { [weak self] in
                self?.hidesDrawerLabels = false
            }
        }
    }

    public func setDropTargeted(_ targeted: Bool) {
        guard isDropTargeted != targeted else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            isDropTargeted = targeted
        }
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

    public func selectCollapsedStack() {
        selectedItemID = items.first?.id
    }

    public func clearCollapsedStackSelection() {
        guard !isExpanded else { return }
        selectedItemID = nil
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

    public var quickLookTargetItems: [ShelfItem] {
        if isExpanded {
            return items.filter { drawerSelection.contains($0.id) }
        }
        return selectedItemID == nil ? [] : items
    }

    public func reorder(from source: Int, to destination: Int) {
        guard items.indices.contains(source), destination >= 0, destination <= items.count else { return }
        let item = items.remove(at: source)
        let dest = destination > source ? destination - 1 : destination
        items.insert(item, at: dest)
    }
}
