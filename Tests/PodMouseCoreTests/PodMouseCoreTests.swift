import XCTest
@testable import PodMouseCore

private let degree = Double.pi / 180

/// Maps world directions (x right, y toward the screen, z up) into a device's own frame.
private struct Pose {
    var toDevice: (Vec3) -> Vec3

    static let flat = Pose { $0 }
    static let tumbled = Pose { v in
        // Rotate 90° about x, then 35° about the new z, as AirPods might sit in a held case.
        let a = Vec3(v.x, v.z, -v.y)
        let c = cos(35 * degree), s = sin(35 * degree)
        return Vec3(c * a.x - s * a.y, s * a.x + c * a.y, a.z)
    }

    func frame(_ t: Double, worldRate: Vec3) -> MotionFrame {
        MotionFrame(timestamp: t, rotationRate: toDevice(worldRate), gravity: toDevice(Vec3(0, 0, -1)))
    }
}

/// Sweeps the way the calibration asks: right first, up first, with some wobble on the other axes.
private func calibrate(_ pose: Pose, startingSide: Double = 1) -> AxisCalibration? {
    var calibrator = Calibrator()
    var t = 0.0
    var result: AxisCalibration?
    func tick(_ rate: (Double) -> Vec3, for seconds: Double) {
        for i in 0..<Int(seconds * 50) where result == nil {
            t += 0.02
            result = calibrator.push(pose.frame(t, worldRate: rate(Double(i) * 0.02) * degree))
        }
    }
    tick({ _ in .zero }, for: 1)
    tick({ s in Vec3(8 * sin(s * 9), 0, -70 * startingSide * cos(s * 2.5)) }, for: 6)
    tick({ _ in .zero }, for: 1)
    tick({ s in Vec3(70 * cos(s * 2.5), 0, 8 * sin(s * 9)) }, for: 6)
    return result
}

final class CalibrationTests: XCTestCase {
    func testRecoversAxesWhateverTheOrientation() throws {
        for pose in [Pose.flat, Pose.tumbled] {
            let calibration = try XCTUnwrap(calibrate(pose))

            let right = calibration.rates(for: pose.toDevice(Vec3(0, 0, -30 * degree)))
            XCTAssertEqual(right.yaw, 30, accuracy: 2)
            XCTAssertEqual(right.pitch, 0, accuracy: 2)

            let up = calibration.rates(for: pose.toDevice(Vec3(30 * degree, 0, 0)))
            XCTAssertEqual(up.pitch, 30, accuracy: 2)
            XCTAssertEqual(up.yaw, 0, accuracy: 2)

            let twist = calibration.rates(for: pose.toDevice(Vec3(0, 200 * degree, 0)))
            XCTAssertEqual(twist.roll, 200, accuracy: 5)
        }
    }

    func testRightIsRightEvenIfTheSweepStartsLeft() throws {
        let calibration = try XCTUnwrap(calibrate(.tumbled, startingSide: -1))
        let right = calibration.rates(for: Pose.tumbled.toDevice(Vec3(0, 0, -30 * degree)))
        XCTAssertEqual(right.yaw, 30, accuracy: 2)
    }

    func testAxesThatArentPerpendicularStillSeparate() {
        let yawAxis = Vec3(0, 1, 0), pitchAxis = Vec3(sin(74 * degree), cos(74 * degree), 0)
        let calibration = AxisCalibration(yawAxis: yawAxis, pitchAxis: pitchAxis)

        let sideways = calibration.rates(for: yawAxis * (40 * degree))
        XCTAssertEqual(sideways.yaw, 40, accuracy: 0.01)
        XCTAssertEqual(sideways.pitch, 0, accuracy: 0.01)

        let upward = calibration.rates(for: pitchAxis * (40 * degree))
        XCTAssertEqual(upward.pitch, 40, accuracy: 0.01)
        XCTAssertEqual(upward.yaw, 0, accuracy: 0.01)
    }

