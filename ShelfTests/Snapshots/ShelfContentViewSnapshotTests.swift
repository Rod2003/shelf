// Visual regression tests for ShelfContentView.
//
// We host the SwiftUI view inside an `NSHostingView` and ask
// swift-snapshot-testing to capture a PNG against a fixed frame, in both
// light and dark color schemes. The first run will fail with "no
// reference image" errors and write the references under
// `ShelfTests/Snapshots/__Snapshots__/` — those PNGs are the committed
// baseline. Subsequent runs compare the rendered hosting view against
// the stored references.
//
// Notes:
//   • Thumbnail loading is intentionally NOT exercised — we don't pass
//     a `BookmarkResolver` or `ThumbnailService`, so file items render
//     the SF Symbol placeholder. That keeps these snapshots
//     deterministic and free of file-system / Quick Look variability.
//   • Setting `recordSnapshots = true` forces re-recording even when
//     references already exist; flip back to `false` before committing.
import XCTest
import SwiftUI
import AppKit
import SnapshotTesting
@testable import Shelf
import ShelfCore

@MainActor
final class ShelfContentViewSnapshotTests: XCTestCase {

    /// Set to true to forcibly regenerate references; commit them and
    /// switch back to false. Leaving this false also works for the
    /// initial recording — the library writes references on first miss.
    private let recordSnapshots = false

    private static let snapshotSize = CGSize(width: 360, height: 320)

    // MARK: - Fixture helpers

    private func makeShelf(items: [ShelfItem] = [], name: String = "") -> Shelf {
        Shelf(name: name, items: items)
    }

    private func makeViewModel(_ shelf: Shelf) -> ShelfViewModel {
        ShelfViewModel(shelf: shelf)
    }

    private func sampleFileBookmarkItem(name: String = "report.pdf") -> ShelfItem {
        // Stable id + createdAt so the rendered cell label is identical
        // run-over-run; only `displayName` reaches the screen.
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

    /// Render the view in an NSHostingView at a fixed size and snapshot.
    /// `colorScheme` is forced via the SwiftUI environment so a single
    /// test machine produces both light- and dark-mode references.
    private func snapshot(
        _ view: some View,
        named name: String,
        scheme: ColorScheme,
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
        host.frame = CGRect(origin: .zero, size: Self.snapshotSize)
        host.layoutSubtreeIfNeeded()

        if recordSnapshots {
            assertSnapshot(
                of: host,
                as: .image(size: Self.snapshotSize),
                named: name,
                record: true,
                file: file,
                testName: testName,
                line: line
            )
        } else {
            assertSnapshot(
                of: host,
                as: .image(size: Self.snapshotSize),
                named: name,
                file: file,
                testName: testName,
                line: line
            )
        }
    }

    // MARK: - Empty state

    func testEmptyShelfLight() {
        let vm = makeViewModel(makeShelf())
        snapshot(ShelfContentView(viewModel: vm), named: "empty", scheme: .light)
    }

    func testEmptyShelfDark() {
        let vm = makeViewModel(makeShelf())
        snapshot(ShelfContentView(viewModel: vm), named: "empty", scheme: .dark)
    }

    // MARK: - Three mixed items

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

    // MARK: - Many items (grid wraps)

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

    // MARK: - Named shelf header

    func testNamedShelfHeaderLight() {
        let vm = makeViewModel(makeShelf(items: [sampleTextItem()], name: "Project Notes"))
        snapshot(ShelfContentView(viewModel: vm), named: "named-shelf", scheme: .light)
    }

    func testNamedShelfHeaderDark() {
        let vm = makeViewModel(makeShelf(items: [sampleTextItem()], name: "Project Notes"))
        snapshot(ShelfContentView(viewModel: vm), named: "named-shelf", scheme: .dark)
    }
}
