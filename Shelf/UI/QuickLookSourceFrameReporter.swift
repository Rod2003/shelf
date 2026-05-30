import AppKit
import ShelfCore
import SwiftUI

extension View {
    func quickLookSourceFrame(
        ids: [ItemID],
        onChange: @escaping ([ItemID], CGRect?) -> Void
    ) -> some View {
        background(
            QuickLookSourceFrameReporter(itemIDs: ids, onChange: onChange)
        )
    }
}

private struct QuickLookSourceFrameReporter: NSViewRepresentable {
    let itemIDs: [ItemID]
    let onChange: ([ItemID], CGRect?) -> Void

    func makeNSView(context: Context) -> QuickLookSourceFrameReportingView {
        let view = QuickLookSourceFrameReportingView()
        view.itemIDs = itemIDs
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: QuickLookSourceFrameReportingView, context: Context) {
        nsView.itemIDs = itemIDs
        nsView.onChange = onChange
        nsView.scheduleReport()
    }

    static func dismantleNSView(_ nsView: QuickLookSourceFrameReportingView, coordinator: ()) {
        // Clear the reported frame, but never synchronously: dismantle runs
        // inside SwiftUI's view-graph teardown (NSHostingView deinit), and
        // mutating the observed view model here re-enters the graph mid-
        // invalidation, tripping Swift's exclusivity enforcement (SIGABRT).
        // Defer to the next main-loop tick so the mutation lands outside
        // teardown. Capture the closure/ids so we don't touch the dismantled
        // view afterwards.
        let onChange = nsView.onChange
        let itemIDs = nsView.itemIDs
        DispatchQueue.main.async {
            onChange?(itemIDs, nil)
        }
    }
}

@MainActor
private final class QuickLookSourceFrameReportingView: NSView {
    var itemIDs: [ItemID] = []
    var onChange: (([ItemID], CGRect?) -> Void)?
    private var lastReportedFrame: CGRect?
    private var reportScheduled = false
    private var observers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
        postsBoundsChangedNotifications = true
        installViewObservers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        postsFrameChangedNotifications = true
        postsBoundsChangedNotifications = true
        installViewObservers()
    }

    deinit {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installViewObservers()
        installWindowObservers()
        scheduleReport()
    }

    func scheduleReport() {
        guard !reportScheduled else { return }
        reportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reportScheduled = false
            self.reportCurrentFrame()
        }
    }

    private func reportCurrentFrame() {
        guard let window else {
            report(nil)
            return
        }

        let frameInWindow = convert(bounds, to: nil)
        let frameOnScreen = window.convertToScreen(frameInWindow)
        guard frameOnScreen.width > 0, frameOnScreen.height > 0 else {
            report(nil)
            return
        }

        report(frameOnScreen)
    }

    func report(_ frame: CGRect?) {
        guard frame != lastReportedFrame else { return }
        lastReportedFrame = frame
        onChange?(itemIDs, frame)
    }

    private func installViewObservers() {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: self,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleReport()
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: self,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleReport()
                }
            }
        )
    }

    private func installWindowObservers() {
        guard let window else { return }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleReport()
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleReport()
                }
            }
        )
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
    }
}
