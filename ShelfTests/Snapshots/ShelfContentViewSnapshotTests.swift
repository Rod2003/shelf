import XCTest
import SwiftUI
import AppKit
import SnapshotTesting
@testable import Shelf
import ShelfCore

@MainActor
final class ShelfContentViewSnapshotTests: XCTestCase {
    private let recordSnapshots = false

    private static let collapsedSnapshotSize = CGSize(width: 360, height: 320)
    private static let expandedSnapshotSize = CGSize(width: 520, height: 320)

    private func makeShelf(items: [ShelfItem] = [], name: String = "") -> ShelfGroup {
        ShelfGroup(name: name, items: items)
    }

    private func makeViewModel(_ shelf: ShelfGroup) -> ShelfViewModel {
        ShelfViewModel(shelf: shelf)
    }

    private func sampleFileBookmarkItem(name: String = "report.pdf") -> ShelfItem {
        let dummyData = Data(repeating: 0, count: 16)
        let record = BookmarkRecord(
            bookmarkData: dummyData,
            originalPath: "/tmp/\(name)",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        return ShelfItem(
            kind: .fileBookmark(record),
            displayName: name,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func sampleWebURLItem(url: String = "https://example.com") -> ShelfItem {
        ShelfItem(
            kind: .webURL(URL(string: url)!),
            displayName: "example.com",
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func sampleTextItem(_ text: String = "Lorem ipsum dolor sit amet") -> ShelfItem {
        ShelfItem(
            kind: .text(text),
            displayName: String(text.prefix(40)),
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
    private func snapshot(
        _ view: some View,
        named name: String,
        scheme: ColorScheme,
        size: CGSize = collapsedSnapshotSize,
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        let appearance: NSAppearance? = (scheme == .dark)
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)

        let host = NSHostingView(rootView:
            view.environment(\.colorScheme, scheme)
        )
        host.appearance = appearance
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        if recordSnapshots {
            assertSnapshot(
                of: host,
                as: .image(size: size),
                named: name,
                record: true,
                file: file,
                testName: testName,
                line: line
            )
        } else {
            assertSnapshot(
                of: host,
                as: .image(size: size),
                named: name,
                file: file,
                testName: testName,
                line: line
            )
        }
    }

    func testEmptyShelfLight() {
        let vm = makeViewModel(makeShelf())
        snapshot(ShelfContentView(viewModel: vm), named: "empty", scheme: .light)
    }

    func testEmptyShelfDark() {
        let vm = makeViewModel(makeShelf())
        snapshot(ShelfContentView(viewModel: vm), named: "empty", scheme: .dark)
    }

    func testOneItemLight() {
        let vm = makeViewModel(makeShelf(items: [sampleFileBookmarkItem(name: "report.pdf")]))
        snapshot(ShelfContentView(viewModel: vm), named: "one-item", scheme: .light)
    }

    func testTwoItemsLight() {
        let items = [sampleFileBookmarkItem(name: "a.png"), sampleFileBookmarkItem(name: "b.png")]
        let vm = makeViewModel(makeShelf(items: items))
        snapshot(ShelfContentView(viewModel: vm), named: "two-items", scheme: .light)
    }

    func testThreeItemsLight() {
        let items = [sampleFileBookmarkItem(), sampleWebURLItem(), sampleTextItem()]
        let vm = makeViewModel(makeShelf(items: items, name: "Mixed"))
        snapshot(ShelfContentView(viewModel: vm), named: "three-items", scheme: .light)
    }

    func testThreeItemsDark() {
        let items = [sampleFileBookmarkItem(), sampleWebURLItem(), sampleTextItem()]
        let vm = makeViewModel(makeShelf(items: items, name: "Mixed"))
        snapshot(ShelfContentView(viewModel: vm), named: "three-items", scheme: .dark)
    }

    func testManyItemsLight() {
        let items = (1...12).map { sampleFileBookmarkItem(name: "doc\($0).pdf") }
        let vm = makeViewModel(makeShelf(items: items, name: "Many"))
        snapshot(ShelfContentView(viewModel: vm), named: "many-items", scheme: .light)
    }

    func testManyItemsDark() {
        let items = (1...12).map { sampleFileBookmarkItem(name: "doc\($0).pdf") }
        let vm = makeViewModel(makeShelf(items: items, name: "Many"))
        snapshot(ShelfContentView(viewModel: vm), named: "many-items", scheme: .dark)
    }

    func testLongFilenameLight() {
        let vm = makeViewModel(makeShelf(items: [
            sampleFileBookmarkItem(name: "Extremely long project archive filename.pdf"),
        ]))
        snapshot(ShelfContentView(viewModel: vm), named: "long-filename", scheme: .light)
    }

    func testLongFilenameDark() {
        let vm = makeViewModel(makeShelf(items: [
            sampleFileBookmarkItem(name: "Extremely long project archive filename.pdf"),
        ]))
        snapshot(ShelfContentView(viewModel: vm), named: "long-filename", scheme: .dark)
    }

    func testExpandedOneItemLight() {
        let vm = makeViewModel(makeShelf(items: [sampleFileBookmarkItem(name: "report.pdf")]))
        vm.isExpanded = true
        vm.selectOnly(vm.items[0].id)
        snapshot(
            ShelfContentView(viewModel: vm),
            named: "expanded-one-item",
            scheme: .light,
            size: Self.expandedSnapshotSize
        )
    }

    func testExpandedManyItemsDark() {
        let items = (1...8).map { sampleFileBookmarkItem(name: "doc\($0).pdf") }
        let vm = makeViewModel(makeShelf(items: items))
        vm.isExpanded = true
        vm.selectOnly(items[1].id)
        snapshot(
            ShelfContentView(viewModel: vm),
            named: "expanded-many-items",
            scheme: .dark,
            size: Self.expandedSnapshotSize
        )
    }
}

@MainActor
final class ShelfViewModelSelectionTests: XCTestCase {
    private func item(_ name: String) -> ShelfItem {
        ShelfItem(kind: .text(name), displayName: name, createdAt: Date(timeIntervalSince1970: 0))
    }

    private func makeViewModel() -> ShelfViewModel {
        ShelfViewModel(shelf: ShelfGroup(items: [item("a"), item("b"), item("c"), item("d")]))
    }

    func testSelectOnlySetsDrawerAndQuickLookTarget() {
        let vm = makeViewModel()
        vm.isExpanded = true

        vm.selectOnly(vm.items[1].id)

        XCTAssertEqual(vm.drawerSelection, [vm.items[1].id])
        XCTAssertEqual(vm.drawerActiveSelectionID, vm.items[1].id)
        XCTAssertEqual(vm.quickLookTargetItem?.id, vm.items[1].id)
    }

    func testCommandToggleRemovesActiveSelection() {
        let vm = makeViewModel()
        vm.selectOnly(vm.items[0].id)
        vm.toggle(vm.items[1].id)
        XCTAssertEqual(vm.drawerSelection, [vm.items[0].id, vm.items[1].id])

        vm.toggle(vm.items[1].id)

        XCTAssertEqual(vm.drawerSelection, [vm.items[0].id])
        XCTAssertNotEqual(vm.drawerActiveSelectionID, vm.items[1].id)
    }

    func testShiftClickExtendsContiguousRange() {
        let vm = makeViewModel()
        vm.selectOnly(vm.items[0].id)

        vm.extendSelection(to: vm.items[2].id)

        XCTAssertEqual(vm.drawerSelection, [vm.items[0].id, vm.items[1].id, vm.items[2].id])
        XCTAssertEqual(vm.drawerActiveSelectionID, vm.items[2].id)
    }

    func testReloadReconcilesDeletedSelection() {
        let vm = makeViewModel()
        vm.selectOnly(vm.items[2].id)
        let surviving = [vm.items[0], vm.items[1]]
        let updated = ShelfGroup(id: vm.shelfID, items: surviving)

        vm.reload(from: updated)

        XCTAssertEqual(vm.items.map(\.id), surviving.map(\.id))
        XCTAssertFalse(vm.drawerSelection.contains(where: { !surviving.map(\.id).contains($0) }))
        XCTAssertNil(vm.drawerActiveSelectionID)
    }
}
