import AppKit
import QuartzCore
import SwiftUI

/// A transparent panel that shows something over the desktop and never takes clicks or focus.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    convenience init(size: CGSize) {
        self.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        animationBehavior = .none
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// `point` is in global display coordinates, whose origin is at the top left.
    func origin(centredOn point: CGPoint) -> CGPoint? {
        guard let height = NSScreen.screens.first?.frame.height else { return nil }
        return CGPoint(x: point.x - frame.width / 2, y: height - point.y - frame.height / 2)
    }
}

private enum Glow {
    /// Sublayers don't inherit a window's backing scale, and both effects are too small to look soft.
    static let scale: CGFloat = 2
    static let aurora = (Theme.aurora + [Theme.aurora[0]]).map { NSColor($0).cgColor }
    static let coral = [
        CGColor(red: 1, green: 0.42, blue: 0.36, alpha: 1),
        CGColor(red: 1, green: 0.62, blue: 0.5, alpha: 1),
        CGColor(red: 1, green: 0.3, blue: 0.42, alpha: 1),
        CGColor(red: 1, green: 0.42, blue: 0.36, alpha: 1),
    ]

    static func conic(side: CGFloat) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.type = .conic
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        layer.contentsScale = scale
        return layer
    }

    /// Starts at 12 o'clock and runs clockwise. The layer's `shadow` makes the mask soft, so
    /// the gradient behind it spreads into a halo around the stroke.
    static func circle(side: CGFloat, radius: CGFloat, lineWidth: CGFloat, halo: CGFloat) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        layer.contentsScale = scale
        let path = CGMutablePath()
        path.addArc(
            center: CGPoint(x: side / 2, y: side / 2), radius: radius,
            startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true
        )
        layer.path = path
        layer.fillColor = nil
        layer.strokeColor = .white
        layer.lineWidth = lineWidth
        layer.lineCap = .round
        layer.shadowColor = .white
        layer.shadowOffset = .zero
        layer.shadowRadius = halo
        layer.shadowOpacity = halo > 0 ? 0.9 : 0
        return layer
    }

    static func image(of layer: CALayer, side: CGFloat) -> NSImage? {
        let pixels = Int(side * scale)
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context.makeImage().map { NSImage(cgImage: $0, size: CGSize(width: side, height: side)) }
    }
}

/// A burst of light where a click landed. Core Animation plays all of it in the render server,
/// so a click costs the main thread, which also runs the pointer, nothing per frame.
final class ClickRipple {
    private final class Ring {
        let gradient = Glow.conic(side: Layers.side)
        let stroke = Glow.circle(side: Layers.side, radius: Layers.reach, lineWidth: 2, halo: 6)

        init(in root: CALayer) {
            gradient.mask = stroke
            gradient.opacity = 0
            root.addSublayer(gradient)
        }

        func pose(scale: CGFloat, lineWidth: CGFloat, opacity: Float) {
            gradient.transform = CATransform3DMakeScale(scale, scale, 1)
            stroke.lineWidth = lineWidth
            gradient.opacity = opacity
        }

        func stop() {
            gradient.removeAllAnimations()
            stroke.removeAllAnimations()
        }

        func play(duration: Double, delay: Double, reach: CGFloat, turn: Double) {
            gradient.add(Layers.ease("transform.scale", from: 0.14, to: reach, duration, delay), forKey: "scale")
            gradient.add(Layers.ease("transform.rotation.z", from: 0, to: turn, duration, delay), forKey: "turn")
            gradient.add(Layers.fade(from: 1, duration, delay), forKey: "fade")
            // Scaling thickens the stroke too, so it starts wide and thins to a hairline as it grows.
            stroke.add(Layers.ease("lineWidth", from: 20, to: 1.5 / reach, duration, delay), forKey: "width")
        }
    }

    private final class Layers {
        static let side: CGFloat = 170
        /// The radius of a ring at full size, leaving room inside the panel for its halo.
        static let reach: CGFloat = 66
        private static let outward = CAMediaTimingFunction(controlPoints: 0.12, 0.8, 0.24, 1)

        let root = CALayer()
        private let flash = CAGradientLayer()
        private let outer: Ring
        private let inner: Ring

        init() {
            root.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
            flash.type = .radial
            flash.startPoint = CGPoint(x: 0.5, y: 0.5)
            flash.endPoint = CGPoint(x: 1, y: 1)
            flash.frame = root.frame.insetBy(dx: 30, dy: 30)
            flash.contentsScale = Glow.scale
            flash.opacity = 0
            root.addSublayer(flash)
            inner = Ring(in: root)
            outer = Ring(in: root)
        }

        func tint(_ pulse: AuraPulse) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let colors = pulse == .rightClick ? Glow.coral : Glow.aurora
            outer.gradient.colors = colors
            inner.gradient.colors = colors
            let core = pulse == .rightClick ? CGColor(red: 1, green: 0.62, blue: 0.54, alpha: 0.7) : CGColor(red: 0.86, green: 0.88, blue: 1, alpha: 0.7)
            flash.colors = [core, core.copy(alpha: 0) as Any]
            CATransaction.commit()
        }

