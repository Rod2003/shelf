// Shelf — single-cell view for one ShelfItem inside the shelf grid.
//
// Renders a real Quick Look thumbnail for `fileBookmark` items via the
// injected `ThumbnailService`, falling back to an SF Symbol placeholder
// while the async load completes (or for non-file kinds). When a
// bookmark fails to resolve (file moved/deleted), an orange ⚠️ overlay
// is composited over a dimmed thumbnail and the help/tooltip text is
// updated accordingly.
//
// Drag-out is NOT handled here — see `DragOutCellWrapper`. This view is
// presentation-only. Cells get tap-to-select via `DragOutCellWrapper`'s
// `onTap` callback (the wrapper's `mouseDown` consumes events before
// SwiftUI's gesture system can fire `.onTapGesture`).
import SwiftUI
import ShelfCore

/// One cell in the shelf grid. Drives an async thumbnail load and
/// reflects bookmark resolution failure as a missing-file affordance.
public struct ShelfItemView: View {
    public let item: ShelfItem
    public let isSelected: Bool
    public let resolver: BookmarkResolver?
    public let thumbnailService: ThumbnailService?

    @State private var thumbnail: NSImage?
    @State private var isMissing: Bool = false
    @State private var isHovering: Bool = false

    public init(
        item: ShelfItem,
        isSelected: Bool = false,
        resolver: BookmarkResolver? = nil,
        thumbnailService: ThumbnailService? = nil
    ) {
        self.item = item
        self.isSelected = isSelected
        self.resolver = resolver
        self.thumbnailService = thumbnailService
    }

    public var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                thumbnailView
                    .frame(width: 64, height: 64)
                if isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .background(Circle().fill(.background))
                        .help("File no longer available")
                }
            }
            Text(item.displayName)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .frame(width: 96)
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backgroundFill)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .help(helpText)
        .task(id: item.id) {
            await loadThumbnailIfNeeded()
        }
    }

    /// Background fill driven by selection (highest priority) then hover.
    /// Selection uses the system accent so the cell tracks the user's
    /// configured tint without us hardcoding a color.
    private var backgroundFill: Color {
        if isSelected { return Color.accentColor.opacity(0.3) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    /// Help/tooltip text — adds a "file no longer available" suffix when
    /// the underlying bookmark could not be resolved.
    private var helpText: String {
        if isMissing { return "\(item.displayName) — file no longer available" }
        return item.displayName
    }

    /// Thumbnail content — dims when the bookmark is missing so the
    /// overlaid ⚠️ badge has visual weight.
    @ViewBuilder
    private var thumbnailView: some View {
        if let img = thumbnail {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .opacity(isMissing ? 0.5 : 1.0)
        } else {
            placeholderSymbol
        }
    }

    /// Placeholder thumbnail keyed off `ShelfItemKind`. Stays as the
    /// rendered representation for `webURL` / `text` items (no file URL
    /// to ask QL about) and as the transient pre-load representation for
    /// `fileBookmark` / `clipboardImage` items.
    @ViewBuilder
    private var placeholderSymbol: some View {
        switch item.kind {
        case .fileBookmark, .clipboardImage:
            Image(systemName: "doc.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
        case .webURL:
            Image(systemName: "link")
                .font(.system(size: 36))
                .foregroundStyle(.blue)
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
        }
    }

    /// Resolve the underlying bookmark (if any) and ask the thumbnail
    /// service for a representation. Sets `isMissing` on resolution
    /// failure so the ⚠️ overlay activates.
    ///
    /// Non-file kinds short-circuit immediately. So do calls when either
    /// the resolver or thumbnail service is unset (preview/test mode).
    private func loadThumbnailIfNeeded() async {
        guard
            case .fileBookmark(let record) = item.kind,
            let resolver = resolver,
            let service = thumbnailService
        else {
            return
        }
        do {
            let resolution = try resolver.resolve(record)
            let image = await service.thumbnail(for: resolution.url)
            // Pair the implicit start-access from `resolve(_:)`. Done as
            // soon as QL has rendered; we do not hold the scope while
            // SwiftUI displays the cached NSImage.
            resolver.release(resolution.url)
            thumbnail = image
        } catch {
            isMissing = true
        }
    }
}
