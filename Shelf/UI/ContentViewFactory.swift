// Shelf — AppKit/SwiftUI bridge factory for shelf panel content.
//
// Produces the view hierarchy that `ShelfWindowController` installs as
// `panel.contentView`. The hierarchy is intentionally two-layered:
//
//   wrapper (NSView) ← future home of NSDraggingDestination registration (T13)
//     └── hosting (NSHostingView<ShelfContentView>)  ← SwiftUI content
//
// We keep the wrapper as a plain `NSView` here so that T13 can subclass or
// extend it with `registerForDraggedTypes(_:)` and `draggingEntered/Updated/
// Performed/Exited` overrides without disturbing the SwiftUI hosting view.
// Per Spike B findings (notepad), drag registration MUST live at this AppKit
// seam; attempting it inside the SwiftUI hierarchy is unsupported.
//
// T19 extends `makeContentView` with two optional dependencies that are
// forwarded into `ShelfContentView`:
//   • `resolver` — used by cells to resolve file bookmarks for thumbnails
//     and to detect missing files for the ⚠️ overlay.
//   • `thumbnailService` — actor-isolated QL thumbnail cache.
// Both default to `nil` so existing call sites remain source-compatible
// until T18 wires the real services in.
import AppKit
import SwiftUI
import ShelfCore

/// Namespace for content-view construction helpers.
@MainActor
public enum ContentViewFactory {
    /// Build the AppKit-side view hierarchy for one shelf panel.
    ///
    /// The returned `NSView` is suitable for direct assignment to
    /// `ShelfWindowController.panel.contentView` (or, equivalently, passing
    /// as the `contentView:` argument to its initializer). Layout is via
    /// autoresizing masks: both wrapper and hosting view fill their parent
    /// bounds, so the hierarchy follows panel resizes without explicit
    /// constraints.
    ///
    /// - Parameters:
    ///   - viewModel: the `ShelfViewModel` driving the SwiftUI tree.
    ///   - resolver: optional bookmark resolver forwarded to each cell.
    ///   - thumbnailService: optional thumbnail service forwarded to each cell.
    /// - Returns: a parent `NSView` with an `NSHostingView<ShelfContentView>`
    ///   subview pinned via autoresizing masks. T13 registers drag types on
    ///   this returned view (or a subclass thereof) without touching the
    ///   inner hosting view.
    public static func makeContentView(
        viewModel: ShelfViewModel,
        resolver: BookmarkResolver? = nil,
        thumbnailService: ThumbnailService? = nil,
        onDragEnded: ((DragOutResult) -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) -> NSView {
        let hosting = NSHostingView(
            rootView: ShelfContentView(
                viewModel: viewModel,
                resolver: resolver,
                thumbnailService: thumbnailService,
                onDragEnded: onDragEnded,
                onClose: onClose
            )
        )
        hosting.autoresizingMask = [.width, .height]

        // Liquid Glass wrapper: NSVisualEffectView with HUD material blends
        // with the desktop/window contents behind the panel. On macOS 26
        // (Tahoe) this renders with the new Liquid Glass aesthetic
        // automatically; on older versions it falls back to the classic
        // vibrancy material. The hosting view sits on top.
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
