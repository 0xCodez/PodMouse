import Foundation

public enum ControlMode: String, Codable, CaseIterable, Sendable {
    /// The AirPods stay in their case and the case is held like an air mouse.
    case hand
    /// The AirPods are in the ears and the head points.
    case head

    /// A wrist turns about twice as fast as a head for the same intent, so it gets half the gain.
    var tuning: PointerTuning {
        switch self {
        case .hand: return PointerTuning(deadZone: 4, pixelsPerDegree: 15, acceleration: 0.6)
        case .head: return PointerTuning(deadZone: 3, pixelsPerDegree: 28, acceleration: 0.6)
        }
    }
}

struct PointerTuning: Sendable {
    /// Rotation below this, in deg/s, doesn't move that axis.
    var deadZone: Double
    var pixelsPerDegree: Double
    /// How much faster quick moves go; 0 is linear.
    var acceleration: Double
}

public struct PointerVelocity: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = PointerVelocity(x: 0, y: 0)
}

/// Rates → pixels per second, the mapping AirCursor uses: each axis has a small dead zone
/// and a gentle, bounded acceleration. It holds no state, so it can't stick or lurch.
public struct PointerMapper: Sendable {
    public var mode: ControlMode
    public var sensitivity: Double
    public var invertX = false
    public var invertY = false

    static let accelerationKnee = 60.0
    static let maxAccelerationSpan = 3.0

    public init(mode: ControlMode, sensitivity: Double) {
        self.mode = mode
        self.sensitivity = sensitivity
    }

    func axisSpeed(_ rate: Double) -> Double {
        let tuning = mode.tuning
        let magnitude = abs(rate)
        guard magnitude > tuning.deadZone else { return 0 }
        let effective = magnitude - tuning.deadZone
        let boost = 1 + tuning.acceleration * min(effective / Self.accelerationKnee, Self.maxAccelerationSpan)
        let speed = effective * tuning.pixelsPerDegree * sensitivity * boost
        return rate < 0 ? -speed : speed
    }

    public func velocity(for rates: ControlRates) -> PointerVelocity {
        let x = axisSpeed(rates.yaw), y = -axisSpeed(rates.pitch)
        return PointerVelocity(x: invertX ? -x : x, y: invertY ? -y : y)
    }
}

/// Motion arrives at about 50 Hz; the pointer is drawn at 120 Hz. Eases between samples
/// and stops as soon as samples go stale, so a dropped connection can't leave the pointer sliding.
public struct PointerSmoother: Sendable {
    static let timeConstant: TimeInterval = 0.028
    static let staleAfter: TimeInterval = 0.12

    private var target = PointerVelocity.zero
    private var current = PointerVelocity.zero
    private var targetTime: TimeInterval = 0

    public init() {}

    public mutating func reset() {
        target = .zero
        current = .zero
    }

    public mutating func setTarget(_ velocity: PointerVelocity, at time: TimeInterval) {
        target = velocity
        targetTime = time
    }

    /// Returns the pointer displacement in pixels for this step.
    public mutating func step(dt: TimeInterval, now: TimeInterval) -> (dx: Double, dy: Double) {
        let goal = now - targetTime > Self.staleAfter ? PointerVelocity.zero : target
        let blend = 1 - exp(-dt / Self.timeConstant)
        current.x += (goal.x - current.x) * blend
        current.y += (goal.y - current.y) * blend
        if abs(current.x) < 0.5, abs(current.y) < 0.5, goal == .zero { current = .zero }
        return (current.x * dt, current.y * dt)
    }
}

/// Decides when a pointer resting in place should click.
public struct DwellTracker: Sendable {
    public enum Update: Equatable, Sendable {
        case idle
        /// The pointer has settled here; the caller checks whether the spot is clickable.
        case settled(x: Double, y: Double)
        case progress(Double)
        case fire
    }

    static let radius = 9.0
    static let settleTime: TimeInterval = 0.25
    /// The pointer must travel this far before it can click again.
    static let rearmDistance = 30.0

    public var duration: TimeInterval
    /// Set by the caller after `.settled`: false stops the countdown for this spot.
    public var targetIsClickable = false

    private var anchorX = 0.0
    private var anchorY = 0.0
    private var anchorTime: TimeInterval?
    private var armed = false
    private var didSettle = false

    public init(duration: TimeInterval) {
        self.duration = duration
    }

    public mutating func push(x: Double, y: Double, time: TimeInterval) -> Update {
        guard let start = anchorTime else {
            anchor(x, y, time)
            return .idle
        }
        let distance = hypot(x - anchorX, y - anchorY)
        if distance > Self.radius {
            if distance > Self.rearmDistance { armed = true }
            if armed { anchor(x, y, time) } else { return .idle }
            return .idle
        }
        guard armed else { return .idle }

        let held = time - start
        if !didSettle {
            guard held >= Self.settleTime else { return .idle }
            didSettle = true
            return .settled(x: anchorX, y: anchorY)
        }
        guard targetIsClickable else { return .idle }
        let progress = (held - Self.settleTime) / duration
        if progress >= 1 {
            armed = false
            didSettle = false
            targetIsClickable = false
            return .fire
        }
        return .progress(progress)
    }

    private mutating func anchor(_ x: Double, _ y: Double, _ time: TimeInterval) {
        anchorX = x
        anchorY = y
        anchorTime = time
        didSettle = false
        targetIsClickable = false
    }
}