    func testMovingDuringHoldStillRestartsIt() {
        var calibrator = Calibrator()
        var t = 0.0
        for _ in 0..<100 {
            t += 0.02
            XCTAssertNil(calibrator.push(Pose.flat.frame(t, worldRate: Vec3(0, 0, 60 * degree))))
        }
        XCTAssertEqual(calibrator.step, .holdStill)
        XCTAssertEqual(calibrator.progress, 0)
    }

    func testDataGapIsNotIntegrated() {
        var calibrator = Calibrator()
        _ = calibrator.push(Pose.flat.frame(0, worldRate: .zero))
        _ = calibrator.push(Pose.flat.frame(5, worldRate: .zero))
        XCTAssertEqual(calibrator.progress, 0)
    }

    func testSameMoveTwiceIsRefused() {
        var calibrator = Calibrator()
        var t = 0.0
        var result: AxisCalibration?
        for i in 0..<1500 where result == nil {
            t += 0.02
            let rate = i < 50 ? 0 : 80 * cos(Double(i) * 0.05)
            result = calibrator.push(Pose.flat.frame(t, worldRate: Vec3(0, 0, rate * degree)))
        }
        XCTAssertNil(result)
    }
}

final class PointerTests: XCTestCase {
    func testDirections() {
        let mapper = PointerMapper(mode: .hand, sensitivity: 1)
        let right = mapper.velocity(for: ControlRates(yaw: 40, pitch: 0, roll: 0))
        XCTAssertGreaterThan(right.x, 0)
        XCTAssertEqual(right.y, 0)
        XCTAssertLessThan(mapper.velocity(for: ControlRates(yaw: 0, pitch: 40, roll: 0)).y, 0, "screen y grows downward")
    }

    func testInversion() {
        var mapper = PointerMapper(mode: .hand, sensitivity: 1)
        mapper.invertX = true
        mapper.invertY = true
        let velocity = mapper.velocity(for: ControlRates(yaw: 40, pitch: 40, roll: 0))
        XCTAssertLessThan(velocity.x, 0)
        XCTAssertGreaterThan(velocity.y, 0)
    }

    func testTremorAndRollAreIgnored() {
        let mapper = PointerMapper(mode: .hand, sensitivity: 3)
        XCTAssertEqual(mapper.velocity(for: ControlRates(yaw: 3, pitch: -3, roll: 300)), .zero)
    }

    func testResponseIsContinuousAndNeverJumps() {
        let mapper = PointerMapper(mode: .hand, sensitivity: 1)
        var previous = 0.0
        for rate in stride(from: 0.0, to: 300, by: 0.5) {
            let speed = mapper.velocity(for: ControlRates(yaw: rate, pitch: 0, roll: 0)).x
            XCTAssertGreaterThanOrEqual(speed, previous)
            XCTAssertLessThan(speed - previous, 40)
            previous = speed
        }
    }

    func testAccelerationIsGentleAndBounded() {
        let mapper = PointerMapper(mode: .hand, sensitivity: 1)
        func gain(_ rate: Double) -> Double { mapper.velocity(for: ControlRates(yaw: rate, pitch: 0, roll: 0)).x / rate }
        XCTAssertGreaterThan(gain(150), gain(30))
        XCTAssertLessThan(gain(150), gain(30) * 2.5)
        XCTAssertLessThan(gain(1000), gain(30) * 3.5)
    }

    func testSmootherStopsWhenSamplesGoStale() {
        var smoother = PointerSmoother()
        smoother.setTarget(PointerVelocity(x: 1000, y: 0), at: 0)
        var moved = 0.0
        var t = 0.0
        for _ in 0..<12 {
            t += 1.0 / 120
            moved += smoother.step(dt: 1.0 / 120, now: t).dx
        }
        XCTAssertGreaterThan(moved, 0)

        for _ in 0..<120 {
            t += 1.0 / 120
            _ = smoother.step(dt: 1.0 / 120, now: t)
        }
        XCTAssertEqual(smoother.step(dt: 1.0 / 120, now: t).dx, 0)
    }

