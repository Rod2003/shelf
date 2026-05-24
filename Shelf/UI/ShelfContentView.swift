import SwiftUI
import ShelfCore

public struct ShelfContentView: View {
    private static let collapsedPanelSize = CGSize(width: 180, height: 180)
    private static let expandedPanelSize = CGSize(width: 280, height: 360)

    @ObservedObject var viewModel: ShelfViewModel
    let resolver: BookmarkResolver?
    let thumbnailService: ThumbnailService?
    let onSingleDragEnded: ((DragOutResult) -> Void)?
    let onMultiDragEnded: ((MultiDragOutResult) -> Void)?
    let onDeleteItems: ((Set<ItemID>) -> Void)?
    let onCollapseRequested: (() -> Void)?
    let onClose: (() -> Void)?

    @State private var isCloseHovering: Bool = false
    @State private var isCollapseHovering: Bool = false
    @Namespace private var morphNamespace

    public init(
        viewModel: ShelfViewModel,
        resolver: BookmarkResolver? = nil,
        thumbnailService: ThumbnailService? = nil,
        onSingleDragEnded: ((DragOutResult) -> Void)? = nil,
        onMultiDragEnded: ((MultiDragOutResult) -> Void)? = nil,
        onDeleteItems: ((Set<ItemID>) -> Void)? = nil,
        onCollapseRequested: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.resolver = resolver
        self.thumbnailService = thumbnailService
        self.onSingleDragEnded = onSingleDragEnded
        self.onMultiDragEnded = onMultiDragEnded
        self.onDeleteItems = onDeleteItems
        self.onCollapseRequested = onCollapseRequested
        self.onClose = onClose
    }

    public var body: some View {
        Group {
            if viewModel.items.isEmpty {
                emptyState
            } else if viewModel.isExpanded {
                expandedContent
                    .transition(.opacity)
            } else {
                StackedShelfView(
                    viewModel: viewModel,
                    resolver: resolver,
                    namespace: morphNamespace,
                    onSingleDragEnded: onSingleDragEnded,
                    onMultiDragEnded: onMultiDragEnded
                )
                    .transition(.opacity)
            }
        }
        .frame(
            minWidth: viewModel.isExpanded ? Self.expandedPanelSize.width : Self.collapsedPanelSize.width,
            minHeight: viewModel.isExpanded ? Self.expandedPanelSize.height : Self.collapsedPanelSize.height
        )
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(6)
        }
        .overlay(alignment: .topLeading) {
            if viewModel.isExpanded {
                collapseButton
                    .padding(6)
            }
        }
    }

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
        .help("Close Shelf")
        .onHover { hovering in
            isCloseHovering = hovering
        }
    }

    private var collapseButton: some View {
        Button(action: { onCollapseRequested?() }) {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isCollapseHovering ? .primary : .secondary)
                .frame(width: 30, height: 30)
                .modifier(GlassCircleBackground())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Collapse Shelf")
        .onHover { hovering in
            isCollapseHovering = hovering
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop files here")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var expandedContent: some View {
        ShelfDrawerView(
            viewModel: viewModel,
            resolver: resolver,
            thumbnailService: thumbnailService,
            namespace: morphNamespace,
            onSingleDragEnded: onSingleDragEnded,
            onMultiDragEnded: onMultiDragEnded,
            onDeleteItems: onDeleteItems,
            onCollapseRequested: onCollapseRequested
        )
    }
}

private struct StackedShelfView: View {
    private static let pillBottomPadding: CGFloat = 12
    private static let pillHorizontalPadding: CGFloat = 14

    @ObservedObject var viewModel: ShelfViewModel
    let resolver: BookmarkResolver?
    let namespace: Namespace.ID
    let onSingleDragEnded: ((DragOutResult) -> Void)?
    let onMultiDragEnded: ((MultiDragOutResult) -> Void)?

