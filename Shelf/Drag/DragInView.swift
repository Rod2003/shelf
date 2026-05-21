import AppKit
import OSLog
import ShelfCore

@MainActor
public final class DragInView: NSView {
    private let log = Logger(subsystem: "dev.rod.shelf", category: "drag")

    public var onDrop: (([ShelfItem]) -> Void)?

    public static let acceptedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        .png,
        .tiff,
        .fileContents,
        NSPasteboard.PasteboardType("public.image"),
        .string
    ]

    private var isHighlighted = false {
        didSet {
            guard oldValue != isHighlighted else { return }
            updateBorderHighlight(animated: true)
        }
    }

    private let borderLayer = CAShapeLayer()

    private static let borderInset: CGFloat = 0
    private static let borderLineWidth: CGFloat = 4
    private static let borderCornerRadius: CGFloat = 22
    private static let highlightFadeDuration: CFTimeInterval = 0.2

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.acceptedTypes)
        wantsLayer = true
        configureBorderLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported; DragInView is constructed programmatically")
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasAcceptableContent(in: sender.draggingPasteboard) else {
            log.debug("draggingEntered: no acceptable content; rejecting")
            return []
        }
        isHighlighted = true
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        isHighlighted = false
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasAcceptableContent(in: sender.draggingPasteboard)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { isHighlighted = false }
        let items = DragItemFactory.makeItems(from: sender.draggingPasteboard)
        guard !items.isEmpty else {
            log.warning("performDragOperation: pasteboard advertised acceptable types but no items extracted")
            return false
        }
        log.info("performDragOperation: extracted \(items.count, privacy: .public) items")
        onDrop?(items)
        return true
    }

    public override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        isHighlighted = false
    }

    private func configureBorderLayer() {
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.controlAccentColor.cgColor
        borderLayer.lineWidth = Self.borderLineWidth
        borderLayer.lineJoin = .round
        borderLayer.opacity = 0
        layer?.addSublayer(borderLayer)
    }

    public override func layout() {
        super.layout()
        let inset = bounds.insetBy(dx: Self.borderInset, dy: Self.borderInset)
        borderLayer.frame = bounds
        borderLayer.path = CGPath(
            roundedRect: inset,
            cornerWidth: Self.borderCornerRadius,
            cornerHeight: Self.borderCornerRadius,
            transform: nil
        )
    }

    private func updateBorderHighlight(animated: Bool) {
        let target: Float = isHighlighted ? 1.0 : 0.0
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Self.highlightFadeDuration)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeOut)
            )
            borderLayer.opacity = target
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            borderLayer.opacity = target
            CATransaction.commit()
        }
    }

    private func hasAcceptableContent(in pasteboard: NSPasteboard) -> Bool {
        let advertised = pasteboard.types ?? []
        for type in Self.acceptedTypes {
            if advertised.contains(type) {
                return true
            }
            if pasteboard.canReadItem(withDataConformingToTypes: [type.rawValue]) {
                return true
            }
        }
        return false
    }
}
