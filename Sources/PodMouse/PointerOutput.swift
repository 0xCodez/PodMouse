import ApplicationServices
import CoreGraphics

/// Posts synthetic mouse events. Requires the Accessibility permission.
final class PointerOutput {
    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var isDragging = false

    var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    func move(dx: Double, dy: Double) {
        let from = location
        let to = Self.clampedToDisplays(CGPoint(x: from.x + dx, y: from.y + dy))
        let type: CGEventType = isDragging ? .leftMouseDragged : .mouseMoved
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: to, mouseButton: .left) else { return }
        event.setDoubleValueField(.mouseEventDeltaX, value: to.x - from.x)
        event.setDoubleValueField(.mouseEventDeltaY, value: to.y - from.y)
        event.post(tap: .cghidEventTap)
    }

    func warp(to point: CGPoint) {
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    func leftClick(at point: CGPoint) {
        warp(to: point)
        post(.leftMouseDown, at: point, button: .left)
        post(.leftMouseUp, at: point, button: .left)
    }

    func rightClick(at point: CGPoint) {
        warp(to: point)
        post(.rightMouseDown, at: point, button: .right)
        post(.rightMouseUp, at: point, button: .right)
    }

    func toggleDrag() {
        isDragging.toggle()
        post(isDragging ? .leftMouseDown : .leftMouseUp, at: location, button: .left)
    }

    func endDrag() {
        if isDragging { toggleDrag() }
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }

    private static func clampedToDisplays(_ point: CGPoint) -> CGPoint {
        var count = UInt32(0)
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        let bounds = displays.map(CGDisplayBounds)
        if bounds.contains(where: { $0.contains(point) }) { return point }

        let clamped = bounds.map { rect in
            CGPoint(x: min(max(point.x, rect.minX), rect.maxX - 1), y: min(max(point.y, rect.minY), rect.maxY - 1))
        }
        return clamped.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) } ?? point
    }
}

/// Asks Accessibility whether the spot under the pointer is something you'd click,
/// so that resting on text while reading never clicks.
enum ClickTarget {
    private static let roles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXMenuButton", "AXPopUpButton",
        "AXCheckBox", "AXRadioButton", "AXTab", "AXTextField", "AXComboBox", "AXDockItem",
    ]

    static func exists(at point: CGPoint) -> Bool {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &found) == .success else {
            return false
        }
        var element = found
        for _ in 0..<4 {
            guard let current = element else { return false }
            if let role = attribute(kAXRoleAttribute, of: current) as? String, roles.contains(role) { return true }
            let parent = attribute(kAXParentAttribute, of: current)
            element = parent.map { $0 as! AXUIElement }
        }
        return false
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
