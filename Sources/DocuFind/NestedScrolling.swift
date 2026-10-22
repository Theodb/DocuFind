import AppKit

/// Scrolling for scroll views inside the scrolling page (a document card inside the results), the way browsers do it:
/// - a scroll that starts over a card scrolls the card, and goes to the page once the card is at its top or bottom;
/// - a whole gesture, momentum included, stays with what it started on, so a page that is already moving keeps
///   moving when a card passes under the pointer.
@MainActor
enum NestedScrolling {
    /// Where the current trackpad gesture goes; nil for plain mouse wheels, which are decided per event.
    private static weak var target: NSScrollView?
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in route(event) }
    }

    private static func route(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, let content = window.contentView else { return event }
        let point = event.locationInWindow
        let starts = event.phase == .began || event.phase == .mayBegin
        let discrete = event.phase == [] && event.momentumPhase == []
        if starts || discrete {
            target = choose(in: content, at: point, deltaY: event.scrollingDeltaY, deltaX: event.scrollingDeltaX)
        }
        guard let target, target.window === window else { return event }
        if discrete { Self.target = nil }
        // Already headed for the innermost scroll view under the pointer: let AppKit deliver it as usual.
        if scrollViews(in: content, at: point).first === target { return event }
        target.scrollWheel(with: event)
        return nil
    }

    /// The innermost scroll view under the pointer that can still move this way; the page when the card can't.
    static func choose(in content: NSView, at point: NSPoint, deltaY: CGFloat, deltaX: CGFloat) -> NSScrollView? {
        let chain = scrollViews(in: content, at: point)
        guard let first = chain.first else { return nil }
        // Sideways gestures are left alone.
        guard abs(deltaY) >= abs(deltaX), deltaY != 0 else { return first }
        return chain.first { canScroll($0, deltaY: deltaY) } ?? first
    }

    /// The vertical scroll views under a window point, innermost first. Found by geometry, since SwiftUI's hosting
    /// views don't hit-test into scroll views nested inside them.
    private static func scrollViews(in content: NSView, at point: NSPoint) -> [NSScrollView] {
        var found: [(NSScrollView, Int)] = []
        func visit(_ view: NSView, depth: Int) {
            guard !view.isHidden, view.alphaValue > 0 else { return }
            if let scroll = view as? NSScrollView, scroll.hasVerticalScroller || scroll.verticalScrollElasticity != .none,
               scroll.convert(scroll.bounds, to: nil).contains(point) {
                found.append((scroll, depth))
            }
            for sub in view.subviews { visit(sub, depth: depth + 1) }
        }
        visit(content, depth: 0)
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Whether the scroll view has room to move in the direction of `deltaY` (positive: toward the top).
    private static func canScroll(_ scroll: NSScrollView, deltaY: CGFloat) -> Bool {
        guard let document = scroll.documentView else { return false }
        let clip = scroll.contentView.bounds
        let range = document.frame.height - clip.height
        guard range > 1 else { return false }
        let offset = clip.origin.y - document.frame.minY
        let towardTop = deltaY > 0
        if document.isFlipped {
            return towardTop ? offset > 0.5 : offset < range - 0.5
        } else {
            return towardTop ? offset < range - 0.5 : offset > 0.5
        }
    }
}
