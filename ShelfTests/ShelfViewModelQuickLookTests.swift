import XCTest

import ShelfCore

@testable import Shelf

@MainActor
final class ShelfViewModelQuickLookTests: XCTestCase {
    private func makeShelf(itemCount: Int) -> ShelfGroup {
        let items: [ShelfItem] = (0..<itemCount).map { i in
            ShelfItem(
                kind: .text("body-\(i)"),
                displayName: "item-\(i)"
            )
        }
        return ShelfGroup(name: "test", items: items)
    }

    func testCollapsedWithoutStackSelectionReturnsEmpty() {
        let shelf = makeShelf(itemCount: 3)
        let vm = ShelfViewModel(shelf: shelf)
        XCTAssertFalse(vm.isExpanded)

        XCTAssertTrue(vm.quickLookTargetItems.isEmpty)
    }

    func testCollapsedSelectedStackReturnsAllItems() {
        let shelf = makeShelf(itemCount: 3)
        let vm = ShelfViewModel(shelf: shelf)
        vm.selectCollapsedStack()

        let targets = vm.quickLookTargetItems
        XCTAssertEqual(targets.map(\.id), shelf.items.map(\.id))
    }

    func testClearingCollapsedStackSelectionDisablesQuickLook() {
        let shelf = makeShelf(itemCount: 3)
        let vm = ShelfViewModel(shelf: shelf)
        vm.selectCollapsedStack()

        vm.clearCollapsedStackSelection()

        XCTAssertNil(vm.selectedItemID)
        XCTAssertTrue(vm.quickLookTargetItems.isEmpty)
    }

    func testCollapsedEmptyShelfReturnsEmpty() {
        let vm = ShelfViewModel(shelf: makeShelf(itemCount: 0))
        XCTAssertTrue(vm.quickLookTargetItems.isEmpty)
    }

    func testExpandedReturnsDrawerSelection() {
        let shelf = makeShelf(itemCount: 3)
        let vm = ShelfViewModel(shelf: shelf)
        vm.isExpanded = true
        vm.selectOnly(shelf.items[0].id)
        vm.toggle(shelf.items[2].id)

        let targets = vm.quickLookTargetItems
        XCTAssertEqual(Set(targets.map(\.id)), Set([shelf.items[0].id, shelf.items[2].id]))
    }

    func testExpandedNoSelectionReturnsEmpty() {
        let shelf = makeShelf(itemCount: 3)
        let vm = ShelfViewModel(shelf: shelf)
        vm.isExpanded = true

        XCTAssertTrue(vm.quickLookTargetItems.isEmpty)
    }

    func testExpandedReturnsItemsInShelfOrderNotSelectionOrder() {
        let shelf = makeShelf(itemCount: 4)
        let vm = ShelfViewModel(shelf: shelf)
        vm.isExpanded = true
        vm.selectOnly(shelf.items[3].id)
        vm.toggle(shelf.items[1].id)

        let targets = vm.quickLookTargetItems
        XCTAssertEqual(targets.map(\.id), [shelf.items[1].id, shelf.items[3].id])
    }

    func testQuickLookSourceFramesAreClearedWhenItemIsRemoved() {
        let shelf = makeShelf(itemCount: 2)
        let vm = ShelfViewModel(shelf: shelf)
        let frame = CGRect(x: 10, y: 20, width: 30, height: 40)

        vm.setQuickLookSourceFrame(frame, for: [shelf.items[0].id])

        XCTAssertEqual(vm.quickLookSourceFrames[shelf.items[0].id], frame)

        vm.remove(itemID: shelf.items[0].id)

        XCTAssertNil(vm.quickLookSourceFrames[shelf.items[0].id])
    }
}
