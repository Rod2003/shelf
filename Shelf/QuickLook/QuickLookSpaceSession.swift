import AppKit

enum SpaceKey {
    static let keyCode: UInt16 = 49

    static func isUnmodifiedSpace(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let blocking: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        return event.modifierFlags.isDisjoint(with: blocking)
    }
}

struct QuickLookSpaceSession {
    static let holdToDismissThreshold: TimeInterval = 0.4

    enum KeyDownAction: Equatable {
        case ignore
        case toggle
    }

    enum KeyUpAction: Equatable {
        case ignore
        case dismissPeek
    }

    private var spaceIsDown = false
    private var openedOnCurrentPress = false
    private var downTimestamp: TimeInterval?

    mutating func handleKeyDown(isRepeat: Bool, at time: TimeInterval) -> KeyDownAction {
        if isRepeat || spaceIsDown {
            return .ignore
        }
        spaceIsDown = true
        openedOnCurrentPress = false
        downTimestamp = time
        return .toggle
    }

    mutating func markOpenedQuickLook() {
        openedOnCurrentPress = true
    }

    mutating func handleKeyUp(at time: TimeInterval) -> KeyUpAction {
        let shouldDismissPeek = spaceIsDown
            && openedOnCurrentPress
            && holdDuration(at: time) >= Self.holdToDismissThreshold
        spaceIsDown = false
        openedOnCurrentPress = false
        downTimestamp = nil
        return shouldDismissPeek ? .dismissPeek : .ignore
    }

    private func holdDuration(at time: TimeInterval) -> TimeInterval {
        guard let downTimestamp else { return 0 }
        return time - downTimestamp
    }
}