    private var pillLabel: String {
        if viewModel.items.count == 1 { return viewModel.items[0].displayName }
        return "\(viewModel.items.count) attachments"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let top = viewModel.items.first {
                DragOutCellWrapper(
                    item: top,
                    onTapWithModifiers: { _ in },
                    onDragEnded: { onSingleDragEnded?($0) },
                    multiItemsProvider: { viewModel.items },
                    onMultiDragEnded: { onMultiDragEnded?($0) }
                ) {
                    StackCardsView(
                        items: viewModel.items,
                        resolver: resolver,
                        namespace: namespace
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            if viewModel.showsCollapsedPill {
                ShelfPill(
                    label: pillLabel,
                    onToggle: {
                        viewModel.setExpanded(true)
                    }
                )
                .padding(.horizontal, Self.pillHorizontalPadding)
                .padding(.bottom, Self.pillBottomPadding)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StackCardsView: View {
    private static let layerStyles: [(rotation: Double, offset: CGSize)] = [
        (0, .zero),
        (-5, CGSize(width: -2, height: 2)),
        (5, CGSize(width: 4, height: 4)),
    ]

    let items: [ShelfItem]
    let resolver: BookmarkResolver?
    let namespace: Namespace.ID

    private var visibleLayers: [StackLayer] {
        let layers = zip(items.prefix(3), Self.layerStyles).map { item, style in
            StackLayer(item: item, rotation: style.rotation, offset: style.offset)
        }
        return Array(layers.reversed())
    }

    var body: some View {
        ZStack {
            ForEach(visibleLayers) { layer in
                StackThumbnailCard(
                    item: layer.item,
                    resolver: resolver
                )
                .rotationEffect(.degrees(layer.rotation))
                .offset(layer.offset)
                .matchedGeometryEffect(
                    id: layer.item.id,
                    in: namespace,
                    isSource: true
                )
            }
            ForEach(Array(items.dropFirst(3)), id: \.id) { item in
                Color.clear
                    .frame(width: 84, height: 84)
                    .matchedGeometryEffect(
                        id: item.id,
                        in: namespace,
                        isSource: true
                    )
            }
        }
        .frame(width: 96, height: 96)
    }
}

private struct StackLayer: Identifiable {
    let item: ShelfItem
    let rotation: Double
    let offset: CGSize

    var id: ItemID { item.id }
}

private struct StackThumbnailCard: View {
    let item: ShelfItem
    let resolver: BookmarkResolver?
    @State private var thumbnail: NSImage?
    private let maxImageSize = CGSize(width: 84, height: 84)

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
        }
        .frame(width: maxImageSize.width, height: maxImageSize.height)
        .help(item.displayName)
        .task(id: item.id) {
            await loadThumbnailIfNeeded()
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch item.kind {
        case .fileBookmark, .clipboardImage:
            Image(systemName: "doc.fill")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
        case .webURL:
            Image(systemName: "link")
                .font(.system(size: 42))
                .foregroundStyle(.blue)
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
        }
    }

    private func loadThumbnailIfNeeded() async {
        do {
            switch item.kind {
            case .fileBookmark(let record):
                guard let resolver else { return }
                let resolution = try resolver.resolve(record)
                defer { resolver.release(resolution.url) }
                thumbnail = sourceImageIfAvailable(for: resolution.url)
                return
            case .clipboardImage(let filename):
                guard let resolvedURL = clipboardImageURL(filename: filename) else { return }
                thumbnail = sourceImageIfAvailable(for: resolvedURL)
            case .webURL, .text:
                return
            }
        } catch {
            thumbnail = nil
        }
    }

    private func sourceImageIfAvailable(for url: URL) -> NSImage? {
        guard
            let data = try? Data(contentsOf: url),
            let image = NSImage(data: data),
            image.size.width > 0,
            image.size.height > 0
        else {
            return nil
        }
        return image
    }

    private func clipboardImageURL(filename: String) -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let url = appSupport
            .appendingPathComponent("Shelf", isDirectory: true)
            .appendingPathComponent("clipboard-images", isDirectory: true)
            .appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

private struct ShelfPill: View {
    let label: String
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                MarqueeText(label)
                    .frame(maxWidth: .infinity)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.45), lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .help(label)
    }
}

private struct MarqueeText: View {
    private let spacing: CGFloat = 28
    let text: String
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var isAnimating = false

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        GeometryReader { proxy in
            let shouldScroll = textWidth > proxy.size.width
            Group {
                if shouldScroll {
                    HStack(spacing: spacing) {
                        measuredText
                        measuredText
                    }
                    .offset(x: isAnimating ? -(textWidth + spacing) : 0)
                    .animation(
                        .linear(duration: max(4, Double(textWidth + spacing) / 24))
                            .repeatForever(autoreverses: false),
                        value: isAnimating
                    )
                } else {
                    measuredText
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .clipped()
            .onAppear {
                containerWidth = proxy.size.width
                isAnimating = shouldScroll
            }
            .onChange(of: proxy.size.width) { _, width in
                containerWidth = width
                isAnimating = textWidth > width
            }
            .onChange(of: textWidth) { _, width in
                isAnimating = width > containerWidth
            }
        }
        .frame(height: 16)
    }

    private var measuredText: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: MarqueeTextWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(MarqueeTextWidthKey.self) { width in
                textWidth = width
            }
    }
}

private struct MarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ShelfDrawerView: View {
    @ObservedObject var viewModel: ShelfViewModel
    let resolver: BookmarkResolver?
    let thumbnailService: ThumbnailService?
    let namespace: Namespace.ID
    let onSingleDragEnded: ((DragOutResult) -> Void)?
    let onMultiDragEnded: ((MultiDragOutResult) -> Void)?
    let onDeleteItems: ((Set<ItemID>) -> Void)?
    let onCollapseRequested: (() -> Void)?
    @FocusState private var isFocused: Bool

    private let columns = [
        GridItem(.flexible(minimum: 96, maximum: 120), spacing: 8),
        GridItem(.flexible(minimum: 96, maximum: 120), spacing: 8),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(viewModel.items, id: \.id) { item in
                    DragOutCellWrapper(
                        item: item,
                        onTapWithModifiers: { modifiers in
                            handleClick(itemID: item.id, modifiers: modifiers)
                        },
                        onDragEnded: { onSingleDragEnded?($0) },
                        multiItemsProvider: {
                            if viewModel.drawerSelection.contains(item.id) {
                                return viewModel.items.filter { viewModel.drawerSelection.contains($0.id) }
                            }
                            viewModel.selectOnly(item.id)
                            return [item]
                        },
                        onMultiDragEnded: { onMultiDragEnded?($0) }
                    ) {
                        ShelfItemView(
                            item: item,
                            isSelected: viewModel.drawerSelection.contains(item.id),
                            resolver: resolver,
                            thumbnailService: thumbnailService
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    viewModel.drawerActiveSelectionID == item.id
                                        ? Color.accentColor
                                        : Color.accentColor.opacity(0.55),
                                    lineWidth: viewModel.drawerSelection.contains(item.id) ? 2 : 0
                                )
                        )
                    }
                    .matchedGeometryEffect(
                        id: item.id,
                        in: namespace,
                        isSource: false
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 42)
            .padding(.bottom, 12)
        }
        .focusable(true)
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onChange(of: viewModel.isExpanded) { _, expanded in
            isFocused = expanded
        }
        .onKeyPress(.delete) {
            guard !viewModel.drawerSelection.isEmpty else { return .handled }
            let selection = viewModel.drawerSelection
            viewModel.removeAll(itemIDs: selection)
            if viewModel.items.isEmpty {
                viewModel.setExpanded(false)
            }
            onDeleteItems?(selection)
            return .handled
        }
        .onKeyPress(.escape) {
            onCollapseRequested?()
            return .handled
        }
    }

    private func handleClick(itemID: ItemID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift) {
            viewModel.extendSelection(to: itemID)
        } else if modifiers.contains(.command) {
            viewModel.toggle(itemID)
        } else {
            viewModel.selectOnly(itemID)
        }
    }
}

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
