import AppKit
import CoreGraphics
import PodMouseCore
import SwiftUI

/// Developer entry points that exercise the app without AirPods:
/// `--snapshot <dir>` renders the UI to PNGs, `--simulate` drives the real pipeline with
/// synthetic motion, and `--probe` reports what the AirPods are actually sending.
/// The last two touch Motion, so launch them with `open`: macOS kills a directly run binary.
final class Diagnostics {
    private enum Task {
        case snapshot(URL)
        case simulate
        case probe(seconds: Double)
        case record(URL)
    }

    private let task: Task
    private let model: AppModel
    private var timer: Timer?
    private var probe: MotionService?

    init?(arguments: [String], model: AppModel) {
        self.model = model
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            task = .snapshot(URL(fileURLWithPath: arguments[index + 1]))
        } else if arguments.contains("--simulate") {
            task = .simulate
        } else if let index = arguments.firstIndex(of: "--record"), index + 1 < arguments.count {
            task = .record(URL(fileURLWithPath: arguments[index + 1]))
        } else if let index = arguments.firstIndex(of: "--probe") {
            let seconds = arguments.dropFirst(index + 1).first.flatMap(Double.init)
            task = .probe(seconds: seconds ?? 20)
        } else {
            return nil
        }
    }

    func run() {
        switch task {
        case .snapshot(let directory): MainActor.assumeIsolated { snapshot(to: directory) }
        case .simulate: simulate()
        case .probe(let seconds): runProbe(seconds: seconds)
        case .record(let file): record(to: file)
        }
    }

    private func report(_ line: String) {
        print(line)
        fflush(stdout)
    }

    // MARK: Snapshot

    /// Every screen in both appearances, with stills standing in for the Metal and SceneKit layers.
    @MainActor private func snapshot(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func write(_ image: NSImage?, _ name: String) {
            guard let tiff = image?.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: directory.appendingPathComponent("\(name).png"))
        }
        func render<V: View>(_ view: V, _ name: String, scheme: ColorScheme) {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).environment(\.stillRendering, true))
            renderer.scale = 2
            write(renderer.nsImage, name)
        }
        let airpods = model.airpods
        let light = model.light
        let moods: [(String, AuraMood)] = [("off", .off), ("searching", .searching), ("connected", .connected), ("calibrating", .calibrating), ("paused", .paused)]

        for (schemeName, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            for (name, mood) in moods {
                light.set(mood: mood)
                airpods.setMood(mood)
                airpods.setLidOpen(mood != .off, animated: false)
                airpods.setLight(on: mood != .off)
                render(MenuView(model: model).background(.surface), "menu-\(name)-\(schemeName)", scheme: scheme)
            }
            render(WelcomeView(model: model) {}.background(.surface), "welcome-\(schemeName)", scheme: scheme)
        }

        let hud = HUDState()
        hud.notchHeight = 37
        let wallpapers: [(String, Color)] = [("onlight", Color(white: 0.88)), ("ondark", Color(white: 0.16))]
        let states: [(String, HUDContent, AuraMood)] = [
            ("status", .status(title: "AirPods 4", subtitle: L("Connected", "Подключены"), battery: 86), .connected),
            ("disconnected", .status(title: L("AirPods disconnected", "AirPods отключены"), subtitle: L("Keep the case lid open", "Держите крышку кейса открытой"), battery: nil), .searching),
            ("paused", .status(title: L("Paused", "Пауза"), subtitle: "⌃⌥T", battery: nil), .paused),
            ("calibration-still", .calibration(step: .holdStill, progress: 0.5, mode: .hand, settling: false), .calibrating),
            ("calibration-sides", .calibration(step: .sweepSides, progress: 0.6, mode: .hand, settling: false), .calibrating),
            ("calibration-updown", .calibration(step: .sweepUpDown, progress: 0.3, mode: .head, settling: false), .calibrating),
        ]
        for (wallpaperName, wallpaper) in wallpapers {
            for (name, content, mood) in states {
                light.set(mood: mood)
                airpods.setMood(mood)
                hud.content = content
                light.setProgress(HUDView.progress(of: content))
                render(HUDView(state: hud, airpods: airpods, light: light).frame(width: NotchHUD.size.width, height: NotchHUD.size.height).background(wallpaper), "hud-\(name)-\(wallpaperName)", scheme: .dark)
            }
        }
        light.setProgress(nil)

        write(ClickRipple.still(pulse: .tap), "ripple-tap")
        write(ClickRipple.still(pulse: .rightClick), "ripple-right")
        write(DwellRing.still(progress: 0.65), "dwell-ring")

        airpods.setMood(.connected)
        airpods.setLidOpen(false, animated: false)
        write(airpods.snapshot(side: 800), "3d-closed")
        airpods.setLidOpen(true, animated: false)
        airpods.setLight(on: true)
        write(airpods.snapshot(side: 800), "3d-open")
        write(airpods.snapshot(side: 400, framing: .hudStatus), "3d-hud-status")
        write(airpods.snapshot(side: 400, framing: .hudCalibration), "3d-hud-calibration")
        report("snapshots: \(directory.path)")
        NSApp.terminate(nil)
    }

    // MARK: Simulation

    /// Calibration sweeps with a device-aligned axis each, then a move right and a move up.
    /// Prints where the pointer went.
    private func simulate() {
        let savedPreferences = model.prefs
        model.prefs.mode = .hand
        model.prefs.dwellEnabled = false
        model.startCalibration()

        var startLocation = CGPoint.zero
        var time = ProcessInfo.processInfo.systemUptime
        var elapsed = 0.0
        var started = false
        let interval = 0.02

        timer = .scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { return }
            elapsed += interval
            time += interval
            let rate: Vec3
            switch elapsed {
            case ..<1.0: rate = .zero
            case ..<6.5: rate = Vec3(0, 1, 0) * (70 * cos((elapsed - 1) * 2.5) * .pi / 180)
            case ..<7.5: rate = .zero
            case ..<13.0: rate = Vec3(1, 0, 0) * (70 * cos((elapsed - 7.5) * 2.5) * .pi / 180)
            case ..<13.5: rate = .zero
            case ..<14.5:
                if !started {
                    started = true
                    startLocation = CGEvent(source: nil)?.location ?? .zero
                }
                rate = Vec3(0, 60 * .pi / 180, 0)
            case ..<15.5: rate = Vec3(50 * .pi / 180, 0, 0)
            default:
                timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.finishSimulation(from: startLocation)
                    self.model.prefs = savedPreferences
                    NSApp.terminate(nil)
                }
                return
            }
            self.model.injectFrame(MotionFrame(timestamp: time, rotationRate: rate))
        }
    }

    private func finishSimulation(from start: CGPoint) {
        let end = CGEvent(source: nil)?.location ?? .zero
        report("calibrated: \(!model.needsCalibration)  still calibrating: \(model.isCalibrating)  paused: \(model.isPaused)")
        report("can post events: \(CGPreflightPostEventAccess())")
        report("accessibility: \(model.hasAccessibility)")
        report(String(format: "pointer moved: dx=%.1f dy=%.1f", end.x - start.x, end.y - start.y))
    }

    // MARK: Recording

    /// Guides a person through labelled moves in the notch and saves the raw sensor stream as CSV.
    private func record(to file: URL) {
        let phases: [(id: String, title: String, detail: String, seconds: Int)] = [
            ("prep", L("Get ready", "Приготовьтесь"), L(
                "Lid open, AirPods inside. Hold the case like a TV remote, with the light facing the screen.",
                "Крышка открыта, наушники внутри. Держите кейс как пульт от телевизора: сторона со светодиодом смотрит на экран."
            ), 12),
            ("rest", L("Hold still", "Замрите"), L(
                "Aim the case at the screen and don't move.",
                "Направьте кейс на экран и держите неподвижно."
            ), 6),
            ("slow-yaw", L("Slowly left and right", "Медленно влево и вправо"), L(
                "Like a laser pointer: glide from the left edge of the screen to the right and back.",
                "Как лазерной указкой: плавно ведите от левого края экрана к правому и обратно."
            ), 10),
            ("slow-pitch", L("Slowly up and down", "Медленно вверх и вниз"), L(
                "Glide from the bottom edge of the screen to the top and back.",
                "Плавно ведите от нижнего края экрана к верхнему и обратно."
            ), 10),
            ("fast", L("Fast left and right", "Быстро влево и вправо"), L(
                "Sweep quickly from edge to edge, as if crossing the screen in a hurry.",
                "Резко ведите от края до края, как будто быстро переводите курсор через весь экран."
            ), 6),
            ("taps", L("Five taps", "Пять тапов"), L(
                "Keep the case still and tap it 5 times with a finger, about a second apart.",
                "Держите кейс неподвижно и 5 раз стукните по нему пальцем, с паузой около секунды."
            ), 9),
            ("twists", L("Three twists", "Три поворота кисти"), L(
                "Three times: twist your wrist sharply to the right and back, like a screwdriver.",
                "Три раза резко поверните кисть вправо и верните обратно, как отвёрткой."
            ), 8),
            ("ajar", L("Almost close the lid", "Почти закройте крышку"), L(
                "Leave a gap of 2–3 mm, hold it with a finger so it doesn't snap shut, and move the case.",
                "Оставьте щель 2–3 мм, придержите пальцем, чтобы крышка не защёлкнулась, и двигайте кейс."
            ), 10),
            ("closed", L("Close the lid", "Закройте крышку"), L(
                "Close it until it clicks and keep moving the case.",
                "Закройте до щелчка и продолжайте двигать кейс."
            ), 8),
        ]
        var lines = ["phase,t,rx,ry,rz,gx,gy,gz,ax,ay,az,qw,qx,qy,qz,sensor"]
        var phase = 0
        var left = phases[0].seconds
        var phaseFrames = 0

        let service = MotionService()
        service.onRawMotion = { motion in
            phaseFrames += 1
            let r = motion.rotationRate, g = motion.gravity, a = motion.userAcceleration, q = motion.attitude.quaternion
            let values = [motion.timestamp, r.x, r.y, r.z, g.x, g.y, g.z, a.x, a.y, a.z, q.w, q.x, q.y, q.z]
                .map { String(format: "%.5f", $0) }.joined(separator: ",")
            lines.append("\(phases[phase].id),\(values),\(motion.sensorLocation.rawValue)")
        }
        service.onConnectionChange = { [weak self] connected in
            self?.report("\(phases[phase].id): connection \(connected)")
            lines.append("event-\(connected ? "connected" : "disconnected"),\(ProcessInfo.processInfo.systemUptime),,,,,,,,,,,,,,")
        }
        report("switched sound to AirPods: \(AudioRoute.switchToHeadphones())")
        let audio = SilentAudio()
        audio.start()
        service.start()
        probe = service

        let guide = RecordingGuide()
        let showPhase = {
            let current = phases[phase]
            guide.show(step: phase + 1, total: phases.count, title: current.title, detail: current.detail, left: left, duration: current.seconds)
        }
        showPhase()

        timer = .scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { return }
            left -= 1
            guard left <= 0 else { return showPhase() }
            self.report("\(phases[phase].id): \(phaseFrames) frames")
            phaseFrames = 0
            phase += 1
            if phase < phases.count {
                left = phases[phase].seconds
                showPhase()
            } else {
                timer.invalidate()
                guide.hide()
                try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
                audio.stop()
                self.report("saved \(lines.count - 1) rows")
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: Probe

    /// The hardware truth test: run it with the case in hand, then with the AirPods worn.
    private func runProbe(seconds: Double) {
        let service = MotionService()
        var frames = 0
        var maxRate = 0.0
        var maxAcceleration = 0.0
        service.onFrame = { frame in
            frames += 1
            maxRate = max(maxRate, frame.rotationRate.length)
            maxAcceleration = max(maxAcceleration, frame.userAcceleration.length)
        }
        service.onConnectionChange = { [weak self] in self?.report("connection: \($0)") }
        service.onError = { [weak self] in self?.report("error: \($0)") }

        report("switched sound to AirPods: \(AudioRoute.switchToHeadphones())")
        let audio = SilentAudio()
        audio.start()
        service.start()
        probe = service
        report("output: \(AudioRoute.currentOutputName ?? "none")")
        report("authorization: \(MotionService.authorization.rawValue)")
        report("Move the AirPods for \(Int(seconds)) seconds…")

        var left = seconds
        timer = .scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            left -= 1
            let output = AudioRoute.currentOutputName ?? "none"
            self?.report(String(format: "%3d frames/s  peak rotation %.2f rad/s  peak acceleration %.2f g  output: ", frames, maxRate, maxAcceleration) + output)
            frames = 0
            maxRate = 0
            maxAcceleration = 0
            if left <= 0 {
                timer.invalidate()
                audio.stop()
                NSApp.terminate(nil)
            }
        }
    }
}
