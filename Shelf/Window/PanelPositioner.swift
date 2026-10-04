import AppKit

@MainActor
enum PanelPositioner {
    static let edgeMargin: CGFloat = 8

    static let collapsedPanelSize = CGSize(width: 180, height: 180)
    static let expandedPanelSize = CGSize(width: 280, height: 280)
    static let expansionDuration: TimeInterval = 0.32
    static let defaultPanelSize = collapsedPanelSize

    struct Screen: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect

        init(frame: CGRect, visibleFrame: CGRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }

        init(_ ns: NSScreen) {
            self.init(frame: ns.frame, visibleFrame: ns.visibleFrame)
        }
    }

    static func computeOrigin(
        forCursor cursor: CGPoint,
        panelSize: CGSize = defaultPanelSize,
        edgeMargin: CGFloat = edgeMargin,
        screens: [Screen]
    ) -> CGPoint {
        let resolvedScreen = containingScreen(of: cursor, screens: screens) ?? screens.first
        guard let screen = resolvedScreen else {
            return cursor
        }
        let desiredX = cursor.x - 30
        let desiredY = cursor.y - panelSize.height + 30
        return clamp(
            origin: CGPoint(x: desiredX, y: desiredY),
            panelSize: panelSize,
            in: screen.visibleFrame,
            edgeMargin: edgeMargin
        )
    }

    static func clamp(
        origin: CGPoint,
        panelSize: CGSize,
        in visibleFrame: CGRect,
        edgeMargin: CGFloat = edgeMargin
    ) -> CGPoint {
        let minX = visibleFrame.minX + edgeMargin
        let minY = visibleFrame.minY + edgeMargin
        let maxX = visibleFrame.maxX - edgeMargin - panelSize.width
        let maxY = visibleFrame.maxY - edgeMargin - panelSize.height
        let x = max(minX, min(origin.x, maxX))
        let y = max(minY, min(origin.y, maxY))
        return CGPoint(x: x, y: y)
    }

    static func containingScreen(of point: CGPoint, screens: [Screen]) -> Screen? {
        screens.first { $0.frame.contains(point) }
    }

    static func liveScreens() -> [Screen] {
        NSScreen.screens.map(Screen.init)
    }

    static func liveCursor() -> CGPoint {
        NSEvent.mouseLocation
    }
}
