// Drag-IN destination view.
//
// `DragInView` is a thin `NSView` subclass that registers as an
// `NSDraggingDestination` for the multi-type pasteboard drops a Shelf accepts:
// file URLs, web URLs, image data, and plain text. It is intentionally
// presentation-agnostic: it does not own a `ShelfStore`, does not know about
// `Shelf` identity, and does not push items anywhere itself. Successful drops
// are converted by `DragItemFactory` into `[ShelfItem]` and delivered via the
// `onDrop` closure the integrating coordinator sets at composition time.

import AppKit
import OSLog
import ShelfCore

/// `NSView` that registers for the multi-type drop pasteboard Shelf supports
/// and converts incoming drops to `[ShelfItem]` via `DragItemFactory`.
///
/// The view exposes a single output: `onDrop`, a closure invoked with the
/// extracted items on a successful `performDragOperation`. The view does not
/// retain any reference to a `ShelfStore`; persisting items is the
/// integrator's responsibility.
@MainActor
public final class DragInView: NSView {
    private let log = Logger(subsystem: "dev.rod.shelf", category: "drag")

    /// Callback invoked with the items derived from a successful drop.
    /// Set by the integrating coordinator. If left `nil`, drops are
    /// still accepted at the AppKit layer (we return `true` from
    /// `performDragOperation`) but the items are silently dropped — that is
    /// useful behavior for tests and previews; production wires this up.
    public var onDrop: (([ShelfItem]) -> Void)?

    /// All pasteboard types we accept. Order roughly matches precedence in
    /// `DragItemFactory.makeItems(from:)` — file URLs first, then web URLs,
    /// then image data, then plain text. The `public.image` UTI string is
    /// included explicitly because some apps (notably web browsers dragging
    /// inline images) advertise it without ever providing `.png` or `.tiff`.
    public static let acceptedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        .png,
        .tiff,
        .fileContents,
        NSPasteboard.PasteboardType("public.image"),
        .string
    ]

    /// Drop highlight overlay state. Set on `draggingEntered`, cleared on
    /// `draggingExited` / `concludeDragOperation`. Drives the
    /// `borderLayer.opacity` through a `CATransaction` so the change fades
    /// rather than snaps.
    private var isHighlighted = false {
        didSet {
            guard oldValue != isHighlighted else { return }
            updateBorderHighlight(animated: true)
        }
    }

    /// Inset rounded-rect stroke that fades in while a drag hovers over the
    /// shelf. Layer-backed (rather than `draw(_:)`-based) so the appearance
    /// can animate via implicit Core Animation.
    private let borderLayer = CAShapeLayer()

    /// Visual tuning for the highlight overlay. Inset is 0 so the stroke
    /// hugs the panel edge; corner radius matches the wrapper's clip
    /// radius (set in `ContentViewFactory`) so the border traces the
    /// rounded corner cleanly.
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

    // MARK: NSDraggingDestination

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

    // MARK: Highlight rendering (CAShapeLayer + implicit animation)

    /// One-time setup of the border layer. Path is sized in `layout()` so it
    /// tracks panel resize.
    private func configureBorderLayer() {
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.controlAccentColor.cgColor
        borderLayer.lineWidth = Self.borderLineWidth
        borderLayer.lineJoin = .round
        borderLayer.opacity = 0  // hidden by default; fades in on highlight
        layer?.addSublayer(borderLayer)
    }

    public override func layout() {
        super.layout()
        let inset = bounds.insetBy(dx: Self.borderInset, dy: Self.borderInset)
        // Build the path in the layer's coordinate space (== view bounds).
        borderLayer.frame = bounds
        borderLayer.path = CGPath(
            roundedRect: inset,
            cornerWidth: Self.borderCornerRadius,
            cornerHeight: Self.borderCornerRadius,
            transform: nil
        )
    }

    /// Animate `borderLayer.opacity` toward its target via a CATransaction
    /// with a fixed duration. Calling this with `animated: false` snaps —
    /// useful if a future caller wants an immediate state set.
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

    // MARK: Helpers

    /// Return `true` if the pasteboard advertises ANY of the types we accept.
    /// Uses both `canReadItem(withDataConformingToTypes:)` (the modern, UTI-aware
    /// API) and a direct `types?.contains(...)` check as a belt-and-braces
    /// fallback for sources that publish raw pasteboard types without UTI
    /// conformance metadata.
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