        func play(reduceMotion: Bool) {
            flash.removeAllAnimations()
            outer.stop()
            inner.stop()
            guard !reduceMotion else {
                outer.pose(scale: 0.5, lineWidth: 3, opacity: 0)
                outer.gradient.add(Self.fade(from: 0.8, 0.45, 0), forKey: "fade")
                flash.add(Self.fade(from: 0.7, 0.4, 0), forKey: "fade")
                return
            }
            outer.pose(scale: 1, lineWidth: 1.5, opacity: 0)
            inner.pose(scale: 0.68, lineWidth: 1.5, opacity: 0)
            outer.play(duration: 0.5, delay: 0, reach: 1, turn: 0.7)
            inner.play(duration: 0.42, delay: 0.07, reach: 0.68, turn: -0.5)
            flash.add(Self.fade(from: 1, 0.3, 0), forKey: "fade")
            flash.add(Self.ease("transform.scale", from: 0.3, to: 1, 0.3, 0), forKey: "scale")
        }

        /// Partway through the burst, as model values, for a still.
        func freeze() {
            outer.pose(scale: 0.74, lineWidth: 3, opacity: 0.9)
            inner.pose(scale: 0.5, lineWidth: 4, opacity: 0.75)
            flash.opacity = 0.5
            flash.transform = CATransform3DMakeScale(0.8, 0.8, 1)
        }

        static func ease(_ keyPath: String, from: Double, to: Double, _ duration: Double, _ delay: Double) -> CABasicAnimation {
            let animation = timed(keyPath, from: from, to: to, duration, delay)
            animation.timingFunction = outward
            return animation
        }

        static func fade(from: Double, _ duration: Double, _ delay: Double) -> CABasicAnimation {
            let animation = timed("opacity", from: from, to: 0, duration, delay)
            animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
            return animation
        }

        private static func timed(_ keyPath: String, from: Double, to: Double, _ duration: Double, _ delay: Double) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            if delay > 0 {
                animation.beginTime = CACurrentMediaTime() + delay
                animation.fillMode = .backwards
            }
            return animation
        }
    }

    private static let duration: TimeInterval = 0.56
    private let layers = Layers()
    private var hideWork: DispatchWorkItem?
    private lazy var panel: OverlayPanel = {
        let panel = OverlayPanel(size: CGSize(width: Layers.side, height: Layers.side))
        panel.contentView = hostView(for: layers.root)
        return panel
    }()

    /// `point` is in global display coordinates, whose origin is at the top left.
    /// The click has already been posted, and the panel lets everything through anyway.
    func show(at point: CGPoint, pulse: AuraPulse) {
        guard let origin = panel.origin(centredOn: point) else { return }
        hideWork?.cancel()
        panel.setFrameOrigin(origin)
        if !panel.isVisible { panel.orderFrontRegardless() }

        layers.tint(pulse)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layers.play(reduceMotion: Theme.reduceMotion)
        CATransaction.commit()

        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }

    static func still(pulse: AuraPulse) -> NSImage? {
        let layers = Layers()
        layers.tint(pulse)
        layers.freeze()
        return Glow.image(of: layers.root, side: Layers.side)
    }
}

/// The ring that fills around the pointer before a resting click.
/// `show` runs at the pointer's 120 Hz, so it only moves a stroke's end and never lays anything out.
final class DwellRing {
    private final class Layers {
        static let side: CGFloat = 64
        private static let radius: CGFloat = 18

        let root = CALayer()
        private let stroke = Glow.circle(side: side, radius: radius, lineWidth: 3, halo: 4)

        init() {
            root.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
            let track = Glow.circle(side: Self.side, radius: Self.radius, lineWidth: 4, halo: 0)
            track.strokeColor = CGColor(gray: 0, alpha: 0.2)
            root.addSublayer(track)

            let gradient = Glow.conic(side: Self.side)
            gradient.colors = Glow.aurora
            gradient.mask = stroke
            root.addSublayer(gradient)
            set(progress: 0)
        }

        func set(progress: Double) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stroke.strokeEnd = progress
            CATransaction.commit()
        }
    }

    private let layers = Layers()
    private var origin: CGPoint?
    private lazy var panel: OverlayPanel = {
        let panel = OverlayPanel(size: CGSize(width: Layers.side, height: Layers.side))
        panel.contentView = hostView(for: layers.root)
        return panel
    }()

    /// `point` is in global display coordinates, whose origin is at the top left.
    func show(at point: CGPoint, progress value: Double) {
        guard let next = panel.origin(centredOn: point) else { return }
        if next != origin {
            panel.setFrameOrigin(next)
            origin = next
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        layers.set(progress: value)
    }

    /// The tick calls this on every idle frame, so it's cheap when there's nothing to hide.
    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        layers.set(progress: 0)
    }

    static func still(progress: Double) -> NSImage? {
        let layers = Layers()
        layers.set(progress: progress)
        return Glow.image(of: layers.root, side: Layers.side)
    }
}

private func hostView(for layer: CALayer) -> NSView {
    let view = NSView(frame: layer.frame)
    view.wantsLayer = true
    view.layer?.addSublayer(layer)
    return view
}
