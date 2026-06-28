import Foundation
import Combine
import SwiftUI
import ShelfCore

public enum ShelfAnimation {
    public static let expansionDuration: TimeInterval = PanelPositioner.expansionDuration
    public static let collapseDuration: TimeInterval = 0.48
    public static let expansion: Animation = .timingCurve(
        0.32,
        0.94,
        0.36,
        1.0,
        duration: PanelPositioner.expansionDuration
    )
    public static let collapse: Animation = .timingCurve(0.22, 0.88, 0.24, 1.0, duration: 0.48)
    public static let pillFade: Animation = .easeOut(duration: 0.08)
}

private struct ShelfSelectionState: Equatable {
    struct ExpandedSelection: Equatable {
        var itemIDs: Set<ItemID> = []
        var activeItemID: ItemID?
    }

    var isCollapsedStackSelected = false
    var expanded = ExpandedSelection()
}

@MainActor
public final class ShelfViewModel: ObservableObject {
    public let shelfID: ShelfGroupID
    @Published public var name: String
    @Published public var items: [ShelfItem]
    @Published public var isExpanded: Bool
    @Published public private(set) var showsCollapsedPill: Bool
    @Published public private(set) var hidesDrawerLabels: Bool
    @Published public var isDropTargeted: Bool
    @Published public private(set) var quickLookSourceFrames: [ItemID: CGRect]
    @Published private var selectionState = ShelfSelectionState()
    private var isExpansionTransitionInFlight = false
    private var isWindowAnimationInFlight = false
    private var desiredExpanded = false

    public var animateWindow: ((_ expanded: Bool, _ duration: TimeInterval, _ completion: @escaping () -> Void) -> Void)?

    public var selectedItemID: ItemID? {
        selectionState.isCollapsedStackSelected ? items.first?.id : nil
    }

    public var drawerSelection: Set<ItemID> {
        selectionState.expanded.itemIDs
    }

    public var drawerActiveSelectionID: ItemID? {
        selectionState.expanded.activeItemID
    }

    public init(shelf: ShelfGroup) {
        self.shelfID = shelf.id
        self.name = shelf.name
        self.items = shelf.items
        self.isExpanded = false
        self.showsCollapsedPill = true
        self.hidesDrawerLabels = false
        self.isDropTargeted = false
        self.quickLookSourceFrames = [:]
    }

    public func setExpanded(_ expanded: Bool) {
        guard desiredExpanded != expanded || isExpanded != expanded else { return }
        desiredExpanded = expanded

        if isExpansionTransitionInFlight {
            if !expanded, !isWindowAnimationInFlight, !isExpanded {
                restoreCollapsedIdle()
            }
            return
        }

        guard isExpanded != expanded else { return }
        isExpansionTransitionInFlight = true

        if expanded {
            hidesDrawerLabels = false
            withAnimation(ShelfAnimation.pillFade) {
                showsCollapsedPill = false
            } completion: { [weak self] in
                guard let self else { return }
                guard self.desiredExpanded else {
                    self.restoreCollapsedIdle()
                    return
                }
                self.runWindowAnimation(expanded: true, duration: ShelfAnimation.expansionDuration) { [weak self] in
                    guard let self else { return }
                    if self.desiredExpanded {
                        self.finishExpanding()
                    } else {
                        self.collapseExpandedWindowAfterCancelledExpand()
                    }
                }
            }
        } else {
            hidesDrawerLabels = true
            withAnimation(ShelfAnimation.collapse) {
                isExpanded = false
            } completion: { [weak self] in
                self?.runWindowAnimation(expanded: false, duration: ShelfAnimation.collapseDuration) { [weak self] in
                    self?.finishCollapsing()
                }
            }
        }
    }

    private func runWindowAnimation(
        expanded: Bool,
        duration: TimeInterval,
        completion: @escaping () -> Void
    ) {
        isWindowAnimationInFlight = true
        guard let animateWindow else {
            isWindowAnimationInFlight = false
            completion()
            return
        }
        animateWindow(expanded, duration) { [weak self] in
            self?.isWindowAnimationInFlight = false
            completion()
        }
    }

    private func finishExpanding() {
        withAnimation(ShelfAnimation.expansion) {
            isExpanded = true
        } completion: {
            self.isExpansionTransitionInFlight = false
            if !self.desiredExpanded {
                self.setExpanded(false)
            }
        }
    }

    private func finishCollapsing() {
        withAnimation(ShelfAnimation.pillFade) {
            showsCollapsedPill = true
        } completion: {
            self.hidesDrawerLabels = false
            self.isExpansionTransitionInFlight = false
            if self.desiredExpanded {
                self.setExpanded(true)
            }
        }
    }

