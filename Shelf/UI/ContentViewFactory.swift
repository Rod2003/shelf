import AppKit
import SwiftUI
import ShelfCore

@MainActor
public enum ContentViewFactory {
    public static func makeContentView(
        viewModel: ShelfViewModel,
        resolver: BookmarkResolver? = nil,
        thumbnailService: ThumbnailService? = nil,
        onSingleDragEnded: ((DragOutResult) -> Void)? = nil,
        onMultiDragEnded: ((MultiDragOutResult) -> Void)? = nil,
        onDeleteItems: ((Set<ItemID>) -> Void)? = nil,
        onDropItems: (([ShelfItem]) -> Void)? = nil,
        onCollapseRequested: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) -> NSView {
        let hosting = NSHostingView(
            rootView: ShelfContentView(
                viewModel: viewModel,
                resolver: resolver,
                thumbnailService: thumbnailService,
                onSingleDragEnded: onSingleDragEnded,
                onMultiDragEnded: onMultiDragEnded,
                onDeleteItems: onDeleteItems,
                onDropItems: onDropItems,
                onCollapseRequested: onCollapseRequested,
                onClose: onClose
            )
        )
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        return hosting
    }
}
