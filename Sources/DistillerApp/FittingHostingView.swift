import AppKit
import SwiftUI

/// A hosting view that keeps its window exactly the size of its SwiftUI content, for the small
/// floating panels whose content grows and shrinks (a summary appears, a message comes and
/// goes). A fixed-size window would cut the content off at the top and bottom instead. The
/// window's top edge stays where it is, and the window stays on its screen.
final class FittingHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.fitWindow() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fitWindow()
    }

    func fitWindow() {
        guard let window else { return }
        let size = fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        guard abs(size.height - content.height) > 0.5 || abs(size.width - content.width) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: content.origin, size: size))
        frame.origin.y = window.frame.maxY - frame.height
        if let visible = window.screen?.visibleFrame {
            frame.origin.y = max(frame.origin.y, visible.minY)
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        }
        window.setFrame(frame, display: true)
    }
}
