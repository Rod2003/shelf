// Shelf — top-level SwiftUI content for one shelf panel.
//
// Layout (post header-removal + drag-handle + close-button additions):
//   ┌──────────────────────────────────┐
//   │  [drag region]               [×] │  invisible 28pt drag strip
//   │                                  │
//   │   [ ] [ ] [ ] [ ] [ ]            │  grid (or empty state)
//   │                                  │
//   └──────────────────────────────────┘
//
// Drag-IN registration lives on the AppKit wrapper NSView produced by
// ContentViewFactory (T13's responsibility). Drag-OUT lives on the cell
// (T14). This view is presentation-only.
//
// T19 extends this presentation layer with two opt-in seams:
//   • `resolver` + `thumbnailService` are forwarded to each `ShelfItemView`
//     so file items render real Quick Look thumbnails and can flag
//     missing bookmarks.
//   • Tap selection updates `viewModel.selectedItemID`, which the App
//     Coordinator (T18) reads to drive `QuickLookCoordinator`.
import SwiftUI
import ShelfCore

/// Root SwiftUI content for one shelf. Driven by a `ShelfViewModel`.
public struct ShelfContentView: View {
    @ObservedObject var viewModel: ShelfViewModel
    let resolver: BookmarkResolver?
    let thumbnailService: ThumbnailService?
    let onDragEnded: ((DragOutResult) -> Void)?
    let onClose: (() -> Void)?

    @State private var isCloseHovering: Bool = false

    public init(
        viewModel: ShelfViewModel,
        resolver: BookmarkResolver? = nil,
        thumbnailService: ThumbnailService? = nil,
        onDragEnded: ((DragOutResult) -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.resolver = resolver
        self.thumbnailService = thumbnailService
        self.onDragEnded = onDragEnded
        self.onClose = onClose
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            // Content. Empty state fills the whole panel so its icon + text
            // are vertically centered within the visible bounds. The grid
            // gets a 24pt top inset so cells don't slide under the close
            // button; that inset only applies when there's actually a grid
            // to show (no dead space when the shelf is empty).
            if viewModel.items.isEmpty {
                emptyState
            } else {
                grid
                    .padding(.top, 36)  // clears 6pt + 30pt close button
            }

            // Close button anchored in the top-right corner with a small
            // breathing inset so it sits inside the panel's rounded edge
            // rather than tangent to it.
            closeButton
                .padding(.top, 6)
                .padding(.trailing, 6)
        }
        .frame(minWidth: 180, minHeight: 180)
    }

    // MARK: Close button

    private var closeButton: some View {
        Button(action: { onClose?() }) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isCloseHovering ? .primary : .secondary)
                .frame(width: 30, height: 30)
                .modifier(GlassCircleBackground())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close Shelf")  // i18n: "Close Shelf"
        .onHover { hovering in
            isCloseHovering = hovering
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop files here")  // i18n: "Drop files here"
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 8)],
                spacing: 8
            ) {
                ForEach(viewModel.items, id: \.id) { item in
                    DragOutCellWrapper(
                        item: item,
                        onTap: {
                            viewModel.selectedItemID = item.id
                        },
                        onDragEnded: { result in
                            onDragEnded?(result)
                        }
                    ) {
                        ShelfItemView(
                            item: item,
                            isSelected: viewModel.selectedItemID == item.id,
                            resolver: resolver,
                            thumbnailService: thumbnailService
                        )
                    }
                }
            }
            .padding(8)
        }
    }
}

/// Liquid Glass capsule background for the shelf's close button.
///
/// On macOS 26 Tahoe we use the native `.glassEffect()` API with a slight
/// adaptive tint plus a hairline stroke. The default `Glass.regular` reads
/// almost invisibly when stacked on top of the panel's own HUD-glass
/// background; the small `.primary`-opacity tint and the rim stroke give
/// the button enough density to register as a distinct element while
/// keeping the Liquid Glass refraction.
///
/// On older systems we fall back to `.regularMaterial`, which auto-renders
/// as Liquid Glass on macOS 26 anyway but doesn't give us access to the
/// `Glass` configurator (tint, interactive variant, etc.).
private struct GlassCircleBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    .regular
                        .interactive()
                        .tint(.primary.opacity(0.08)),
                    in: .circle
                )
                .overlay(
                    Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                )
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .overlay(
                    Circle().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
                )
        }
    }
}
