import AppKit
import CoreGraphics
import Foundation

@MainActor
public enum PanelPositioner {
    public static let edgeMargin: CGFloat = 8

    public static let defaultPanelSize = CGSize(width: 180, height: 180)

    public static let cascadeOffsetPx: CGFloat = 30

    public struct Screen: Equatable {
        public let frame: CGRect
        public let visibleFrame: CGRect

        public init(frame: CGRect, visibleFrame: CGRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }

        public init(_ ns: NSScreen) {
            self.init(frame: ns.frame, visibleFrame: ns.visibleFrame)
        }
    }

    public static func computeOrigin(
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

    public static func cascadeOrigin(
        baseOrigin: CGPoint,
        existingCount: Int,
        offsetPerPanel: CGFloat = cascadeOffsetPx
    ) -> CGPoint {
        let n = existingCount % 8
        return CGPoint(
            x: baseOrigin.x + offsetPerPanel * CGFloat(n),
            y: baseOrigin.y - offsetPerPanel * CGFloat(n)
        )
    }

    public static func clamp(
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

    public static func containingScreen(of point: CGPoint, screens: [Screen]) -> Screen? {
        screens.first { $0.frame.contains(point) }
    }

    public static func liveScreens() -> [Screen] {
        NSScreen.screens.map(Screen.init)
    }

    public static func liveCursor() -> CGPoint {
        NSEvent.mouseLocation
    }
}
