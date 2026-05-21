import SwiftUI
import ShelfCore
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
    private var backgroundFill: Color {
        if isSelected { return Color.accentColor.opacity(0.3) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }
    private var helpText: String {
        if isMissing { return "\(item.displayName) — file no longer available" }
        return item.displayName
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
            resolver.release(resolution.url)
            thumbnail = image
        } catch {
            isMissing = true
        }
    }
}
