// Shelf — T24 integration tests for drag-IN logic.
//
// Verifies that `DragItemFactory.makeItems(from:)` honors its documented
// pasteboard precedence rule (`.fileURL` > web URL > image > `.string`)
// and that the produced `ShelfItem`s round-trip end-to-end through
// `BookmarkResolver` for the file-bookmark variant.
//
// Tests deliberately use `NSPasteboard(name:)` with a unique per-test
// name to avoid contaminating the system general pasteboard, and create
// temporary files under `FileManager.default.temporaryDirectory` so they
// run cleanly in any environment without privileged paths.
//
// What is NOT covered here (out of scope for T24):
//   * Live drag from another app — that's T26 agent QA.
//   * `DragInView.performDragOperation(_:)` end-to-end — UI surface.
//   * `DragOutSource` full file-promise flow — same.
//
// Per the T24 spec, the pasteboard precedence + item-construction layer
// is the unit of integration we cover at this level; the remaining
// surfaces are covered by T26.

import AppKit
import XCTest

@testable import Shelf
import ShelfCore

@MainActor
final class DragInDragOutIntegrationTests: XCTestCase {

    /// Files created during a test, removed in `tearDown` to keep
    /// `tempDirectory` tidy across runs.
    private var createdFiles: [URL] = []

    override func tearDown() {
        for url in createdFiles {
            try? FileManager.default.removeItem(at: url)
        }
        createdFiles.removeAll()
        super.tearDown()
    }

    // MARK: Helpers

