import AppKit
import Metal
import QuartzCore
import SwiftUI

/// What the light is doing, from the app's live state.
enum AuraMood: Equatable {
    case off, searching, connected, calibrating, paused

    init(isOn: Bool, isPaused: Bool, isCalibrating: Bool, isReceivingMotion: Bool) {
        if !isOn { self = .off }
        else if isCalibrating { self = .calibrating }
        else if isPaused { self = .paused }
        else { self = isReceivingMotion ? .connected : .searching }
    }
}

/// A one-off flash of the light.
enum AuraPulse {
    case tap, rightClick, step, success
}

/// The single light the whole app shares. Every call is cheap and safe from any thread,
/// because the pointer path makes them: a store behind a lock, nothing allocated or dispatched.
final class AuraLight {
    fileprivate struct State {
        var mood = AuraMood.off
        var pulse = AuraPulse.tap
        var pulseTime = -Double.greatestFiniteMagnitude
        var lean = SIMD2<Float>.zero
        var progress: Float = -1
    }

    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var state = State()

    init() { lock.initialize(to: os_unfair_lock()) }
    deinit { lock.deallocate() }

    func set(mood: AuraMood) {
        os_unfair_lock_lock(lock)
        state.mood = mood
        os_unfair_lock_unlock(lock)
    }

    func pulse(_ pulse: AuraPulse) {
        let now = CACurrentMediaTime()
        os_unfair_lock_lock(lock)
        state.pulse = pulse
        state.pulseTime = now
        os_unfair_lock_unlock(lock)
    }

    /// Pushes the light toward where the case is aimed, each axis in -1...1.
    func lean(x: Double, y: Double) {
        os_unfair_lock_lock(lock)
        state.lean = SIMD2(Float(x), Float(y))
        os_unfair_lock_unlock(lock)
    }

    /// Fills the HUD's edge with light, 0...1. Nil turns the arc off.
    func setProgress(_ progress: Double?) {
        os_unfair_lock_lock(lock)
        state.progress = progress.map(Float.init) ?? -1
        os_unfair_lock_unlock(lock)
    }

    fileprivate func read() -> State {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return state
    }
}

/// Where one view draws the light. All in points, origin at the top left.
struct AuraStage: Equatable {
    /// The black notch body with its top edge on the view's top edge, drawn by the renderer so its
    /// spring and its glow stay in step. Nil for no body, as in the menu.
    var notch: CGSize?
    var notchRadius: CGFloat = 24
    /// The soft blob behind the case, in unit coordinates of the view.
    var blobCenter = CGPoint(x: 0.5, y: 0.5)
    var blobRadius: CGFloat = 110
    /// The strength of the blob, 0...1.
    var blobStrength = 1.0
    /// True over black or the desktop: the light adds. False over the light surface: it tints.
    var onDark = true
    /// The strength of the light around the body, 0...1. The body itself stays, so a HUD closing
    /// onto the real notch can fade its glow out as it lands.
    var glow = 1.0
}

extension EnvironmentValues {
    /// True in `--snapshot`, where Metal and SceneKit views are replaced by rendered stills.
    @Entry var stillRendering = false
}

/// The light as a view. It renders on its own thread and only while it's on screen.
struct AuraView: View {
    let light: AuraLight
    var stage = AuraStage()
    /// Called on the main thread when the notch body comes to rest after `stage.notch` got
    /// shorter, whether to a smaller size, to height 0 or to nil. It comes at once if the view
    /// isn't on screen, so a window can always wait for it before ordering out.
    var onSettled: (() -> Void)? = nil

    @Environment(\.stillRendering) private var still
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if still {
                GeometryReader { geometry in
                    if let image = AuraRenderer.still(light: light, stage: stage, size: geometry.size, scale: max(scale, 2)) {
                        Image(nsImage: image).resizable()
                    }
                }
            } else {
                AuraSurface(light: light, stage: stage, onSettled: onSettled)
            }
        }
        .allowsHitTesting(false)
    }
}

