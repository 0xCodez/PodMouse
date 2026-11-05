import Foundation

public enum Gesture: Equatable, Sendable {
    case tap
    case twistRight
    case twistLeft
    case nod
    case shake
}

/// Hand mode: tap the case, twist the wrist. Head mode: nod, shake.
public struct GestureDetector: Sendable {
    /// A twist is a sharp turn and back, so a single jerk of the wrist doesn't count.
    static let twistThreshold = 200.0
    static let twistReturnThreshold = 120.0
    static let twistWindow: TimeInterval = 0.6
    static let nodThreshold = 50.0
    static let shakeThreshold = 110.0
    /// In recordings, real taps land on a nearly still hand and most other jolts don't.
    static let maxRateBeforeTap = 60.0
    static let tapLookback: TimeInterval = 0.14
    static let tapLookbackSkip: TimeInterval = 0.03
    static let tapCooldown: TimeInterval = 0.35
    static let twistCooldown: TimeInterval = 0.7
    static let nodWindow: TimeInterval = 0.6
    static let nodCooldown: TimeInterval = 0.8
    static let shakeWindow: TimeInterval = 1.0
    static let shakeCooldown: TimeInterval = 1.2
    static let maxGap: TimeInterval = 0.25

    public var mode: ControlMode
    /// Sample-to-sample jump in acceleration, in g, that counts as a tap.
    public var tapThreshold: Double
    /// Latest jump in acceleration, shown in the settings so the threshold can be tuned by eye.
    public private(set) var lastJolt = 0.0

    private var previousAcceleration: Vec3?
    private var previousTime: TimeInterval?
    private var quietUntil: TimeInterval = 0
    private var recentSpeeds: [(time: TimeInterval, speed: Double)] = []
    private var twistStart: (time: TimeInterval, sign: Double)?
    private var nodStart: TimeInterval?
    private var shakeSign = 0.0
    private var shakeCount = 0
    private var shakeStart: TimeInterval = 0

    public init(mode: ControlMode, tapThreshold: Double) {
        self.mode = mode
        self.tapThreshold = tapThreshold
    }

    public mutating func push(_ frame: MotionFrame, rates: ControlRates) -> Gesture? {
        let t = frame.timestamp
        var jolt = 0.0
        if let previousAcceleration, let previousTime, t - previousTime <= Self.maxGap {
            jolt = (frame.userAcceleration - previousAcceleration).length
        }
        previousAcceleration = frame.userAcceleration
        previousTime = t
        lastJolt = jolt

        recentSpeeds.append((t, frame.rotationRate.length * 180 / .pi))
        recentSpeeds.removeAll { t - $0.time > Self.tapLookback }

        guard t >= quietUntil else { return nil }
        switch mode {
        case .hand: return detectHand(t, jolt: jolt, rates: rates)
        case .head: return detectHead(t, rates: rates)
        }
    }

    private mutating func detectHand(_ t: TimeInterval, jolt: Double, rates: ControlRates) -> Gesture? {
        if let twist = detectTwist(t, rates: rates) { return twist }
        guard jolt > tapThreshold else { return nil }

        // The tap's own kick shows up in the newest samples, so look just before them.
        let before = recentSpeeds.filter { t - $0.time >= Self.tapLookbackSkip }.map(\.speed)
        guard !before.isEmpty, before.reduce(0, +) / Double(before.count) < Self.maxRateBeforeTap else { return nil }
        quietUntil = t + Self.tapCooldown
        return .tap
    }

    private mutating func detectTwist(_ t: TimeInterval, rates: ControlRates) -> Gesture? {
        let pointing = max(abs(rates.yaw), abs(rates.pitch))
        if let start = twistStart, t - start.time > Self.twistWindow { twistStart = nil }

        if let start = twistStart {
            if rates.roll * start.sign < -Self.twistReturnThreshold {
                twistStart = nil
                quietUntil = t + Self.twistCooldown
                return start.sign > 0 ? .twistRight : .twistLeft
            }
        } else if abs(rates.roll) > Self.twistThreshold, abs(rates.roll) > 1.3 * pointing {
            twistStart = (t, rates.roll > 0 ? 1 : -1)
        }
        return nil
    }

    private mutating func detectHead(_ t: TimeInterval, rates: ControlRates) -> Gesture? {
        if abs(rates.yaw) > Self.shakeThreshold {
            let sign: Double = rates.yaw > 0 ? 1 : -1
            if sign != shakeSign {
                if shakeCount == 0 || t - shakeStart > Self.shakeWindow {
                    shakeCount = 0
                    shakeStart = t
                }
                shakeSign = sign
                shakeCount += 1
                if shakeCount >= 3 {
                    shakeCount = 0
                    shakeSign = 0
                    quietUntil = t + Self.shakeCooldown
                    return .shake
                }
            }
        }

        let isVertical = abs(rates.yaw) < 0.7 * abs(rates.pitch)
        if rates.pitch < -Self.nodThreshold, isVertical {
            nodStart = t
        } else if rates.pitch > Self.nodThreshold, isVertical, let start = nodStart, t - start <= Self.nodWindow {
            nodStart = nil
            quietUntil = t + Self.nodCooldown
            return .nod
        }
        return nil
    }
}
