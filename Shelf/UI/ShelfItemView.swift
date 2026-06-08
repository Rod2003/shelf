import SwiftUI
import ShelfCore
public struct ShelfItemView: View {
    public let item: ShelfItem
    public let isSelected: Bool
    public let resolver: BookmarkResolver?
    public let thumbnailService: ThumbnailService?
    public let thumbnailNamespace: Namespace.ID?
    public let showsDisplayName: Bool

    @State private var thumbnail: NSImage?
    @State private var isMissing: Bool = false
    @State private var isHovering: Bool = false

    public init(
        item: ShelfItem,
        isSelected: Bool = false,
        resolver: BookmarkResolver? = nil,
        thumbnailService: ThumbnailService? = nil,
        thumbnailNamespace: Namespace.ID? = nil,
        showsDisplayName: Bool = true
    ) {
        self.item = item
        self.isSelected = isSelected
        self.resolver = resolver
        self.thumbnailService = thumbnailService
        self.thumbnailNamespace = thumbnailNamespace
        self.showsDisplayName = showsDisplayName
    }

    public var body: some View {
        VStack(spacing: 4) {
            thumbnailContainer
            Text(item.displayName)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .opacity(showsDisplayName ? 1 : 0)
                .animation(nil, value: showsDisplayName)
        }
        .frame(width: 96)
        .padding(4)
        .modifier(ShelfGlassItemBackground(isSelected: isSelected, isHovering: isHovering))
        .onHover { hovering in
            isHovering = hovering
        }
        .help(helpText)
        .task(id: item.id) {
            await loadThumbnailIfNeeded()
        }
    }
    private var helpText: String {
        if isMissing { return "\(item.displayName) — file no longer available" }
        return item.displayName
    }

    @ViewBuilder
    private var thumbnailContainer: some View {
        let content = ZStack(alignment: .topTrailing) {
            thumbnailView
                .frame(width: 64, height: 64)
            if isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .background(Circle().fill(.background))
                    .help("File no longer available")
            }
        }
        .frame(width: 64, height: 64)

        if let thumbnailNamespace {
            content
                .matchedGeometryEffect(
                    id: item.id,
                    in: thumbnailNamespace,
                    isSource: false
                )
        } else {
            content
        }
    }

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
    private func loadThumbnailIfNeeded() async {
        guard let service = thumbnailService else { return }
        switch item.kind {
        case .fileBookmark:
            thumbnail = await service.thumbnail(
                for: item,
                resolver: resolver,
                size: CGSize(width: 64, height: 64)
            )
            if thumbnail == nil {
                isMissing = true
            }

        case .clipboardImage:
            thumbnail = await service.thumbnail(
                for: item,
                resolver: resolver,
                size: CGSize(width: 64, height: 64)
            )
        case .webURL, .text:
            return
        }
    }
}
