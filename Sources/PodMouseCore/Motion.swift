import Foundation

public struct Vec3: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)

    public var length: Double { (x * x + y * y + z * z).squareRoot() }

    public var normalized: Vec3 {
        let l = length
        return l > 1e-9 ? self * (1 / l) : .zero
    }

    public func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }

    public func cross(_ o: Vec3) -> Vec3 {
        Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
}

/// One reading from the headphones, in the device's own frame.
public struct MotionFrame: Equatable, Sendable {
    public var timestamp: TimeInterval
    /// rad/s
    public var rotationRate: Vec3
    /// In g, gravity removed.
    public var userAcceleration: Vec3
    /// Unit vector toward the ground.
    public var gravity: Vec3

    public init(timestamp: TimeInterval, rotationRate: Vec3, userAcceleration: Vec3 = .zero, gravity: Vec3 = .zero) {
        self.timestamp = timestamp
        self.rotationRate = rotationRate
        self.userAcceleration = userAcceleration
        self.gravity = gravity
    }
}

/// Rotation expressed in terms of the screen, in deg/s.
/// yaw > 0 turns right, pitch > 0 tilts up, roll > 0 twists clockwise.
public struct ControlRates: Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(yaw: Double, pitch: Double, roll: Double) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }
}

/// The axes a particular hand rotates around, in the device's frame.
///
/// Recorded wrists turn around one clean axis at a time, but those axes follow neither gravity
/// nor each other: side-to-side and up-down were about 74° apart. So both are measured, and
/// any rotation is split into the two without assuming they are perpendicular.
public struct AxisCalibration: Equatable, Codable, Sendable {
    /// Positive rotation around this moves the pointer right.
    public var yawAxis: Vec3
    /// Positive rotation around this moves the pointer up.
    public var pitchAxis: Vec3

    public init(yawAxis: Vec3, pitchAxis: Vec3) {
        self.yawAxis = yawAxis.normalized
        self.pitchAxis = pitchAxis.normalized
    }

    public func rates(for rotationRate: Vec3) -> ControlRates {
        let w = rotationRate
        let overlap = yawAxis.dot(pitchAxis)
        let alongYaw = w.dot(yawAxis), alongPitch = w.dot(pitchAxis)
        let scale = 1 / max(1 - overlap * overlap, 0.1)
        return ControlRates(
            yaw: Self.degrees((alongYaw - overlap * alongPitch) * scale),
            pitch: Self.degrees((alongPitch - overlap * alongYaw) * scale),
            roll: Self.degrees(w.dot(pitchAxis.cross(yawAxis).normalized))
        )
    }

    static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}

/// The dominant rotation axis of a stretch of back-and-forth motion. Sweeping several times
/// averages out wobble that a single turn would bake into the calibration.
struct SweepAxis: Sendable {
    /// Below this, a hand is settling rather than sweeping.
    static let minRate = 25.0
    /// Enough of the sweep's start to tell which way it set off.
    static let openingAngle = 20.0

    private(set) var travel = 0.0
    private var opening = Vec3.zero
    private var openingTravel = 0.0
    private var covariance = [Double](repeating: 0, count: 9)

    mutating func add(_ w: Vec3, dt: TimeInterval) {
        guard AxisCalibration.degrees(w.length) >= Self.minRate else { return }
        travel += AxisCalibration.degrees(w.length) * dt
        if openingTravel < Self.openingAngle {
            opening = opening + w * dt
            openingTravel += AxisCalibration.degrees(w.length) * dt
        }
        let v = [w.x, w.y, w.z]
        for i in 0..<3 {
            for j in 0..<3 { covariance[i * 3 + j] += v[i] * v[j] * dt }
        }
    }

    /// Principal axis of the sweep, pointing the way the sweep began.
    var axis: Vec3 {
        var v = opening.normalized
        guard v != .zero else { return .zero }
        for _ in 0..<40 {
            v = Vec3(
                covariance[0] * v.x + covariance[1] * v.y + covariance[2] * v.z,
                covariance[3] * v.x + covariance[4] * v.y + covariance[5] * v.z,
                covariance[6] * v.x + covariance[7] * v.y + covariance[8] * v.z
            ).normalized
        }
        return v.dot(opening) < 0 ? v * -1 : v
    }
}

/// Learns an `AxisCalibration` from a pause, then sweeps side to side and up and down.
public struct Calibrator: Sendable {
    public enum Step: Int, Sendable {
        case holdStill, sweepSides, sweepUpDown, done
    }

    static let stillRate = 30.0
    static let stillDuration: TimeInterval = 0.6
    static let settleDuration: TimeInterval = 0.5
    /// About three passes of a comfortable wrist sweep.
    static let requiredTravel = 170.0
    static let maxGap: TimeInterval = 0.25
    /// Axes this parallel mean the two sweeps were the same move.
    static let maxAxisOverlap = 0.75
    /// Below this, the side-to-side axis is too tilted for gravity to settle its direction.
    static let minVerticalness = 0.5

    public private(set) var step: Step = .holdStill
    /// 0...1 within the current step.
    public private(set) var progress = 0.0
    /// The hand has to stop before the up-down sweep, or the end of the last sweep leaks into it.
    public private(set) var isSettling = false

    private var lastTimestamp: TimeInterval?
    private var stillTime: TimeInterval = 0
    private var gravity = Vec3.zero
    private var sides = SweepAxis()
    private var upDown = SweepAxis()

    public init() {}

    /// Returns the finished calibration once the last sweep completes.
    public mutating func push(_ frame: MotionFrame) -> AxisCalibration? {
        defer { lastTimestamp = frame.timestamp }
        guard let last = lastTimestamp else { return nil }
        let dt = frame.timestamp - last
        guard dt > 0, dt <= Self.maxGap else { return nil }

        let w = frame.rotationRate
        switch step {
        case .holdStill:
            let isStill = AxisCalibration.degrees(w.length) < Self.stillRate
            stillTime = isStill ? stillTime + dt : 0
            gravity = isStill ? gravity + frame.gravity : .zero
            progress = min(stillTime / Self.stillDuration, 1)
            if stillTime >= Self.stillDuration { advance(to: .sweepSides) }
        case .sweepSides:
            sides.add(w, dt: dt)
            progress = min(sides.travel / Self.requiredTravel, 1)
            if sides.travel >= Self.requiredTravel {
                advance(to: .sweepUpDown)
                isSettling = true
                stillTime = 0
            }
        case .sweepUpDown:
            if isSettling {
                stillTime = AxisCalibration.degrees(w.length) < Self.stillRate ? stillTime + dt : 0
                if stillTime >= Self.settleDuration { isSettling = false }
                return nil
            }
            upDown.add(w, dt: dt)
            progress = min(upDown.travel / Self.requiredTravel, 1)
            if upDown.travel >= Self.requiredTravel {
                let yawAxis = rightward(sides.axis), pitchAxis = upDown.axis
                if abs(yawAxis.dot(pitchAxis)) > Self.maxAxisOverlap {
                    upDown = SweepAxis()
                    progress = 0
                    isSettling = true
                    stillTime = 0
                    return nil
                }
                advance(to: .done)
                return AxisCalibration(yawAxis: yawAxis, pitchAxis: pitchAxis)
            }
        case .done:
            break
        }
        return nil
    }

    /// Turning right is clockwise from above, whichever way the sweep happened to start.
    private func rightward(_ axis: Vec3) -> Vec3 {
        let down = gravity.normalized
        return axis.dot(down) < -Self.minVerticalness ? axis * -1 : axis
    }

    private mutating func advance(to next: Step) {
        step = next
        progress = 0
    }
}