    private func collapseExpandedWindowAfterCancelledExpand() {
        runWindowAnimation(expanded: false, duration: ShelfAnimation.collapseDuration) { [weak self] in
            self?.finishCollapsing()
        }
    }

    private func restoreCollapsedIdle() {
        isWindowAnimationInFlight = false
        isExpansionTransitionInFlight = false
        isExpanded = false
        hidesDrawerLabels = false
        withAnimation(ShelfAnimation.pillFade) {
            showsCollapsedPill = true
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
        let liveIDs = Set(shelf.items.map(\.id))
        selectionState.isCollapsedStackSelected = selectionState.isCollapsedStackSelected && !shelf.items.isEmpty
        selectionState.expanded.itemIDs.formIntersection(liveIDs)
        quickLookSourceFrames = quickLookSourceFrames.filter { liveIDs.contains($0.key) }
        if let active = selectionState.expanded.activeItemID, !liveIDs.contains(active) {
            selectionState.expanded.activeItemID = selectionState.expanded.itemIDs.first
        }
    }

    public func remove(itemID: ItemID) {
        items.removeAll { $0.id == itemID }
        selectionState.isCollapsedStackSelected = selectionState.isCollapsedStackSelected && !items.isEmpty
        selectionState.expanded.itemIDs.remove(itemID)
        quickLookSourceFrames.removeValue(forKey: itemID)
        if selectionState.expanded.activeItemID == itemID {
            selectionState.expanded.activeItemID = selectionState.expanded.itemIDs.first
        }
    }

    public func removeAll(itemIDs: Set<ItemID>) {
        guard !itemIDs.isEmpty else { return }
        items.removeAll { itemIDs.contains($0.id) }
        selectionState.isCollapsedStackSelected = selectionState.isCollapsedStackSelected && !items.isEmpty
        selectionState.expanded.itemIDs.subtract(itemIDs)
        for itemID in itemIDs {
            quickLookSourceFrames.removeValue(forKey: itemID)
        }
        if let active = selectionState.expanded.activeItemID, itemIDs.contains(active) {
            selectionState.expanded.activeItemID = selectionState.expanded.itemIDs.first
        }
    }

    public func selectOnly(_ itemID: ItemID) {
        selectionState.expanded.itemIDs = [itemID]
        selectionState.expanded.activeItemID = itemID
    }

    public func selectCollapsedStack() {
        selectionState.isCollapsedStackSelected = !items.isEmpty
    }

    public func clearCollapsedStackSelection() {
        guard !isExpanded else { return }
        selectionState.isCollapsedStackSelected = false
    }

    public func toggle(_ itemID: ItemID) {
        if selectionState.expanded.itemIDs.contains(itemID) {
            selectionState.expanded.itemIDs.remove(itemID)
            if selectionState.expanded.activeItemID == itemID {
                selectionState.expanded.activeItemID = selectionState.expanded.itemIDs.first
            }
        } else {
            selectionState.expanded.itemIDs.insert(itemID)
            selectionState.expanded.activeItemID = itemID
        }
    }

    public func extendSelection(to itemID: ItemID) {
        guard
            let anchor = selectionState.expanded.activeItemID,
            let anchorIdx = items.firstIndex(where: { $0.id == anchor }),
            let targetIdx = items.firstIndex(where: { $0.id == itemID })
        else {
            selectOnly(itemID)
            return
        }
        let range = anchorIdx <= targetIdx ? anchorIdx...targetIdx : targetIdx...anchorIdx
        selectionState.expanded.itemIDs = Set(items[range].map(\.id))
        selectionState.expanded.activeItemID = itemID
    }

    public var quickLookTargetItems: [ShelfItem] {
        if isExpanded {
            return items.filter { selectionState.expanded.itemIDs.contains($0.id) }
        }
        return selectionState.isCollapsedStackSelected ? items : []
    }

    public func setQuickLookSourceFrame(_ frame: CGRect?, for itemIDs: [ItemID]) {
        let liveIDs = Set(items.map(\.id))
        var nextFrames = quickLookSourceFrames

        for itemID in itemIDs where liveIDs.contains(itemID) {
            if let frame, !frame.isNull, !frame.isEmpty {
                nextFrames[itemID] = frame
            } else {
                nextFrames.removeValue(forKey: itemID)
            }
        }

        if nextFrames != quickLookSourceFrames {
            quickLookSourceFrames = nextFrames
        }
    }

    public func reorder(from source: Int, to destination: Int) {
        guard items.indices.contains(source), destination >= 0, destination <= items.count else { return }
        let item = items.remove(at: source)
        let dest = destination > source ? destination - 1 : destination
        items.insert(item, at: dest)
    }
}