enum AuraRenderer {
    /// One frame of the same shader, drawn synchronously, because `ImageRenderer` can't draw a
    /// `CAMetalLayer`. Springs are at their targets, and the same `time` always gives the same
    /// image. `pulse` shows a flash `pulseAge` seconds in.
    static func still(
        light: AuraLight, stage: AuraStage, size: CGSize, scale: CGFloat, settled time: Double = 8,
        pulse: AuraPulse? = nil, pulseAge: Double = 0.14
    ) -> NSImage? {
        guard let gpu = AuraGPU.shared, size.width >= 1, size.height >= 1 else { return nil }
        var state = light.read()
        if let pulse { state.pulse = pulse }
        let frame = AuraFrame(settledOn: state, stage: stage, time: Float(time))
        var uniforms = frame.uniforms(
            size: size, scale: scale, stage: stage, pulse: state.pulse,
            pulseAge: pulse == nil ? .infinity : pulseAge, reduceMotion: false
        )
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard let image = gpu.image(&uniforms, width: width, height: height) else { return nil }
        return NSImage(cgImage: image, size: size)
    }
}

// MARK: Looks

/// Everything a mood sets, kept as plain values so a change of mood can be interpolated.
private struct Look {
    typealias Palette = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

    var palette: Palette
    var speed: Float
    var energy: Float
    var sweep: Float
    var comet: Float = 0
    var breath: Float = 0
    var breathRate: Float = 0
    var narrow: Float = 0

    private static func hue(_ r: Float, _ g: Float, _ b: Float) -> SIMD4<Float> { SIMD4(r, g, b, 1) }
    private static let violet = hue(0.48, 0.36, 1)
    private static let azure = hue(0.18, 0.66, 1)
    private static let mint = hue(0.24, 0.94, 0.78)
    private static let coral = hue(1, 0.36, 0.54)
    private static let amber = hue(1, 0.7, 0.28)
    private static let pearl = hue(0.86, 0.9, 1)
    private static let dusk = hue(0.34, 0.42, 1)
    private static let ember = hue(1, 0.56, 0.22)

    static let off = Look(palette: (pearl, hue(0.8, 0.88, 1), pearl, hue(0.94, 0.86, 0.98), pearl), speed: 0.05, energy: 0.09, sweep: 0.75)
    static let searching = Look(palette: (violet, azure, dusk, violet, azure), speed: 0.3, energy: 0.34, sweep: 0.1, comet: 1, breath: 1, breathRate: 1.5, narrow: 1)
    static let connected = Look(palette: (violet, azure, mint, coral, amber), speed: 0.34, energy: 1, sweep: 1)
    static let calibrating = Look(palette: (azure, mint, azure, mint, violet), speed: 0.85, energy: 0.9, sweep: 1)
    static let paused = Look(palette: (amber, ember, amber, hue(1, 0.62, 0.34), ember), speed: 0.025, energy: 0.3, sweep: 0.42, breath: 1, breathRate: 1.05)

    static func of(_ mood: AuraMood) -> Look {
        switch mood {
        case .off: off
        case .searching: searching
        case .connected: connected
        case .calibrating: calibrating
        case .paused: paused
        }
    }

    /// Moves `amount` of the way to `target`, and says how far there was to go.
    mutating func approach(_ target: Look, _ amount: Float) -> Float {
        var left: Float = 0
        func move(_ value: inout SIMD4<Float>, _ goal: SIMD4<Float>) {
            left = max(left, (goal - value).max(), (value - goal).max())
            value += (goal - value) * amount
        }
        func move(_ value: inout Float, _ goal: Float) {
            left = max(left, abs(goal - value))
            value += (goal - value) * amount
        }
        move(&palette.0, target.palette.0)
        move(&palette.1, target.palette.1)
        move(&palette.2, target.palette.2)
        move(&palette.3, target.palette.3)
        move(&palette.4, target.palette.4)
        move(&speed, target.speed)
        move(&energy, target.energy)
        move(&sweep, target.sweep)
        move(&comet, target.comet)
        move(&breath, target.breath)
        move(&breathRate, target.breathRate)
        move(&narrow, target.narrow)
        return left
    }
}

/// Mirrors `Uniforms` in Aura.metal.
private struct AuraUniforms {
    var size: SIMD4<Float>
    var notch: SIMD4<Float>
    var flow: SIMD4<Float>
    var comet: SIMD4<Float>
    var blob: SIMD4<Float>
    var lean: SIMD4<Float>
    var pulse: SIMD4<Float>
    var pulseColor: SIMD4<Float>
    var palette: Look.Palette
}

// MARK: Motion

/// The light's smoothed state, advanced once per frame. A still builds one settled instead,
/// so the two can't disagree.
private struct AuraFrame {
    private static let pulseLength = 0.6
    private static let cometRate: Float = 0.38
    /// Reduce Motion freezes the flow here, and every other phase starts here.
    private static let startPhase: Float = 7

