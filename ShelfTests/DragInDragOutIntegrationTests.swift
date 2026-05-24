import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import Shelf
import ShelfCore

@MainActor
final class DragInDragOutIntegrationTests: XCTestCase {
    private var createdFiles: [URL] = []

    override func tearDown() {
        for url in createdFiles {
            try? FileManager.default.removeItem(at: url)
        }
        createdFiles.removeAll()
        super.tearDown()
    }
    private func makeIsolatedPasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name("shelf-test-\(UUID().uuidString)")
        let pb = NSPasteboard(name: name)
        pb.clearContents()
        return pb
    }
    private func makeTempFile(name: String, contents: String = "shelf-test") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-test-\(UUID().uuidString)-\(name)")
        try contents.data(using: .utf8)!.write(to: url, options: .atomic)
        createdFiles.append(url)
        return url
    }
    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-test-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        createdFiles.append(url)
        return url
    }
    private func makePNGData() throws -> Data {
        let image = NSImage(size: CGSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            throw XCTSkip("Could not create test PNG data")
        }
        return png
    }
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
    func testFolderProducesSingleFileBookmarkItem() throws {
        let folder = try makeTempFolder()
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
        XCTAssertEqual(
            resolution.url.resolvingSymlinksInPath().lastPathComponent,
            file.lastPathComponent
        )
        let bytes = try Data(contentsOf: resolution.url)
        XCTAssertEqual(String(data: bytes, encoding: .utf8), "hello roundtrip")
        XCTAssertFalse(resolution.isStale, "freshly-created bookmark must not be stale")
    }
    func testEmptyPasteboardYieldsNoItems() {
        let pb = makeIsolatedPasteboard()
        let items = DragItemFactory.makeItems(from: pb)
        XCTAssertEqual(items.count, 0)
    }
    func testSwiftUIDropFileURLPrecedenceOverString() async throws {
        let file = try makeTempFile(name: "provider-precedence.txt")
        let fileProvider = NSItemProvider(object: file as NSURL)
        let textProvider = NSItemProvider(object: "not the right item" as NSString)

        let items = await DragItemFactory.makeItems(from: [textProvider, fileProvider])

        XCTAssertEqual(items.count, 1)
        guard case let .fileBookmark(record) = items[0].kind else {
            return XCTFail("expected .fileBookmark, got \(items[0].kind)")
        }
        XCTAssertEqual(record.originalPath, file.path)
    }
    func testSwiftUIDropWebURLProducesWebURLItem() async throws {
        let url = URL(string: "https://example.com/swiftui-drop")!
        let provider = NSItemProvider(object: url as NSURL)

        let items = await DragItemFactory.makeItems(from: [provider])

        XCTAssertEqual(items.count, 1)
        guard case let .webURL(itemURL) = items[0].kind else {
            return XCTFail("expected .webURL, got \(items[0].kind)")
        }
        XCTAssertEqual(itemURL, url)
        XCTAssertEqual(items[0].displayName, "example.com")
    }
    func testSwiftUIDropPlainStringProducesTextItem() async throws {
        let payload = "  hello provider shelf  "
        let provider = NSItemProvider(object: payload as NSString)

        let items = await DragItemFactory.makeItems(from: [provider])

        XCTAssertEqual(items.count, 1)
        guard case let .text(text) = items[0].kind else {
            return XCTFail("expected .text, got \(items[0].kind)")
        }
        XCTAssertEqual(text, payload)
        XCTAssertEqual(items[0].displayName, "hello provider shelf")
    }
    func testSwiftUIDropImageDataProducesClipboardImageItem() async throws {
        let data = try makePNGData()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }

        let items = await DragItemFactory.makeItems(from: [provider])

        XCTAssertEqual(items.count, 1)
        guard case .clipboardImage = items[0].kind else {
            return XCTFail("expected .clipboardImage, got \(items[0].kind)")
        }
    }
    func testSwiftUIDropUnsupportedProviderYieldsNoItems() async {
        let items = await DragItemFactory.makeItems(from: [NSItemProvider()])
        XCTAssertEqual(items.count, 0)
    }
    func testMailtoURLAloneYieldsNoWebURLItem() {
        let pb = makeIsolatedPasteboard()
        guard let mailto = URL(string: "mailto:test@example.com") else {
            return XCTFail("could not construct mailto URL")
        }
        pb.writeObjects([mailto as NSURL])

        let items = DragItemFactory.makeItems(from: pb)
        for item in items {
            if case .webURL = item.kind {
                XCTFail("mailto must not produce a .webURL item")
            }
        }
    }
}
