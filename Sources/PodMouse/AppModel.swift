import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreMotion
import PodMouseCore

struct Preferences: Codable, Equatable {
    var mode = ControlMode.hand
    var sensitivity = 1.0
    var tapThreshold = 0.5
    var twistDrags = false
    var invertX = false
    var invertY = false
    var dwellEnabled = false
    var dwellTime = 0.9
    var handCalibration: AxisCalibration?
    var headCalibration: AxisCalibration?
    var hasSeenWelcome = false

    var calibration: AxisCalibration? {
        get { mode == .hand ? handCalibration : headCalibration }
        set {
            if mode == .hand { handCalibration = newValue } else { headCalibration = newValue }
        }
    }

    private static let key = "preferences"

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return stored
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Owns the pipeline: motion frames → screen rates → pointer, gestures and the HUD.
final class AppModel: ObservableObject {
    @Published var prefs = Preferences.load() {
        didSet {
            guard prefs != oldValue else { return }
            prefs.save()
            applyPreferences(previousMode: oldValue.mode)
        }
    }
    @Published private(set) var isOn = false
    @Published private(set) var isPaused = false
    @Published private(set) var isCalibrating = false
    @Published private(set) var hasAccessibility = AXIsProcessTrusted()
    @Published private(set) var motionAuthorization = MotionService.authorization
    @Published private(set) var isReceivingMotion = false
    @Published private(set) var isOnHeadphones = AudioRoute.isOnHeadphones
    @Published private(set) var headphones: HeadphoneInfo?
    @Published private(set) var lastJolt = 0.0

    let airpods: AirPodsScene
    let hud: NotchHUD
    private let ring = DwellRing()
    private let motion = MotionService()
    private let audio = SilentAudio()
    private let stem = StemControls()
    private let pointer = PointerOutput()
    private var hotKeys: [HotKey] = []

    private var calibrator = Calibrator()
    private var mapper: PointerMapper
    private var smoother = PointerSmoother()
    private var gestures: GestureDetector
    private var dwell: DwellTracker
    private var trail: [(time: TimeInterval, point: CGPoint)] = []
    private var timer: DispatchSourceTimer?
    private var healthTimer: Timer?
    private var lastTick: TimeInterval = 0
    private var lastFrameTime: TimeInterval = 0
    private var lastRestart: TimeInterval = 0
    private var joltDecayTime: TimeInterval = 0
    private var ignoresHeadphones = false

    /// A click lands where the pointer was just before the hand or head jolted it.
    private static let handClickLookback: TimeInterval = 0.2
    private static let nodClickLookback: TimeInterval = 0.45
    private static let motionTimeout: TimeInterval = 1.5

    init() {
        let prefs = Preferences.load()
        let airpods = AirPodsScene()
        self.airpods = airpods
        hud = NotchHUD(airpods: airpods)
        mapper = PointerMapper(mode: prefs.mode, sensitivity: prefs.sensitivity)
        mapper.invertX = prefs.invertX
        mapper.invertY = prefs.invertY
        gestures = GestureDetector(mode: prefs.mode, tapThreshold: prefs.tapThreshold)
        dwell = DwellTracker(duration: prefs.dwellTime)

        motion.onFrame = { [weak self] frame in
            guard self?.ignoresHeadphones == false else { return }
            self?.handle(frame)
        }
        motion.onConnectionChange = { [weak self] in self?.handleConnection($0) }
        motion.onError = { [weak self] _ in self?.refreshStatus() }
        stem.onPress = { [weak self] in self?.handle($0) }

        hotKeys = [
            HotKey(id: 1, keyCode: kVK_ANSI_T) { [weak self] in self?.togglePause() },
            HotKey(id: 2, keyCode: kVK_ANSI_C) { [weak self] in self?.centerPointer() },
        ]
        healthTimer = .scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStatus() }
    }

    // MARK: Commands

    var needsCalibration: Bool { prefs.calibration == nil }

    var menuBarSymbol: String {
        !isOn ? "airpods.gen4" : isPaused ? "pause.circle" : "cursorarrow.motionlines"
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        if on { turnOn() } else { turnOff() }
    }