    func testSmoothedDistanceMatchesTheVelocity() {
        var smoother = PointerSmoother()
        var moved = 0.0
        var t = 0.0
        for _ in 0..<120 {
            t += 1.0 / 120
            smoother.setTarget(PointerVelocity(x: 600, y: 0), at: t)
            moved += smoother.step(dt: 1.0 / 120, now: t).dx
        }
        XCTAssertEqual(moved, 600, accuracy: 40)
    }
}

final class DwellTests: XCTestCase {
    private func run(_ tracker: inout DwellTracker, x: Double, from start: Double, seconds: Double) -> [DwellTracker.Update] {
        stride(from: start, to: start + seconds, by: 0.01).map { tracker.push(x: x, y: 0, time: $0) }
    }

    func testRestingOnSomethingClickableFiresOnce() {
        var tracker = DwellTracker(duration: 0.5)
        _ = tracker.push(x: 0, y: 0, time: 0)
        _ = tracker.push(x: 100, y: 0, time: 0.1)

        var updates = [DwellTracker.Update]()
        for time in stride(from: 0.11, to: 3, by: 0.01) {
            let update = tracker.push(x: 100, y: 0, time: time)
            if case .settled = update { tracker.targetIsClickable = true }
            updates.append(update)
        }
        XCTAssertEqual(updates.filter { $0 == .fire }.count, 1)
    }

    func testRestingOnPlainTextNeverFires() {
        var tracker = DwellTracker(duration: 0.5)
        _ = tracker.push(x: 0, y: 0, time: 0)
        _ = tracker.push(x: 100, y: 0, time: 0.1)
        XCTAssertFalse(run(&tracker, x: 100, from: 0.11, seconds: 3).contains(.fire))
    }

    func testDoesNotFireBeforeThePointerHasMoved() {
        var tracker = DwellTracker(duration: 0.5)
        tracker.targetIsClickable = true
        XCTAssertFalse(run(&tracker, x: 0, from: 0, seconds: 3).contains(.fire))
    }
}

final class GestureTests: XCTestCase {
    private func stream(_ detector: inout GestureDetector, _ rates: [ControlRates], accelerations: [Vec3] = []) -> [Gesture] {
        var found = [Gesture]()
        for (i, r) in rates.enumerated() {
            let w = Vec3(r.pitch, r.yaw, r.roll) * degree
            let frame = MotionFrame(
                timestamp: Double(i) * 0.02,
                rotationRate: w,
                userAcceleration: i < accelerations.count ? accelerations[i] : .zero
            )
            if let gesture = detector.push(frame, rates: r) { found.append(gesture) }
        }
        return found
    }

    private let still = ControlRates(yaw: 0, pitch: 0, roll: 0)

    func testTapOnAStillHand() {
        var detector = GestureDetector(mode: .hand, tapThreshold: 0.5)
        let rates = Array(repeating: still, count: 30)
        var accelerations = Array(repeating: Vec3.zero, count: 30)
        accelerations[20] = Vec3(0.8, 0, 0)
        XCTAssertEqual(stream(&detector, rates, accelerations: accelerations), [.tap])
    }

    func testAJoltWhileMovingIsNotATap() {
        var detector = GestureDetector(mode: .hand, tapThreshold: 0.5)
        let rates = Array(repeating: ControlRates(yaw: 120, pitch: 0, roll: 0), count: 30)
        var accelerations = Array(repeating: Vec3.zero, count: 30)
        accelerations[20] = Vec3(0.8, 0, 0)
        XCTAssertEqual(stream(&detector, rates, accelerations: accelerations), [])
    }

    func testGentleAccelerationIsNotATap() {
        var detector = GestureDetector(mode: .hand, tapThreshold: 0.5)
        let rates = Array(repeating: still, count: 30)
        let ramp = (0..<30).map { Vec3(Double($0) * 0.02, 0, 0) }
        XCTAssertEqual(stream(&detector, rates, accelerations: ramp), [])
    }

