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

    func testCollapsedReturnsAllItems() {
        let shelf = makeShelf(itemCount: 3)
        let vm = ShelfViewModel(shelf: shelf)
        XCTAssertFalse(vm.isExpanded)

        let targets = vm.quickLookTargetItems
        XCTAssertEqual(targets.map(\.id), shelf.items.map(\.id))
    }

    func testCollapsedEmptyShelfReturnsEmpty() {
        let vm = ShelfViewModel(shelf: makeShelf(itemCount: 0))
        XCTAssertTrue(vm.quickLookTargetItems.isEmpty)
    }

    func testExpandedReturnsDrawerSelection() {
        let shelf = makeShelf(itemCount: 3)
        let vm = ShelfViewModel(shelf: shelf)
        vm.isExpanded = true
        vm.drawerSelection = [shelf.items[0].id, shelf.items[2].id]

        let targets = vm.quickLookTargetItems
        XCTAssertEqual(Set(targets.map(\.id)), Set([shelf.items[0].id, shelf.items[2].id]))
    }

    func testExpandedNoSelectionReturnsEmpty() {
        let shelf = makeShelf(itemCount: 3)
        let vm = ShelfViewModel(shelf: shelf)
        vm.isExpanded = true
        vm.drawerSelection = []

        XCTAssertTrue(vm.quickLookTargetItems.isEmpty)
    }

    func testExpandedReturnsItemsInShelfOrderNotSelectionOrder() {
        let shelf = makeShelf(itemCount: 4)
        let vm = ShelfViewModel(shelf: shelf)
        vm.isExpanded = true
        vm.drawerSelection = [shelf.items[3].id, shelf.items[1].id]

        let targets = vm.quickLookTargetItems
        XCTAssertEqual(targets.map(\.id), [shelf.items[1].id, shelf.items[3].id])
    }
}