    var look: Look
    var phase = startPhase
    var breathPhase: Float = 0
    var cometPhase: Float = 0
    var notchWidth: Float = 0
    var notchHeight: Float = 0
    var notchRadius: Float = 24
    var widthSpeed: Float = 0
    var heightSpeed: Float = 0
    var lastWidth: Float = 0
    var lean = SIMD2<Float>.zero
    var blob: SIMD4<Float>
    var onDark: Float
    var glow: Float
    var arc: Float = 0
    var progress: Float = 0

    init(look: Look, stage: AuraStage) {
        self.look = look
        blob = Self.blobTarget(stage)
        onDark = stage.onDark ? 1 : 0
        glow = Float(stage.glow)
    }

    /// The state a long-running frame would reach at `time`.
    init(settledOn state: AuraLight.State, stage: AuraStage, time: Float) {
        self.init(look: Look.of(state.mood), stage: stage)
        phase = Self.startPhase + time * look.speed
        breathPhase = time * look.breathRate
        cometPhase = 0.3 + time * Self.cometRate
        settle(stage: stage, state: state)
    }

    /// Takes the targets without animating, for a view that wasn't on screen to watch them change.
    mutating func settle(stage: AuraStage, state: AuraLight.State) {
        look = Look.of(state.mood)
        blob = Self.blobTarget(stage)
        onDark = stage.onDark ? 1 : 0
        glow = Float(stage.glow)
        lean = state.lean
        arc = state.progress >= 0 ? 1 : 0
        if state.progress >= 0 { progress = state.progress }
        let size = Self.notchTarget(stage)
        if size.y > 0 { lastWidth = size.x }
        notchWidth = size.y > 0 ? size.x : lastWidth * Self.tuckedWidth
        notchHeight = size.y
        notchRadius = Float(stage.notchRadius)
        widthSpeed = 0
        heightSpeed = 0
    }

    /// With no real notch to land on, the body narrows as it slides up off the screen.
    private static let tuckedWidth: Float = 0.72

    private static func blobTarget(_ stage: AuraStage) -> SIMD4<Float> {
        SIMD4(Float(stage.blobCenter.x), Float(stage.blobCenter.y), Float(stage.blobRadius), Float(stage.blobStrength))
    }

    private static func notchTarget(_ stage: AuraStage) -> SIMD2<Float> {
        guard let notch = stage.notch, notch.height > 0 else { return .zero }
        return SIMD2(Float(notch.width), Float(notch.height))
    }

    private static func spring(_ value: inout Float, _ speed: inout Float, to target: Float, over seconds: Float) {
        let omega: Float = 2 * .pi / 0.45
        let damping: Float = 0.8
        var left = seconds
        while left > 0 {
            let step = min(left, 1 / 240)
            speed += (omega * omega * (target - value) - 2 * damping * omega * speed) * step
            value += speed * step
            left -= step
        }
    }

    /// Picks up a window coming back: the body may spring open, but it doesn't play a change
    /// that happened off screen.
    mutating func resume(stage: AuraStage, state: AuraLight.State) {
        let height = notchHeight, width = notchWidth
        settle(stage: stage, state: state)
        if height < notchHeight {
            notchWidth = height < 1 ? notchWidth * Self.tuckedWidth : width
            notchHeight = height
        }
    }