    func testTwistIsThereAndBack() {
        var detector = GestureDetector(mode: .hand, tapThreshold: 0.5)
        let there = ControlRates(yaw: 10, pitch: 5, roll: 260)
        let back = ControlRates(yaw: 0, pitch: 0, roll: -220)
        XCTAssertEqual(stream(&detector, [still, there, there, still, back, back, still]), [.twistRight])

        var other = GestureDetector(mode: .hand, tapThreshold: 0.5)
        XCTAssertEqual(stream(&other, [still, back, back, still, there, there, still].map {
            ControlRates(yaw: $0.yaw, pitch: $0.pitch, roll: $0.roll * 1.2)
        }), [.twistLeft])
    }

    func testAOneWayJerkIsNotATwist() {
        var detector = GestureDetector(mode: .hand, tapThreshold: 0.5)
        let there = ControlRates(yaw: 0, pitch: 0, roll: 260)
        XCTAssertEqual(stream(&detector, [still, there, there] + Array(repeating: still, count: 60)), [])
    }

    func testPointingFastIsNotATwist() {
        var detector = GestureDetector(mode: .hand, tapThreshold: 0.5)
        XCTAssertEqual(stream(&detector, [ControlRates(yaw: 400, pitch: 0, roll: 220), ControlRates(yaw: 400, pitch: 0, roll: -220)]), [])
    }

    func testNodIsDownThenUp() {
        var detector = GestureDetector(mode: .head, tapThreshold: 0.5)
        let down = ControlRates(yaw: 0, pitch: -80, roll: 0)
        let up = ControlRates(yaw: 0, pitch: 80, roll: 0)
        XCTAssertEqual(stream(&detector, [still, down, down, still, up, still]), [.nod])

        var lookingUp = GestureDetector(mode: .head, tapThreshold: 0.5)
        XCTAssertEqual(stream(&lookingUp, [still, up, up, still]), [])
    }

    func testShakeNeedsThreeSwings() {
        var detector = GestureDetector(mode: .head, tapThreshold: 0.5)
        let left = ControlRates(yaw: -150, pitch: 0, roll: 0)
        let right = ControlRates(yaw: 150, pitch: 0, roll: 0)
        XCTAssertEqual(stream(&detector, [left, left, right, right, left, left]), [.shake])

        var oneTurn = GestureDetector(mode: .head, tapThreshold: 0.5)
        XCTAssertEqual(stream(&oneTurn, [right, right, right, right]), [])
    }

    func testHandModeIgnoresHeadGestures() {
        var detector = GestureDetector(mode: .hand, tapThreshold: 0.5)
        let down = ControlRates(yaw: 0, pitch: -80, roll: 0)
        let up = ControlRates(yaw: 0, pitch: 80, roll: 0)
        XCTAssertEqual(stream(&detector, [down, up]), [])
    }
}

/// A real AirPods 4 case in a hand, recorded in labelled phases.
final class RecordingTests: XCTestCase {
    private struct Sample {
        var phase: String
        var frame: MotionFrame
    }

