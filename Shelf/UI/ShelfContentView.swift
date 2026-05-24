import SwiftUI
import ShelfCore

public struct ShelfContentView: View {
    private static let collapsedPanelSize = CGSize(width: 180, height: 180)
    private static let expandedPanelSize = CGSize(width: 280, height: 280)

    @ObservedObject var viewModel: ShelfViewModel
    let resolver: BookmarkResolver?
    let thumbnailService: ThumbnailService?
    let onSingleDragEnded: ((DragOutResult) -> Void)?
    let onMultiDragEnded: ((MultiDragOutResult) -> Void)?
    let onDeleteItems: ((Set<ItemID>) -> Void)?
    let onDropItems: (([ShelfItem]) -> Void)?
    let onCollapseRequested: (() -> Void)?
    let onClose: (() -> Void)?

    @State private var isCloseHovering: Bool = false
    @State private var isCollapseHovering: Bool = false
    @State private var keepsCollapseButtonMounted: Bool = false
    @Namespace private var morphNamespace
    @Namespace private var glassNamespace

    public init(
        viewModel: ShelfViewModel,
        resolver: BookmarkResolver? = nil,
        thumbnailService: ThumbnailService? = nil,
        onSingleDragEnded: ((DragOutResult) -> Void)? = nil,
        onMultiDragEnded: ((MultiDragOutResult) -> Void)? = nil,
        onDeleteItems: ((Set<ItemID>) -> Void)? = nil,
        onDropItems: (([ShelfItem]) -> Void)? = nil,
        onCollapseRequested: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.resolver = resolver
        self.thumbnailService = thumbnailService
        self.onSingleDragEnded = onSingleDragEnded
        self.onMultiDragEnded = onMultiDragEnded
        self.onDeleteItems = onDeleteItems
        self.onDropItems = onDropItems
        self.onCollapseRequested = onCollapseRequested
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            panelInteractionSurface
                .zIndex(0)
            panelGlassLayer
                .zIndex(0.1)
            content
                .zIndex(1)
            dragRegions
                .zIndex(1.5)
            ShelfPanelBorder(isDropTargeted: viewModel.isDropTargeted)
                .zIndex(2)
        }
        .frame(
            minWidth: viewModel.isExpanded ? Self.expandedPanelSize.width : Self.collapsedPanelSize.width,
            minHeight: viewModel.isExpanded ? Self.expandedPanelSize.height : Self.collapsedPanelSize.height
        )
        .contentShape(Rectangle())
        .clipShape(RoundedRectangle(cornerRadius: ShelfGlass.panelCornerRadius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            ShelfGlassContainer(spacing: 40) {
                closeButton
            }
            .padding(6)
        }
        .overlay(alignment: .topLeading) {
            ShelfGlassContainer(spacing: 40) {
                if keepsCollapseButtonMounted {
                    collapseButton
                        .opacity(viewModel.isExpanded ? 1 : 0)
                        .allowsHitTesting(viewModel.isExpanded)
                        .animation(.easeOut(duration: 0.08), value: viewModel.isExpanded)
                }
            }
            .padding(6)
        }
        .onDrop(
            of: DragItemFactory.acceptedContentTypes,
            isTargeted: Binding(
                get: { viewModel.isDropTargeted },
                set: { viewModel.setDropTargeted($0) }
            ),
            perform: handleDrop(providers:)
        )
        .onAppear {
            keepsCollapseButtonMounted = viewModel.isExpanded
        }
        .onChange(of: viewModel.isExpanded) { _, expanded in
            if expanded {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 90_000_000)
                    if viewModel.isExpanded {
                        keepsCollapseButtonMounted = true
                    }
                }
            } else {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 45_000_000)
                    if !viewModel.isExpanded {
                        keepsCollapseButtonMounted = false
                    }
                }
            }
        }
    }

    private var panelInteractionSurface: some View {
        Color.white.opacity(0.001)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panelGlassLayer: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(
                ShelfGlassPanelBackground(
                    isDropTargeted: viewModel.isDropTargeted
                )
            )
            .allowsHitTesting(false)
    }

    private var dragRegions: some View {
        ZStack {
            VStack(spacing: 0) {
                WindowDragHandle()
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                Spacer(minLength: 0)
            }
            if !viewModel.isExpanded {
                HStack(spacing: 0) {
                    WindowDragHandle()
                        .frame(width: 24)
                        .frame(maxHeight: .infinity)
                    Spacer(minLength: 0)
                    WindowDragHandle()
                        .frame(width: 24)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            let items = await DragItemFactory.makeItems(from: providers)
            if !items.isEmpty {
                onDropItems?(items)
            }
            viewModel.setDropTargeted(false)
        }
        return true
    }

    private var content: some View {
        Group {
            if viewModel.items.isEmpty {
                emptyState
            } else if viewModel.isExpanded {
                expandedContent
                    .transition(.shelfBlurFade)
            } else {
                StackedShelfView(
                    viewModel: viewModel,
                    resolver: resolver,
                    namespace: morphNamespace,
                    glassNamespace: glassNamespace,
                    onSingleDragEnded: onSingleDragEnded,
                    onMultiDragEnded: onMultiDragEnded
                )
                .transition(.shelfBlurFade)
            }
        }
    }

    private var closeButton: some View {
        Button(action: { onClose?() }) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isCloseHovering ? .primary : .secondary)
                .frame(width: 30, height: 30)
                .modifier(ShelfGlassCircleBackground(id: "close", namespace: glassNamespace))
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
                .modifier(ShelfGlassCircleBackground(id: "collapse", namespace: glassNamespace))
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
    private static let stackDragOutSize = CGSize(width: 116, height: 116)

    @ObservedObject var viewModel: ShelfViewModel
    let resolver: BookmarkResolver?
    let namespace: Namespace.ID
    let glassNamespace: Namespace.ID
    let onSingleDragEnded: ((DragOutResult) -> Void)?
    let onMultiDragEnded: ((MultiDragOutResult) -> Void)?

    private var pillLabel: String {
        if viewModel.items.count == 1 { return viewModel.items[0].displayName }
        return "\(viewModel.items.count) attachments"
    }

    var body: some View {
        ShelfGlassContainer(spacing: 40) {
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
                            namespace: namespace,
                            glassNamespace: glassNamespace
                        )
                    }
                    .frame(
                        width: Self.stackDragOutSize.width,
                        height: Self.stackDragOutSize.height,
                        alignment: .center
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                if viewModel.showsCollapsedPill {
                    ShelfPill(
                        label: pillLabel,
                        fitsToContent: viewModel.items.count > 1,
                        glassNamespace: glassNamespace,
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
}

private struct StackCardsView: View {
    private static let glassCardSize = CGSize(width: 94, height: 94)
    private static let layerStyles: [(rotation: Double, offset: CGSize)] = [
        (0, .zero),
        (-5, CGSize(width: -2, height: 2)),
        (5, CGSize(width: 4, height: 4)),
    ]

    let items: [ShelfItem]
    let resolver: BookmarkResolver?
    let namespace: Namespace.ID
    let glassNamespace: Namespace.ID

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
                    resolver: resolver,
                    rotation: layer.rotation,
                    offset: layer.offset
                )
            }
            ForEach(Array(items.dropFirst(3)), id: \.id) { item in
                Color.clear
                    .frame(width: Self.glassCardSize.width, height: Self.glassCardSize.height)
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
    let rotation: Double
    let offset: CGSize
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
        .rotationEffect(.degrees(rotation))
        .offset(offset)
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
    let fitsToContent: Bool
    let glassNamespace: Namespace.ID
    let onToggle: () -> Void
    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                pillLabel
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .frame(maxWidth: fitsToContent ? nil : .infinity)
            .padding(.horizontal, fitsToContent ? 14 : 10)
            .padding(.vertical, 6)
            .foregroundStyle(isHovering ? .primary : .secondary)
            .modifier(ShelfGlassPillBackground(id: "attachments-pill", namespace: glassNamespace))
            .contentShape(Capsule())
        }
        .frame(maxWidth: fitsToContent ? nil : .infinity)
        .fixedSize(horizontal: fitsToContent, vertical: false)
        .buttonStyle(.plain)
        .help(label)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: label)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: fitsToContent)
    }

    @ViewBuilder
    private var pillLabel: some View {
        if fitsToContent {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentTransition(.opacity)
        } else {
            MarqueeText(label)
                .frame(maxWidth: .infinity)
        }
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
                    ShelfItemView(
                        item: item,
                        isSelected: viewModel.drawerSelection.contains(item.id),
                        resolver: resolver,
                        thumbnailService: thumbnailService,
                        showsDisplayName: !viewModel.hidesDrawerLabels
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
                    .overlay {
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
                            Color.clear
                                .contentShape(Rectangle())
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
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

private struct ShelfBlurFadeTransitionModifier: ViewModifier {
    let opacity: Double
    let blurRadius: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .blur(radius: blurRadius)
            .scaleEffect(scale)
    }
}

private extension AnyTransition {
    static var shelfBlurFade: AnyTransition {
        .modifier(
            active: ShelfBlurFadeTransitionModifier(
                opacity: 0,
                blurRadius: 10,
                scale: 0.985
            ),
            identity: ShelfBlurFadeTransitionModifier(
                opacity: 1,
                blurRadius: 0,
                scale: 1
            )
        )
    }
}