    /// Advances by `dt` seconds. Returns true while anything is still on its way to a target,
    /// apart from the steady flow. `notchAtRest` is set when the body has stopped.
    mutating func advance(dt: Float, state: AuraLight.State, stage: AuraStage, now: Double, reduceMotion: Bool, notchAtRest: inout Bool) -> Bool {
        let target = Look.of(state.mood)
        let moodLeft = look.approach(target, 1 - exp(-dt / (reduceMotion ? 0.22 : 0.32)))
        if moodLeft < 0.003 { look = target }

        if !reduceMotion {
            phase += dt * look.speed
            breathPhase += dt * look.breathRate
            cometPhase += dt * Self.cometRate
        }

        let glide = 1 - exp(-dt / 0.18)
        let blobGoal = Self.blobTarget(stage)
        let blobLeft = max((blobGoal - blob).max(), (blob - blobGoal).max())
        blob = blobLeft < 0.002 ? blobGoal : blob + (blobGoal - blob) * glide
        let darkGoal: Float = stage.onDark ? 1 : 0
        let darkLeft = abs(darkGoal - onDark)
        onDark = darkLeft < 0.004 ? darkGoal : onDark + (darkGoal - onDark) * glide
        let glowGoal = Float(stage.glow)
        let glowLeft = abs(glowGoal - glow)
        glow = glowLeft < 0.004 ? glowGoal : glow + (glowGoal - glow) * glide

        let leanLeft = max((state.lean - lean).max(), (lean - state.lean).max())
        lean = leanLeft < 0.002 ? state.lean : lean + (state.lean - lean) * (1 - exp(-dt / 0.1))

        let arcGoal: Float = state.progress >= 0 ? 1 : 0
        let arcLeft = abs(arcGoal - arc)
        arc = arcLeft < 0.004 ? arcGoal : arc + (arcGoal - arc) * glide
        var progressLeft: Float = 0
        if state.progress >= 0 {
            progressLeft = abs(state.progress - progress)
            progress = progressLeft < 0.0005 ? state.progress : progress + (state.progress - progress) * (1 - exp(-dt / 0.08))
        }

        let goal = Self.notchTarget(stage)
        if goal.y > 0 { lastWidth = goal.x }
        let widthGoal = goal.y > 0 ? goal.x : lastWidth * Self.tuckedWidth
        if notchHeight < 1, heightSpeed == 0 { notchWidth = max(notchWidth, widthGoal * Self.tuckedWidth) }
        notchRadius += (Float(stage.notchRadius) - notchRadius) * glide
        if reduceMotion {
            let ease = 1 - exp(-dt / 0.06)
            notchWidth += (widthGoal - notchWidth) * ease
            notchHeight += (goal.y - notchHeight) * ease
        } else {
            Self.spring(&notchWidth, &widthSpeed, to: widthGoal, over: dt)
            Self.spring(&notchHeight, &heightSpeed, to: goal.y, over: dt)
        }
        notchAtRest = abs(widthGoal - notchWidth) < 0.25 && abs(goal.y - notchHeight) < 0.25
            && abs(widthSpeed) < 3 && abs(heightSpeed) < 3
        if notchAtRest {
            notchWidth = widthGoal
            notchHeight = goal.y
            widthSpeed = 0
            heightSpeed = 0
        }

        let pulsing = now - state.pulseTime < Self.pulseLength + 0.05
        return !notchAtRest || pulsing || moodLeft >= 0.003 || blobLeft >= 0.002 || darkLeft >= 0.004 || glowLeft >= 0.004
            || leanLeft >= 0.002 || arcLeft >= 0.004 || progressLeft >= 0.0005
    }

    func uniforms(size: CGSize, scale: CGFloat, stage: AuraStage, pulse: AuraPulse, pulseAge: Double, reduceMotion: Bool) -> AuraUniforms {
        let height = max(notchHeight, 0)
        let halfWidth = notchWidth / 2
        let radius = max(min(notchRadius, min(height, halfWidth)), 0.01)
        let opened = min(height / 22, 1)
        let openness = opened * opened * (3 - 2 * opened) * glow

        let unit = Float(max(pulseAge, 0) / Self.pulseLength)
        var envelope: Float = 0
        var ring: Float = -1
        if unit < 1 {
            let left = 1 - unit
            if reduceMotion {
                // No ripple, only a soft rise and fall of brightness.
                envelope = min(unit / 0.2, 1) * left * 0.5
            } else {
                envelope = pow(left, 2.2)
                ring = 1 - left * left * left
            }
        }
        var color = SIMD4<Float>(1, 1, 1, 2)
        var bloom: Float = 0
        var spectrum: Float = 0
        switch pulse {
        case .tap: break
        case .rightClick: color = SIMD4(1, 0.36, 0.54, 2.4)
        case .step: color = SIMD4(0.21, 0.82, 0.9, 1.6)
        case .success:
            bloom = envelope
            spectrum = 1
            color = SIMD4(1, 1, 1, 1.4)
        }

        return AuraUniforms(
            size: SIMD4(Float(size.width), Float(size.height), Float(scale), onDark),
            notch: SIMD4(halfWidth, height, radius, openness),
            flow: SIMD4(phase, look.energy, look.sweep, look.breath * sin(breathPhase)),
            comet: SIMD4(look.comet, -1.25 + 2.5 * (cometPhase - cometPhase.rounded(.down)), arc, progress),
            blob: SIMD4(blob.x * Float(size.width), blob.y * Float(size.height), blob.z, blob.w),
            lean: SIMD4(lean.x, lean.y, look.narrow, stage.notch == nil ? 0 : 1),
            pulse: SIMD4(envelope, ring, bloom, spectrum),
            pulseColor: color,
            palette: look.palette
        )
    }
}

