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

    func testExpandWithWindowAnimationSerializesPillAndDrawerState() async {
        let shelf = makeShelf(itemCount: 3)
        let vm = ShelfViewModel(shelf: shelf)
        let animateWindowCalled = expectation(description: "animateWindow called")

        vm.animateWindow = { expanded, duration, completion in
            XCTAssertTrue(expanded)
            XCTAssertEqual(duration, ShelfAnimation.expansionDuration, accuracy: 0.001)
            XCTAssertFalse(vm.showsCollapsedPill)
            XCTAssertFalse(vm.isExpanded)
            animateWindowCalled.fulfill()
            completion()
        }

        vm.setExpanded(true)

        await fulfillment(of: [animateWindowCalled], timeout: 1.0)
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(vm.isExpanded)
        XCTAssertFalse(vm.showsCollapsedPill)
        XCTAssertFalse(vm.hidesDrawerLabels)
    }

    func testRepeatedExpandRequestsDoNotStartASecondWindowAnimation() async {
        let shelf = makeShelf(itemCount: 3)
        let vm = ShelfViewModel(shelf: shelf)
        let animateWindowCalled = expectation(description: "animateWindow called once")
        var animateWindowCalls = 0
        var completion: (() -> Void)?

        vm.animateWindow = { expanded, _, finished in
            XCTAssertTrue(expanded)
            animateWindowCalls += 1
            completion = finished
            animateWindowCalled.fulfill()
        }

        vm.setExpanded(true)
        vm.setExpanded(true)

        await fulfillment(of: [animateWindowCalled], timeout: 1.0)
        XCTAssertEqual(animateWindowCalls, 1)

        completion?()
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(vm.isExpanded)
        XCTAssertEqual(animateWindowCalls, 1)
    }

    func testCollapseDuringPendingExpandCancelsTransition() async {
        let shelf = makeShelf(itemCount: 3)
        let vm = ShelfViewModel(shelf: shelf)
        let expansionStarted = expectation(description: "expansion window animation started")
        let collapseStarted = expectation(description: "collapse window animation started")
        var animationRequests: [Bool] = []
        var expansionCompletion: (() -> Void)?
        var collapseCompletion: (() -> Void)?

        vm.animateWindow = { expanded, _, completion in
            animationRequests.append(expanded)
            if expanded {
                expansionCompletion = completion
                expansionStarted.fulfill()
            } else {
                collapseCompletion = completion
                collapseStarted.fulfill()
            }
        }

        vm.setExpanded(true)
        await fulfillment(of: [expansionStarted], timeout: 1.0)

        vm.setExpanded(false)
        expansionCompletion?()
        await fulfillment(of: [collapseStarted], timeout: 1.0)
        collapseCompletion?()

        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertFalse(vm.isExpanded)
        XCTAssertTrue(vm.showsCollapsedPill)
        XCTAssertFalse(vm.hidesDrawerLabels)
        XCTAssertEqual(animationRequests, [true, false])
    }
}
