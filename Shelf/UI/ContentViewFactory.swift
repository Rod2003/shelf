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
                onCollapseRequested: onCollapseRequested,
                onClose: onClose
            )
        )
        hosting.autoresizingMask = [.width, .height]

        let wrapper = NSVisualEffectView()
        wrapper.material = .hudWindow
        wrapper.blendingMode = .behindWindow
        wrapper.state = .active
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = 22
        wrapper.layer?.masksToBounds = true
        wrapper.translatesAutoresizingMaskIntoConstraints = true
        wrapper.autoresizingMask = [.width, .height]
        wrapper.addSubview(hosting)
        hosting.frame = wrapper.bounds
        return wrapper
    }
}