    private func load() throws -> [Sample] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "case-recording", withExtension: "csv", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").dropFirst().map { line in
            let c = line.split(separator: ",").map(String.init)
            let v = c[1...].map { Double($0)! }
            return Sample(phase: c[0], frame: MotionFrame(
                timestamp: v[0],
                rotationRate: Vec3(v[1], v[2], v[3]),
                userAcceleration: Vec3(v[4], v[5], v[6])
            ))
        }
    }

    /// Runs the phases' clean stretches through the real calibrator.
    private func calibration(from samples: [Sample]) throws -> AxisCalibration {
        var calibrator = Calibrator()
        var t = 0.0
        for _ in 0..<60 {
            t += 0.02
            _ = calibrator.push(MotionFrame(timestamp: t, rotationRate: .zero))
        }
        let sides = samples.filter { $0.phase == "slow-yaw" }.dropFirst(75).map(\.frame.rotationRate)
        let pause = [Vec3](repeating: .zero, count: 20)
        let upDown = samples.filter { $0.phase == "slow-pitch" }.dropFirst(150).map(\.frame.rotationRate)
        for rate in sides + pause + upDown {
            t += 0.02
            if let result = calibrator.push(MotionFrame(timestamp: t, rotationRate: rate)) { return result }
        }
        throw XCTSkip("recording too short to finish calibrating")
    }

    private struct Replay {
        var pathX = 0.0, pathY = 0.0
        var path: Double { hypot(pathX, pathY) }
        var gestures = [Gesture]()
        var movingSamples = 0, frozenSamples = 0
    }

    private func replay(_ samples: [Sample], phase: String, skipping: Int = 0, _ calibration: AxisCalibration) -> Replay {
        let mapper = PointerMapper(mode: .hand, sensitivity: 1)
        var smoother = PointerSmoother()
        var detector = GestureDetector(mode: .hand, tapThreshold: 0.5)
        var result = Replay()
        for sample in samples.filter({ $0.phase == phase }).dropFirst(skipping) {
            let rates = calibration.rates(for: sample.frame.rotationRate)
            if let gesture = detector.push(sample.frame, rates: rates) { result.gestures.append(gesture) }
            let velocity = mapper.velocity(for: rates)
            if hypot(rates.yaw, rates.pitch) > 20 {
                result.movingSamples += 1
                if velocity == .zero { result.frozenSamples += 1 }
            }
            smoother.setTarget(velocity, at: sample.frame.timestamp)
            for i in 1...2 {
                let step = smoother.step(dt: 0.01, now: sample.frame.timestamp + Double(i) * 0.01)
                result.pathX += abs(step.dx)
                result.pathY += abs(step.dy)
            }
        }
        return result
    }

    func testCalibrationFindsTheAxesThisHandUses() throws {
        let axes = try calibration(from: try load())
        XCTAssertGreaterThan(abs(axes.yawAxis.dot(Vec3(0, 0.95, -0.3).normalized)), 0.97)
        XCTAssertGreaterThan(abs(axes.pitchAxis.dot(Vec3(0.84, 0.4, 0.36).normalized)), 0.97)
    }

    func testMovesStayMostlyOnTheirAxis() throws {
        let samples = try load()
        let axes = try calibration(from: samples)
        // The first 1.5 s of each phase is the hand arriving from the previous one.
        let sideways = replay(samples, phase: "slow-yaw", skipping: 75, axes)
        let upDown = replay(samples, phase: "slow-pitch", skipping: 75, axes)
        let fast = replay(samples, phase: "fast", skipping: 75, axes)
        print("REPORT axis", Int(sideways.pathX), Int(sideways.pathY), Int(upDown.pathX), Int(upDown.pathY), Int(fast.pathX), Int(fast.pathY))
        XCTAssertGreaterThan(sideways.pathX, sideways.pathY * 2)
        XCTAssertGreaterThan(upDown.pathY, upDown.pathX * 2)
        XCTAssertGreaterThan(fast.pathX, fast.pathY * 4)
    }

    func testThePointerKeepsMovingWhileTheHandDoes() throws {
        let samples = try load()
        let axes = try calibration(from: samples)
        for phase in ["slow-yaw", "slow-pitch", "fast"] {
            let r = replay(samples, phase: phase, axes)
            print("REPORT frozen", phase, r.frozenSamples, "of", r.movingSamples)
            XCTAssertLessThan(Double(r.frozenSamples), Double(r.movingSamples) * 0.02, phase)
        }
    }

    func testPointingNeverClicks() throws {
        let samples = try load()
        let axes = try calibration(from: samples)
        for phase in ["slow-yaw", "slow-pitch", "fast"] {
            XCTAssertEqual(replay(samples, phase: phase, axes).gestures, [], phase)
        }
    }

    func testRealTapsAndTwistsAreFound() throws {
        let samples = try load()
        let axes = try calibration(from: samples)
        XCTAssertEqual(replay(samples, phase: "taps", axes).gestures, [.tap, .tap, .tap])
        XCTAssertEqual(replay(samples, phase: "twists", axes).gestures.count, 3)
    }
}