    func togglePause() {
        guard isOn else { return }
        isPaused.toggle()
        smoother.reset()
        pointer.endDrag()
        hud.showStatus(
            title: isPaused ? L("Paused", "Пауза") : L("Pointer on", "Курсор включён"),
            subtitle: "⌃⌥T",
            battery: nil
        )
    }

    func startCalibration() {
        if !isOn { turnOn() }
        calibrator = Calibrator()
        isCalibrating = true
        smoother.reset()
        hud.showCalibration(step: calibrator.step, progress: 0, mode: prefs.mode)
    }

    func cancelCalibration() {
        isCalibrating = false
        hud.hide()
    }

    func requestAccessibility() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        hasAccessibility = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    func openBluetoothSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func switchSoundToHeadphones() {
        AudioRoute.switchToHeadphones()
        refreshStatus()
        if isOn { motion.restart() }
    }

    func centerPointer() {
        guard let screen = NSScreen.main else { return }
        let frame = CGDisplayBounds(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID())
        pointer.warp(to: CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Feeds frames through the same path as real AirPods, which stop being listened to.
    func injectFrame(_ frame: MotionFrame) {
        ignoresHeadphones = true
        handle(frame)
    }

    // MARK: Lifecycle

    private func turnOn() {
        requestAccessibility()
        isOn = true
        isPaused = false
        smoother.reset()
        AudioRoute.switchToHeadphones()
        audio.start()
        motion.start()
        syncStemControls()
        startTicking()
        refreshHeadphones()
        airpods.setLidOpen(true)
        airpods.setLight(on: true)
        refreshStatus()
    }

    private func turnOff() {
        isOn = false
        isCalibrating = false
        isReceivingMotion = false
        pointer.endDrag()
        stopTicking()
        motion.stop()
        stem.stop()
        audio.stop()
        ring.hide()
        hud.hide()
        airpods.setLidOpen(false)
        airpods.setLight(on: false)
        airpods.show(yaw: 0, pitch: 0)
    }

    private func applyPreferences(previousMode: ControlMode) {
        mapper.mode = prefs.mode
        mapper.sensitivity = prefs.sensitivity
        mapper.invertX = prefs.invertX
        mapper.invertY = prefs.invertY
        gestures.mode = prefs.mode
        gestures.tapThreshold = prefs.tapThreshold
        dwell.duration = prefs.dwellTime
        if !prefs.dwellEnabled { ring.hide() }
        if prefs.mode != previousMode {
            isCalibrating = false
            hud.hide()
            pointer.endDrag()
            syncStemControls()
        }
    }

    /// Stem presses only exist with the AirPods out of the case, and claiming Now Playing
    /// takes over the media keys, so it's limited to the mode that uses them.
    private func syncStemControls() {
        if isOn, prefs.mode == .head { stem.start() } else { stem.stop() }
    }

    private func startTicking() {
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: 1.0 / 120)
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func stopTicking() {
        timer?.cancel()
        timer = nil
    }

    // MARK: Motion

    private func handle(_ frame: MotionFrame) {
        lastFrameTime = ProcessInfo.processInfo.systemUptime
        if !isReceivingMotion {
            isReceivingMotion = true
            if !isCalibrating { announceConnection() }
        }

        if isCalibrating {
            if let calibration = calibrator.push(frame) {
                finishCalibration(calibration)
            } else {
                hud.showCalibration(step: calibrator.step, progress: calibrator.progress, mode: prefs.mode, settling: calibrator.isSettling)
                let wave = sin(calibrator.progress * .pi * 6)
                airpods.show(yaw: calibrator.step == .sweepSides ? wave * 28 : 0, pitch: calibrator.step == .sweepUpDown ? wave * 22 : 0)
            }
            return
        }

        guard let calibration = prefs.calibration else { return }
        let rates = calibration.rates(for: frame.rotationRate)
        airpods.follow(yaw: rates.yaw, pitch: rates.pitch, at: frame.timestamp)
        let gesture = gestures.push(frame, rates: rates)
        publishJolt(gestures.lastJolt)
        if let gesture { perform(gesture) }

        guard !isPaused else { return }
        smoother.setTarget(mapper.velocity(for: rates), at: lastFrameTime)
    }

    private func finishCalibration(_ calibration: AxisCalibration) {
        prefs.calibration = calibration
        isCalibrating = false
        hud.showStatus(title: L("All set", "Готово"), subtitle: L("Short, smooth wrist moves work best", "Лучше всего короткие плавные движения кистью"), battery: nil)
    }

    /// The tap meter reads better with a slow fall.
    private func publishJolt(_ jolt: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        if jolt >= lastJolt {
            lastJolt = jolt
            joltDecayTime = now
        } else if now - joltDecayTime > 0.1 {
            lastJolt = max(jolt, lastJolt * 0.8)
        }
    }

    private func perform(_ gesture: Gesture) {
        switch gesture {
        case .shake:
            togglePause()
        case _ where isPaused:
            break
        case .tap:
            pointer.leftClick(at: position(ago: Self.handClickLookback))
        case .nod:
            pointer.leftClick(at: position(ago: Self.nodClickLookback))
        case .twistRight:
            pointer.rightClick(at: position(ago: Self.handClickLookback))
        case .twistLeft:
            if prefs.twistDrags { pointer.toggleDrag() }
        }
    }

    private func handle(_ press: StemControls.Press) {
        switch press {
        case .single where !isPaused: pointer.leftClick(at: pointer.location)
        case .double where !isPaused: pointer.rightClick(at: pointer.location)
        case .triple: togglePause()
        default: break
        }
    }

    private func position(ago seconds: TimeInterval) -> CGPoint {
        let time = ProcessInfo.processInfo.systemUptime - seconds
        return trail.first { $0.time >= time }?.point ?? pointer.location
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - lastTick
        lastTick = now
        guard !isPaused, !isCalibrating, prefs.calibration != nil else { return }

        let step = smoother.step(dt: dt, now: now)
        if step.dx != 0 || step.dy != 0 { pointer.move(dx: step.dx, dy: step.dy) }

        let location = pointer.location
        trail.append((now, location))
        trail.removeAll { now - $0.time > 0.6 }

        guard prefs.dwellEnabled else { return }
        switch dwell.push(x: location.x, y: location.y, time: now) {
        case .idle:
            ring.hide()
        case .settled(let x, let y):
            dwell.targetIsClickable = ClickTarget.exists(at: CGPoint(x: x, y: y))
        case .progress(let progress):
            ring.show(at: location, progress: progress)
        case .fire:
            ring.hide()
            pointer.leftClick(at: location)
        }
    }

    // MARK: Status

    private func handleConnection(_ connected: Bool) {
        refreshStatus()
        if connected {
            refreshHeadphones()
        } else {
            isReceivingMotion = false
            pointer.endDrag()
            hud.showStatus(
                title: L("AirPods disconnected", "AirPods отключены"),
                subtitle: prefs.mode == .hand ? L("Keep the case lid open", "Держите крышку кейса открытой") : nil,
                battery: nil
            )
        }
    }

    private func refreshHeadphones() {
        HeadphoneInfo.readConnected { [weak self] info in
            self?.headphones = info
            if self?.isReceivingMotion == true, self?.isCalibrating == false { self?.announceConnection() }
        }
    }

    private func announceConnection() {
        hud.showStatus(
            title: headphones?.name ?? "AirPods",
            subtitle: L("Connected", "Подключены"),
            battery: headphones?.battery
        )
    }

    private func refreshStatus() {
        hasAccessibility = AXIsProcessTrusted()
        motionAuthorization = MotionService.authorization
        isOnHeadphones = AudioRoute.isOnHeadphones
        guard isOn else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFrameTime > Self.motionTimeout {
            isReceivingMotion = false
            if now - lastRestart > 5 {
                lastRestart = now
                AudioRoute.switchToHeadphones()
                motion.restart()
            }
        }
    }
}
