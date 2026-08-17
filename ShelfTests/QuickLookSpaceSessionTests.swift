import XCTest

@testable import Shelf

final class QuickLookSpaceSessionTests: XCTestCase {
    func testFirstKeyDownTogglesAndRepeatsAreIgnored() {
        var session = QuickLookSpaceSession()

        XCTAssertEqual(session.handleKeyDown(isRepeat: false, at: 0), .toggle)
        XCTAssertEqual(session.handleKeyDown(isRepeat: true, at: 0.05), .ignore)
        XCTAssertEqual(session.handleKeyDown(isRepeat: false, at: 0.1), .ignore)
    }

    func testKeyUpAfterShortPressKeepsPinnedPreview() {
        var session = QuickLookSpaceSession()

        XCTAssertEqual(session.handleKeyDown(isRepeat: false, at: 0), .toggle)
        session.markOpenedQuickLook()

        XCTAssertEqual(
            session.handleKeyUp(at: QuickLookSpaceSession.holdToDismissThreshold - 0.05),
            .ignore
        )
    }

    func testKeyUpAfterHeldPressDismissesPeek() {
        var session = QuickLookSpaceSession()

        XCTAssertEqual(session.handleKeyDown(isRepeat: false, at: 0), .toggle)
        session.markOpenedQuickLook()

        XCTAssertEqual(
            session.handleKeyUp(at: QuickLookSpaceSession.holdToDismissThreshold),
            .dismissPeek
        )
    }

    func testClosingPressDoesNotDismissOnKeyUp() {
        var session = QuickLookSpaceSession()

        XCTAssertEqual(session.handleKeyDown(isRepeat: false, at: 0), .toggle)
        XCTAssertEqual(
            session.handleKeyUp(at: QuickLookSpaceSession.holdToDismissThreshold + 1),
            .ignore
        )
    }

    func testNextPressCanToggleAfterRelease() {
        var session = QuickLookSpaceSession()

        XCTAssertEqual(session.handleKeyDown(isRepeat: false, at: 0), .toggle)
        session.markOpenedQuickLook()
        XCTAssertEqual(session.handleKeyUp(at: 0.1), .ignore)

        XCTAssertEqual(session.handleKeyDown(isRepeat: false, at: 0.2), .toggle)
    }

    func testOrphanKeyUpIsIgnored() {
        var session = QuickLookSpaceSession()

        XCTAssertEqual(session.handleKeyUp(at: 1), .ignore)
    }
}