    /// Construct a freshly-named pasteboard with a UUID-derived name so
    /// concurrent test runs cannot collide. `NSPasteboard(name:)` returns
    /// or creates the pasteboard with that name; using a per-test UUID
    /// guarantees isolation from `.general` and from sibling tests.
    private func makeIsolatedPasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name("shelf-test-\(UUID().uuidString)")
        let pb = NSPasteboard(name: name)
        pb.clearContents()
        return pb
    }

    /// Create a temp file with deterministic content; tracked for cleanup.
    private func makeTempFile(name: String, contents: String = "shelf-test") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-test-\(UUID().uuidString)-\(name)")
        try contents.data(using: .utf8)!.write(to: url, options: .atomic)
        createdFiles.append(url)
        return url
    }

    /// Create a temp directory; tracked for cleanup.
    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-test-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        createdFiles.append(url)
        return url
    }

    // MARK: Precedence

    /// File URLs must take precedence over a coexisting `.string` payload
    /// even when both are advertised on the pasteboard (typical Safari /
    /// Finder behavior — they offer both for downloaded-file drags).
    func testFileURLPrecedenceOverString() throws {
        let file = try makeTempFile(name: "precedence.txt")
        let pb = makeIsolatedPasteboard()
        pb.writeObjects([file as NSURL])
        pb.setString("not the right item", forType: .string)

        let items = DragItemFactory.makeItems(from: pb)

        XCTAssertEqual(items.count, 1, "expected exactly one fileBookmark item")
        guard case let .fileBookmark(record) = items[0].kind else {
            return XCTFail("expected .fileBookmark, got \(items[0].kind)")
        }
        XCTAssertEqual(record.originalPath, file.path)
        XCTAssertFalse(record.bookmarkData.isEmpty, "bookmarkData must be non-empty")
        XCTAssertEqual(items[0].displayName, file.lastPathComponent)
    }

    // MARK: Web URL

    /// A bare web URL on the pasteboard must produce a `.webURL` item.
    /// The factory's `displayName` strategy prefers `host` truncated to
    /// `maxDisplayNameLength`; for `https://example.com/some/path` we
    /// expect `"example.com"` rather than the full URL.
    func testWebURLProducesWebURLItem() throws {
        let url = URL(string: "https://example.com/some/path?q=1")!
        let pb = makeIsolatedPasteboard()
        pb.writeObjects([url as NSURL])

        let items = DragItemFactory.makeItems(from: pb)

        XCTAssertEqual(items.count, 1)
        guard case let .webURL(itemURL) = items[0].kind else {
            return XCTFail("expected .webURL, got \(items[0].kind)")
        }
        XCTAssertEqual(itemURL, url)
        XCTAssertEqual(items[0].displayName, "example.com")
    }

    // MARK: Multiple web URLs

    /// Multiple web URLs on the pasteboard produce multiple items —
    /// confirms the factory's `webURLs.map(makeWebURLItem(from:))` path,
    /// distinct from the file-URL `compactMap` branch.
    func testMultipleWebURLsProduceMultipleItems() throws {
        let url1 = URL(string: "https://example.com")!
        let url2 = URL(string: "https://apple.com")!
        let pb = makeIsolatedPasteboard()
        pb.writeObjects([url1 as NSURL, url2 as NSURL])

        let items = DragItemFactory.makeItems(from: pb)

        XCTAssertEqual(items.count, 2)
        for item in items {
            guard case .webURL = item.kind else {
                return XCTFail("expected all items to be .webURL, got \(item.kind)")
            }
        }
    }

    // MARK: Text fallback

    /// Plain string only on the pasteboard must produce a `.text` item;
    /// `displayName` is the trimmed first 60 chars per factory contract.
    func testStringFallbackProducesTextItem() throws {
        let payload = "  hello shelf integration  "
        let pb = makeIsolatedPasteboard()
        pb.setString(payload, forType: .string)

        let items = DragItemFactory.makeItems(from: pb)

        XCTAssertEqual(items.count, 1)
        guard case let .text(text) = items[0].kind else {
            return XCTFail("expected .text, got \(items[0].kind)")
        }
        XCTAssertEqual(text, payload, "raw text payload preserved exactly")
        XCTAssertEqual(
            items[0].displayName,
            "hello shelf integration",
            "displayName is whitespace-trimmed"
        )
    }

    /// Long text input must have its `displayName` capped at 60 chars
    /// per factory's `String(trimmed.prefix(60))` rule. The full payload
    /// stays intact in the `.text` associated value.
    func testLongTextDisplayNameTruncated() throws {
        let payload = String(repeating: "a", count: 200)
        let pb = makeIsolatedPasteboard()
        pb.setString(payload, forType: .string)

        let items = DragItemFactory.makeItems(from: pb)

        XCTAssertEqual(items.count, 1)
        guard case let .text(text) = items[0].kind else {
            return XCTFail("expected .text, got \(items[0].kind)")
        }
        XCTAssertEqual(text.count, 200, "raw text length preserved")
        XCTAssertEqual(items[0].displayName.count, 60, "displayName capped at 60")
    }

    // MARK: Folder = single bookmark item

    /// A folder URL must produce ONE `.fileBookmark` item (not N items
    /// for the folder's contents). The factory's contract: "Folders are
    /// stored as a single `.fileBookmark` item (NOT expanded)."
    func testFolderProducesSingleFileBookmarkItem() throws {
        let folder = try makeTempFolder()
        // Add some children so a buggy expander would be tempting.
        for i in 0..<3 {
            let child = folder.appendingPathComponent("child\(i).txt")
            try Data("c".utf8).write(to: child)
        }

        let pb = makeIsolatedPasteboard()
        pb.writeObjects([folder as NSURL])

        let items = DragItemFactory.makeItems(from: pb)

        XCTAssertEqual(items.count, 1, "folder must produce exactly one item, not N")
        guard case let .fileBookmark(record) = items[0].kind else {
            return XCTFail("expected .fileBookmark, got \(items[0].kind)")
        }
        XCTAssertEqual(record.originalPath, folder.path)
    }

    // MARK: End-to-end bookmark roundtrip

    /// File bookmark item must round-trip through `BookmarkResolver`:
    /// drag-in produces a `BookmarkRecord` opaque blob; resolve recovers
    /// a usable URL pointing at the same file. This is the core invariant
    /// for drag-OUT later returning the same bytes that were dropped.
    func testFileBookmarkResolvesBackToOriginalURL() throws {
        let file = try makeTempFile(name: "roundtrip.txt", contents: "hello roundtrip")
        let pb = makeIsolatedPasteboard()
        pb.writeObjects([file as NSURL])

        let items = DragItemFactory.makeItems(from: pb)
        XCTAssertEqual(items.count, 1)
        guard case let .fileBookmark(record) = items[0].kind else {
            return XCTFail("expected .fileBookmark, got \(items[0].kind)")
        }

        let resolver = BookmarkResolver()
        let resolution = try resolver.resolve(record)
        defer { resolver.release(resolution.url) }

        // Resolved URL must point to the same file (path components may
        // differ in `/private/var` vs `/var` symlink prefixing on macOS;
        // resolve to canonical form for comparison).
        XCTAssertEqual(
            resolution.url.resolvingSymlinksInPath().lastPathComponent,
            file.lastPathComponent
        )
        let bytes = try Data(contentsOf: resolution.url)
        XCTAssertEqual(String(data: bytes, encoding: .utf8), "hello roundtrip")
        XCTAssertFalse(resolution.isStale, "freshly-created bookmark must not be stale")
    }

    // MARK: Empty pasteboard

    /// Pasteboard with no extractable types yields an empty array — the
    /// factory returns gracefully without throwing or returning nil.
    func testEmptyPasteboardYieldsNoItems() {
        let pb = makeIsolatedPasteboard()
        let items = DragItemFactory.makeItems(from: pb)
        XCTAssertEqual(items.count, 0)
    }

    // MARK: Non-http URL is ignored

    /// A `mailto:` URL is non-file and non-http; the factory's
    /// `readWebURLs` filter requires scheme to be http/https, so this
    /// must NOT be promoted to a `.webURL` item. (It may still be
    /// available as `.string` through an NSURL coercion; behavior is
    /// "no item" for mailto-only or "text item" if a string is set.)
    func testMailtoURLAloneYieldsNoWebURLItem() {
        let pb = makeIsolatedPasteboard()
        guard let mailto = URL(string: "mailto:test@example.com") else {
            return XCTFail("could not construct mailto URL")
        }
        pb.writeObjects([mailto as NSURL])

        let items = DragItemFactory.makeItems(from: pb)

        // The factory may promote mailto via NSURL→string fallback or
        // skip entirely; it MUST NOT produce a `.webURL` item.
        for item in items {
            if case .webURL = item.kind {
                XCTFail("mailto must not produce a .webURL item")
            }
        }
    }
}