// MARK: GPU

/// The device and pipeline, shared by all views. The first touch compiles the shader, so a view
/// makes that touch on the render thread.
private final class AuraGPU {
    static let shared: AuraGPU? = AuraGPU()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let url = Bundle.main.url(forResource: "Aura", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "auraVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "auraFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("Aura: shader failed: \(error)")
            return nil
        }
        self.device = device
        self.queue = queue
    }

    private func encode(_ uniforms: inout AuraUniforms, to texture: MTLTexture, on buffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AuraUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    func draw(_ uniforms: inout AuraUniforms, to layer: CAMetalLayer) {
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        encode(&uniforms, to: drawable.texture, on: buffer)
        buffer.present(drawable)
        buffer.commit()
    }

    func image(_ uniforms: inout AuraUniforms, width: Int, height: Int) -> CGImage? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        let bytesPerRow = width * 4
        guard let texture = device.makeTexture(descriptor: descriptor),
              let pixels = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let buffer = queue.makeCommandBuffer() else { return nil }
        encode(&uniforms, to: texture, on: buffer)
        guard let blit = buffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: pixels, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height
        )
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let provider = CGDataProvider(data: Data(bytes: pixels.contents(), count: bytesPerRow * height) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

// MARK: Render thread

/// One thread for all views, with a run loop for their display links. The main thread also
/// runs the 120 Hz pointer timer, so nothing per-frame may happen there.
private enum AuraThread {
    private static let loop: CFRunLoop = {
        let ready = DispatchSemaphore(value: 0)
        var loop: CFRunLoop?
        let thread = Thread {
            loop = CFRunLoopGetCurrent()
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        thread.name = "Aura"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return loop!
    }()

    static func run(_ work: @escaping () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(loop)
    }
}

/// Draws one view. `tick` runs on the render thread. The rest is what the view hands over,
/// under the lock.
private final class AuraEngine: NSObject {
    private enum Pace {
        case idle, steady, active

        var range: CAFrameRateRange {
            switch self {
            case .idle: CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
            case .steady: CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
            case .active: CAFrameRateRange(minimum: 45, maximum: 60, preferred: 60)
            }
        }
    }

    /// Set once before the first tick.
    var onRest: (() -> Void)?

    private let light: AuraLight
    private let layer: CAMetalLayer

    private let lock = NSLock()
    private var stage: AuraStage
    private var size = CGSize.zero
    private var scale: CGFloat = 2
    private var reduceMotion = false
    private var shrinkPending = false
    private var resuming = true

    // Render thread only.
    private var frame: AuraFrame
    private var lastTime: Double = 0
    private var drawnSize = CGSize.zero
    private var pace: Pace?
    private var needsDraw = true

    init(light: AuraLight, stage: AuraStage, layer: CAMetalLayer) {
        self.light = light
        self.stage = stage
        self.layer = layer
        frame = AuraFrame(look: .of(light.read().mood), stage: stage)
        super.init()
    }

    /// Returns true if the body got shorter off screen, where no spring will ever finish it.
    func set(stage: AuraStage, running: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = self.stage.notch?.height ?? 0
        let after = stage.notch?.height ?? 0
        self.stage = stage
        if after > before { shrinkPending = false }
        guard after < before else { return false }
        shrinkPending = running
        return !running
    }

    func set(size: CGSize, scale: CGFloat) {
        lock.lock()
        self.size = size
        self.scale = scale
        lock.unlock()
    }

    func set(reduceMotion: Bool) {
        lock.lock()
        self.reduceMotion = reduceMotion
        lock.unlock()
    }

    /// Returns true if the body was on its way and now won't get there.
    func pause() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let abandoned = shrinkPending
        shrinkPending = false
        resuming = true
        return abandoned
    }

    @objc func tick(_ link: CADisplayLink) {
        autoreleasepool {
            lock.lock()
            let stage = self.stage
            let size = self.size
            let scale = self.scale
            let reduceMotion = self.reduceMotion
            let shrinking = shrinkPending
            let resumed = resuming
            resuming = false
            lock.unlock()
            guard size.width >= 1, size.height >= 1, let gpu = AuraGPU.shared else { return }

            let state = light.read()
            let now = link.targetTimestamp
            let dt = resumed ? 1.0 / 60 : min(max(now - lastTime, 0.001), 1.0 / 15)
            lastTime = now
            if layer.device == nil { layer.device = gpu.device }
            if resumed {
                frame.resume(stage: stage, state: state)
                needsDraw = true
            }

            var notchAtRest = false
            let moving = frame.advance(dt: Float(dt), state: state, stage: stage, now: now, reduceMotion: reduceMotion, notchAtRest: &notchAtRest)
            if shrinking, notchAtRest { finishShrink() }

            let wanted: Pace = moving ? .active : (reduceMotion ? .idle : .steady)
            if wanted != pace {
                pace = wanted
                link.preferredFrameRateRange = wanted.range
            }

            if size != drawnSize {
                drawnSize = size
                needsDraw = true
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.drawableSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
                CATransaction.commit()
            }
            // With Reduce Motion nothing flows, so a picture that isn't changing needs no new frames.
            guard moving || !reduceMotion || needsDraw else { return }
            needsDraw = moving
            var uniforms = frame.uniforms(
                size: size, scale: scale, stage: stage, pulse: state.pulse,
                pulseAge: now - state.pulseTime, reduceMotion: reduceMotion
            )
            gpu.draw(&uniforms, to: layer)
        }
    }

    private func finishShrink() {
        lock.lock()
        let fire = shrinkPending
        shrinkPending = false
        lock.unlock()
        if fire, let onRest { DispatchQueue.main.async(execute: onRest) }
    }
}

// MARK: View

private struct AuraSurface: NSViewRepresentable {
    let light: AuraLight
    let stage: AuraStage
    let onSettled: (() -> Void)?

    func makeNSView(context: Context) -> AuraLayerView {
        AuraLayerView(light: light, stage: stage)
    }

    func updateNSView(_ view: AuraLayerView, context: Context) {
        view.onSettled = onSettled
        view.update(stage: stage)
    }

    static func dismantleNSView(_ view: AuraLayerView, coordinator: ()) {
        view.stop()
    }
}

/// Backed by the Metal layer. Keeps the display link running only while the window is visible.
private final class AuraLayerView: NSView {
    var onSettled: (() -> Void)?

    private let metal = CAMetalLayer()
    private let engine: AuraEngine
    private var link: CADisplayLink?
    private var running = false
    private var accessibilityWatch: NSObjectProtocol?

    init(light: AuraLight, stage: AuraStage) {
        engine = AuraEngine(light: light, stage: stage, layer: metal)
        super.init(frame: .zero)
        metal.pixelFormat = .bgra8Unorm
        metal.isOpaque = false
        metal.framebufferOnly = true
        metal.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        engine.onRest = { [weak self] in self?.onSettled?() }
        engine.set(reduceMotion: Theme.reduceMotion)
        accessibilityWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [engine] _ in engine.set(reduceMotion: Theme.reduceMotion) }
        AuraThread.run { _ = AuraGPU.shared }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        stop()
        if let accessibilityWatch { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityWatch) }
    }

    override func makeBackingLayer() -> CALayer { metal }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(stage: AuraStage) {
        if engine.set(stage: stage, running: running) {
            DispatchQueue.main.async { [weak self] in self?.onSettled?() }
        }
    }

    func stop() {
        pause()
        guard let link else { return }
        self.link = nil
        AuraThread.run { link.invalidate() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        publishSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        publishSize()
    }

    private var windowWatch: WindowWatch?

    private func publishSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metal.contentsScale = scale
        engine.set(size: bounds.size, scale: scale)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowWatch = window.map { WindowWatch($0) { [weak self] in self?.visibilityChanged() } }
        publishSize()
        visibilityChanged()
    }

    override func viewDidHide() {
        super.viewDidHide()
        visibilityChanged()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityChanged()
    }

    private func visibilityChanged() {
        let visible = WindowWatch.shows(window) && !isHiddenOrHasHiddenAncestor
        if visible { resume() } else { pause() }
    }

    private func resume() {
        guard !running else { return }
        running = true
        if let link {
            AuraThread.run { link.isPaused = false }
            return
        }
        let link = displayLink(target: engine, selector: #selector(AuraEngine.tick))
        self.link = link
        AuraThread.run { link.add(to: .current, forMode: .default) }
    }

    private func pause() {
        guard running else { return }
        running = false
        if let link { AuraThread.run { link.isPaused = true } }
        if engine.pause() { onSettled?() }
    }
}
