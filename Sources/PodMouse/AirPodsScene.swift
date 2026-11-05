import AppKit
import os
import PodMouseCore
import SceneKit
import SwiftUI

/// The case and earbuds as a live 3D object, from the same model as the website.
/// Everything in the app that shows AirPods shows this scene.
final class AirPodsScene {
    let scene = SCNScene()
    private let light: AuraLight

    private let floatNode = SCNNode()
    private let poseNode = SCNNode()
    private let lidNode = SCNNode()
    private let ledMaterial = SCNMaterial()
    private let ledGlow = SCNNode()
    private let rimLights = [SCNLight(), SCNLight()]
    private let heroCamera = SCNNode()
    private let hudCamera = SCNNode()
    /// SceneKit's render thread holds the scene lock for most of a frame, so a change made on
    /// main waits for it, and main is where the 120 Hz pointer runs. Changes are made here.
    private let queue = DispatchQueue(label: "scene", qos: .userInteractive)
    private let pose = OSAllocatedUnfairLock(initialState: PendingPose())
    private var shell: [SCNMaterial] = []
    private var flares: [SCNMaterial] = []
    private var mood = AuraMood.off
    private var motionWatch: NSObjectProtocol?
    private var yaw = 0.0
    private var pitch = 0.0
    private var followTime: TimeInterval?

    private struct PendingPose {
        var angles = AirPodsScene.restingTilt
        var isQueued = false
    }

    private static let openLidAngle = 1.9
    private static let flareMask = 2
    /// A three-quarter view, so it reads as an object at any size.
    private static let restingTilt = SCNVector3(0.2, -0.42, 0)
    private static let followLimit = 40.0
    /// Seconds for the on-screen case to drift back to its resting pose.
    private static let followReturn = 1.6

    init(light: AuraLight) {
        self.light = light
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = Self.studioLighting()
        scene.lightingEnvironment.intensity = 0.85
        addRimLight(rimLights[0], euler: SCNVector3(-0.25, -2.5, 0))
        addRimLight(rimLights[1], euler: SCNVector3(-0.25, 2.5, 0))

        for (node, framing) in [(heroCamera, AirPodsFraming.hero), (hudCamera, .hudStatus)] {
            let shot = Self.shot(of: framing)
            node.camera = Self.camera(fieldOfView: shot.fieldOfView)
            node.position = shot.position
            scene.rootNode.addChildNode(node)
        }

        scene.rootNode.addChildNode(floatNode)
        floatNode.addChildNode(poseNode)
        poseNode.eulerAngles = Self.restingTilt
        buildModel()
        apply(.off, animated: false)
        applyMotionPreference()
        motionWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.change { self?.applyMotionPreference() } }
    }

    private static func camera(fieldOfView: CGFloat) -> SCNCamera {
        let camera = SCNCamera()
        camera.projectionDirection = .vertical
        camera.fieldOfView = fieldOfView
        camera.zNear = 20
        camera.zFar = 1600
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = 0.7
        camera.whitePoint = 2.5
        camera.minimumExposure = -2
        camera.maximumExposure = 2
        camera.bloomIntensity = 0.08
        camera.bloomThreshold = 1.4
        camera.bloomBlurRadius = 5
        return camera
    }

    private func addRimLight(_ light: SCNLight, euler: SCNVector3) {
        light.type = .directional
        light.intensity = 0
        let node = SCNNode()
        node.light = light
        node.eulerAngles = euler
        scene.rootNode.addChildNode(node)
    }

    func camera(for framing: AirPodsFraming) -> SCNNode { framing == .hero ? heroCamera : hudCamera }

    private func change(_ work: @escaping () -> Void) {
        queue.async {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            work()
            SCNTransaction.commit()
        }
    }

    /// Glides the HUD's camera between its framings, which the HUD's one view shares.
    func frameHUD(_ framing: AirPodsFraming) {
        guard framing != .hero else { return }
        let position = Self.shot(of: framing).position
        change { [hudCamera] in
            // At 52 pt a flare's length would run across the text beside the case.
            hudCamera.camera?.categoryBitMask = framing == .hudStatus ? ~Self.flareMask : -1
            SCNTransaction.animationDuration = Theme.reduceMotion ? 0 : 0.45
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            hudCamera.position = position
        }
    }

    func setLidOpen(_ open: Bool, animated: Bool = true) {
        let angle = open ? -Self.openLidAngle : 0
        change { [lidNode] in
            lidNode.removeAllActions()
            guard animated, !Theme.reduceMotion else {
                lidNode.eulerAngles.x = CGFloat(angle)
                return
            }
            let swing = SCNAction.rotateTo(x: CGFloat(angle), y: 0, z: 0, duration: 0.7, usesShortestUnitArc: true)
            swing.timingMode = .easeInEaseOut
            lidNode.runAction(swing)
        }
    }

    func setLight(on: Bool) {
        change { [ledMaterial, ledGlow] in
            ledMaterial.emission.contents = NSColor(red: 0.2, green: 1, blue: 0.48, alpha: 1).withAlphaComponent(on ? 1 : 0)
            ledMaterial.emission.intensity = on ? 1.6 : 0
            ledGlow.isHidden = !on
        }
    }

    /// Turns the on-screen case with the real one, in degrees per second.
    func follow(yaw yawRate: Double, pitch pitchRate: Double, at time: TimeInterval) {
        let dt = followTime.map { min(max(time - $0, 0), 0.1) } ?? 0
        followTime = time
        let keep = exp(-dt / Self.followReturn)
        yaw = min(max((yaw + yawRate * dt) * keep, -Self.followLimit), Self.followLimit)
        pitch = min(max((pitch + pitchRate * dt) * keep, -Self.followLimit), Self.followLimit)
        applyPose()
    }

    /// Acts out a move during calibration, in degrees.
    func show(yaw: Double, pitch: Double) {
        self.yaw = yaw
        self.pitch = pitch
        applyPose()
    }

    /// Tints the rim of the case to match the light around it.
    func setMood(_ mood: AuraMood) {
        guard mood != self.mood else { return }
        self.mood = mood
        change { [weak self] in self?.apply(mood, animated: true) }
    }

    private func apply(_ mood: AuraMood, animated: Bool) {
        let rim = Self.rim(for: mood)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.6 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        for material in shell {
            material.setValue(NSValue(scnVector3: rim.left), forKey: "rimLeft")
            material.setValue(NSValue(scnVector3: rim.right), forKey: "rimRight")
            material.setValue(rim.amount, forKey: "rimAmount")
        }
        rimLights[0].color = NSColor(red: rim.left.x, green: rim.left.y, blue: rim.left.z, alpha: 1)
        rimLights[1].color = NSColor(red: rim.right.x, green: rim.right.y, blue: rim.right.z, alpha: 1)
        rimLights[0].intensity = 400 * rim.amount
        rimLights[1].intensity = 400 * rim.amount
        SCNTransaction.commit()
    }

    private static func rim(for mood: AuraMood) -> (left: SCNVector3, right: SCNVector3, amount: CGFloat) {
        let violet = SCNVector3(0.48, 0.36, 1), azure = SCNVector3(0.18, 0.66, 1), mint = SCNVector3(0.24, 0.94, 0.78)
        let coral = SCNVector3(1, 0.36, 0.54), amber = SCNVector3(1, 0.7, 0.28)
        func mix(_ a: SCNVector3, _ b: SCNVector3, _ t: CGFloat) -> SCNVector3 {
            SCNVector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
        }
        switch mood {
        case .off: return (SCNVector3(1, 1, 1), SCNVector3(1, 1, 1), 0)
        case .searching: return (violet, mix(violet, azure, 0.5), 0.7)
        case .connected: return (mix(violet, coral, 0.22), azure, 1)
        case .calibrating: return (azure, mint, 1)
        case .paused: return (amber, amber, 0.8)
        }
    }

    /// Reduce Motion stops everything that moves on its own, and the flares stop glinting.
    private func applyMotionPreference() {
        let still = Theme.reduceMotion
        for material in flares { material.setValue(still ? 1.0 : 0.0, forKey: "flareStill") }
        if still {
            floatNode.removeAction(forKey: "float")
            floatNode.position = SCNVector3Zero
        } else if floatNode.action(forKey: "float") == nil {
            let rise = SCNAction.moveBy(x: 0, y: 1, z: 0, duration: 2.8)
            rise.timingMode = .easeInEaseOut
            floatNode.runAction(.repeatForever(.sequence([rise, rise.reversed()])), forKey: "float")
        }
    }

    /// At 50 Hz on the pointer's thread: only the newest pose matters, so a slow frame can't
    /// build up a queue of them.
    private func applyPose() {
        let rest = Self.restingTilt
        let angles = SCNVector3(rest.x - CGFloat(pitch * .pi / 180), rest.y + CGFloat(yaw * .pi / 180), 0)
        let isFirst = pose.withLock { pending -> Bool in
            pending.angles = angles
            defer { pending.isQueued = true }
            return !pending.isQueued
        }
        light.lean(x: yaw / Self.followLimit, y: pitch / Self.followLimit)
        guard isFirst else { return }
        change { [pose, poseNode] in
            poseNode.eulerAngles = pose.withLock { pending in
                pending.isQueued = false
                return pending.angles
            }
        }
    }

    /// A still of the scene, for checking the look without a window. The HUD framings are laid
    /// out for the HUD's fixed view, so `side` is then its width unless `size` says otherwise.
    func snapshot(side: CGFloat, framing: AirPodsFraming = .hero, size: CGSize? = nil) -> NSImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        // A still can't wait for the fade or the camera.
        queue.sync {
            SCNTransaction.flush()
            rimLights.forEach { $0.removeAllAnimations() }
            shell.forEach { $0.removeAllAnimations() }
            apply(mood, animated: false)
            camera(for: framing).position = Self.shot(of: framing).position
            hudCamera.camera?.categoryBitMask = framing == .hudStatus ? ~Self.flareMask : -1
            SCNTransaction.flush()
        }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera(for: framing)
        let aspect = framing == .hero ? 1 : AirPodsFraming.hudSize.height / AirPodsFraming.hudSize.width
        let size = size ?? CGSize(width: side, height: side * aspect)
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }

    // MARK: Framing

    /// The height of the open case, and the middle of it, in model units.
    private static let modelHeight: CGFloat = 53
    private static let modelCenter = CGPoint(x: 1.6, y: 2.9)

    private static func shot(of framing: AirPodsFraming) -> (position: SCNVector3, fieldOfView: CGFloat) {
        // Long lenses for the HUD: its case sits far off axis, and a wide one would skew it.
        func hud(height: CGFloat, center: CGPoint) -> (SCNVector3, CGFloat) {
            let view = AirPodsFraming.hudSize, fieldOfView: CGFloat = 14
            let scale = height / modelHeight
            return (SCNVector3(
                modelCenter.x + (view.width / 2 - center.x) / scale,
                modelCenter.y + (center.y - view.height / 2) / scale,
                view.height / scale / (2 * tan(fieldOfView * .pi / 360))
            ), fieldOfView)
        }
        switch framing {
        case .hero: return (SCNVector3(modelCenter.x, modelCenter.y, 196), 22)
        case .hudStatus: return hud(height: 46, center: CGPoint(x: 52, y: 66))
        case .hudCalibration: return hud(height: 104, center: CGPoint(x: AirPodsFraming.hudSize.width / 2, y: 112))
        }
    }

    // MARK: Model

    private func buildModel() {
        poseNode.addChildNode(lidNode)
        guard let url = Bundle.main.url(forResource: "airpods", withExtension: "mesh"),
              let data = try? Data(contentsOf: url) else { return }

        var at = 0
        func u32() -> Int {
            defer { at += 4 }
            return Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian })
        }
        func f32() -> CGFloat {
            defer { at += 4 }
            return CGFloat(data.withUnsafeBytes { Float(bitPattern: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian) })
        }
        func slice(_ count: Int) -> Data {
            defer { at += count }
            return data.subdata(in: at..<(at + count))
        }

        let materials = Self.materials(led: ledMaterial)
        shell = Array(materials[0...1])
        let parts = u32()
        lidNode.position = SCNVector3(f32(), f32(), f32())

        for _ in 0..<parts {
            let parent = u32() == 1 ? lidNode : poseNode
            let material = materials[u32()]
            let vertices = u32(), indices = u32()
            let positions = slice(vertices * 12), normals = slice(vertices * 12), triangles = slice(indices * 4)
            func source(_ data: Data, _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
                SCNGeometrySource(
                    data: data, semantic: semantic, vectorCount: vertices, usesFloatComponents: true,
                    componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12
                )
            }
            let element = SCNGeometryElement(data: triangles, primitiveType: .triangles, primitiveCount: indices / 3, bytesPerIndex: 4)
            let geometry = SCNGeometry(sources: [source(positions, .vertex), source(normals, .normal)], elements: [element])
            geometry.materials = [material]
            parent.addChildNode(SCNNode(geometry: geometry))
        }
        addFlares()
    }

    /// In the order the website's exporter writes them.
    private static func materials(led: SCNMaterial) -> [SCNMaterial] {
        func make(_ white: CGFloat, roughness: CGFloat, metalness: CGFloat = 0, clearCoat: CGFloat = 0, doubleSided: Bool = false) -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = NSColor(white: white, alpha: 1)
            material.roughness.contents = roughness
            material.metalness.contents = metalness
            material.clearCoat.contents = clearCoat
            material.clearCoatRoughness.contents = 0.05
            material.isDoubleSided = doubleSided
            return material
        }
        led.lightingModel = .physicallyBased
        led.diffuse.contents = NSColor(white: 0.1, alpha: 1)
        led.roughness.contents = 0.3
        let body = make(0.95, roughness: 0.32, clearCoat: 1)
        let buds = make(0.96, roughness: 0.3, clearCoat: 1)
        for material in [body, buds] {
            material.shaderModifiers = [.fragment: rimShader]
        }
        // Black mesh swallows the softboxes that any dielectric would still mirror.
        let grille = make(0.02, roughness: 0.9)
        grille.multiply.contents = NSColor(white: 0.45, alpha: 1)
        return [
            body,
            buds,
            make(0.9, roughness: 0.74, doubleSided: true),
            grille,
            grille,
            make(0.82, roughness: 0.22, metalness: 1),
            led,
        ]
    }

    /// Where the case turns away it goes dark against the black flags, so white holds its edge on
    /// a pale background, and it picks up the colour of the light around it.
    private static let rimShader = """
    #pragma arguments
    float3 rimLeft;
    float3 rimRight;
    float rimAmount;
    #pragma body
    float turn = 1.0 - saturate(dot(_surface.normal, _surface.view));
    float rim = pow(turn, 3.5);
    float3 tint = mix(rimLeft, rimRight, 0.5 + 0.5 * _surface.normal.x);
    _output.color.rgb *= 1.0 - 0.6 * pow(turn, 3.0);
    _output.color.rgb += tint * rim * rimAmount * 0.45;
    """

    // MARK: Flares

    private func addFlares() {
        func flare(_ parent: SCNNode, at position: SCNVector3, facing normal: SIMD3<Float>, length: CGFloat, height: CGFloat, gain: CGFloat, led: CGFloat = 0) {
            let plane = SCNPlane(width: length, height: height)
            let material = Self.flareMaterial()
            material.setValue(gain, forKey: "flareGain")
            material.setValue(led, forKey: "flareLED")
            plane.materials = [material]
            flares.append(material)
            let node = SCNNode(geometry: plane)
            node.categoryBitMask = Self.flareMask
            node.position = position
            node.simdOrientation = simd_quatf(from: SIMD3(0, 0, 1), to: simd_normalize(normal))
            node.renderingOrder = 100
            node.castsShadow = false
            parent.addChildNode(node)
        }
        flare(poseNode, at: SCNVector3(5, 9.4, -10), facing: SIMD3(0.1, 0.7, 0.7), length: 30, height: 2.4, gain: 1.2)
        flare(lidNode, at: SCNVector3(9, 0.2, 20.3), facing: SIMD3(0.2, -0.5, 0.8), length: 56, height: 2.4, gain: 1.6)
        flare(poseNode, at: SCNVector3(-8, 8.9, 10.4), facing: SIMD3(-0.1, 0.8, 0.6), length: 50, height: 2.4, gain: 1.4)
        poseNode.addChildNode(ledGlow)
        ledGlow.isHidden = true
        flare(ledGlow, at: SCNVector3(0, -6, 10.8), facing: SIMD3(0, 0, 1), length: 18, height: 18, gain: 1, led: 1)
    }

    private static func flareMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.black
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        material.isDoubleSided = true
        material.shaderModifiers = [.geometry: flareGeometry, .fragment: flareFragment]
        return material
    }

    /// Turns the quad to face the camera here rather than with a constraint, so the node keeps
    /// its real transform: its +Z is the surface it sits on, and how nearly that surface mirrors
    /// a softbox into the lens is how bright the flare is. The pose costs the CPU nothing.
    private static let flareGeometry = """
    #pragma arguments
    float flareStill;
    #pragma varyings
    float2 flareAt;
    float flareGlint;
    float flareSeen;
    #pragma body
    float3 center = (scn_node.modelViewTransform * float4(0, 0, 0, 1)).xyz;
    float3 facing = normalize((scn_node.modelViewTransform * float4(0, 0, 1, 0)).xyz);
    float key = saturate(dot(facing, normalize(float3(-0.42, 0.5, 0.76))));
    float fill = saturate(dot(facing, normalize(float3(0.5, 0.3, 0.8))));
    float glint = max(pow(key, 24.0), 0.7 * pow(fill, 32.0));
    out.flareGlint = mix(glint, 0.2, flareStill);
    out.flareSeen = smoothstep(0.1, 0.5, facing.z);
    out.flareAt = _geometry.texcoords[0] * 2.0 - 1.0;
    // Pulled toward the lens along its own ray, clear of the curve of the case it sits on.
    float3 corner = center * (1.0 - 14.0 / length(center)) + float3(_geometry.position.xy, 0.0);
    _geometry.position = scn_node.inverseModelViewTransform * float4(corner, 1.0);
    """

    private static let flareFragment = """
    #pragma arguments
    float flareGain;
    float flareLED;
    #pragma varyings
    float2 flareAt;
    float flareGlint;
    float flareSeen;
    #pragma body
    float2 p = in.flareAt;
    float fade = saturate(1.0 - p.x * p.x);
    float streak = exp(-abs(p.x) * 5.0) * exp(-p.y * p.y * 26.0) * fade;
    float2 q = p * float2(46.0, 3.0);
    float core = exp(-dot(q, q));
    float3 color = (float3(0.62, 0.78, 1.0) * streak + core) * in.flareGlint;
    if (flareLED > 0.5) {
        float r = dot(p, p);
        float glow = exp(-r * 18.0) * saturate(1.0 - r);
        float line = exp(-abs(p.x) * 6.0) * exp(-p.y * p.y * 1200.0) * fade;
        color = float3(0.2, 1.0, 0.48) * (glow * 0.45 + line * (0.2 + in.flareGlint));
    }
    _output.color = float4(color * flareGain * in.flareSeen, 0.0);
    """

    // MARK: Lighting

    /// A photographer's studio, wrapped around the scene in floating point because softboxes
    /// are many times brighter than white paper. A dim room lit from the front and above for
    /// the diffuse white, long hard-edged strips for the clear coat to mirror, and black flags
    /// that the white edges turn dark against, so they read on a pale background.
    private static func studioLighting() -> CGImage {
        let width = 1024, height = 512
        var pixels = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: width * height)

        // SceneKit wraps the image with its left edge toward the camera, running to the camera's left.
        for y in 0..<height {
            let elevation = (0.5 - (Float(y) + 0.5) / Float(height)) * .pi
            for x in 0..<width {
                let azimuth = -(Float(x) + 0.5) / Float(width) * 2 * .pi
                let front = cos(elevation) * cos(azimuth), right = cos(elevation) * sin(azimuth), up = sin(elevation)
                let room = 0.02 + 1.5 * pow(max(0.85 * front + 0.3 * up - 0.3 * right, 0), 1.9)
                pixels[y * width + x] = SIMD4(room, room, room * 1.01, 1)
            }
        }

        /// Azimuth 0 is at the camera, positive to its right. Elevation is up from the horizon.
        func box(azimuth: ClosedRange<Float>, elevation: ClosedRange<Float>, radiance: Float) {
            let left = Int(-azimuth.upperBound / 360 * Float(width)), right = Int(-azimuth.lowerBound / 360 * Float(width))
            let top = Int((0.5 - elevation.upperBound / 180) * Float(height)), bottom = Int((0.5 - elevation.lowerBound / 180) * Float(height))
            for y in top..<bottom {
                for x in left..<right {
                    pixels[y * width + (x + width) % width] = SIMD4(radiance, radiance, radiance, 1)
                }
            }
        }
        box(azimuth: -74 ... -68, elevation: -40 ... 58, radiance: 16)
        box(azimuth: -44 ... -14, elevation: 8 ... 52, radiance: 6)
        box(azimuth: 52 ... 58, elevation: -40 ... 58, radiance: 12)
        box(azimuth: -60 ... 60, elevation: 62 ... 70, radiance: 12)
        box(azimuth: 100 ... 140, elevation: -90 ... 90, radiance: 0)
        box(azimuth: -140 ... -100, elevation: -90 ... 90, radiance: 0)
        box(azimuth: 160 ... 168, elevation: -50 ... 70, radiance: 3)
        box(azimuth: -168 ... -160, elevation: -50 ... 70, radiance: 3)

        let data = pixels.withUnsafeBytes { Data($0) }
        return CGImage(
            width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16,
            space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }
}

/// How a view frames the case. A persistent HUD view moves between these with its camera
/// alone, so nothing is laid out or resized on the main thread while the pointer is live.
enum AirPodsFraming: Equatable, CaseIterable {
    case hero, hudStatus, hudCalibration

    /// The fixed view the HUD framings are laid out for, in points.
    static let hudSize = CGSize(width: 380, height: 270)
}

/// The live scene, or in a snapshot a still of it: `ImageRenderer` can't draw an `SCNView`.
struct AirPodsView: View {
    let airpods: AirPodsScene
    var framing = AirPodsFraming.hero
    @Environment(\.stillRendering) private var still

    var body: some View {
        if still {
            GeometryReader { box in
                let size = CGSize(width: box.size.width * 2, height: box.size.height * 2)
                if let image = airpods.snapshot(side: size.width, framing: framing, size: size) {
                    Image(nsImage: image).resizable().frame(width: box.size.width, height: box.size.height)
                }
            }
        } else {
            LiveAirPodsView(airpods: airpods, framing: framing)
        }
    }
}

/// Shows the scene in SwiftUI, with a transparent background.
private struct LiveAirPodsView: NSViewRepresentable {
    let airpods: AirPodsScene
    let framing: AirPodsFraming

    func makeNSView(context: Context) -> VisibleSceneView {
        let view = VisibleSceneView(sceneToShow: airpods.scene, camera: airpods.camera(for: framing), framing: framing)
        airpods.frameHUD(framing)
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false
        view.allowsCameraControl = false
        view.prepare([airpods.scene], completionHandler: nil)
        return view
    }

    func updateNSView(_ view: VisibleSceneView, context: Context) {
        guard view.framing != framing else { return }
        view.framing = framing
        airpods.frameHUD(framing)
    }
}

/// Holds its scene only while a window actually shows it. Pausing isn't enough: an `SCNView`
/// keeps its display link and spins waiting for drawables until it has no scene.
private final class VisibleSceneView: SCNView, SCNSceneRendererDelegate {
    var framing: AirPodsFraming
    private let sceneToShow: SCNScene
    private let camera: SCNNode
    private var windowWatch: WindowWatch?

    init(sceneToShow: SCNScene, camera: SCNNode, framing: AirPodsFraming) {
        self.sceneToShow = sceneToShow
        self.camera = camera
        self.framing = framing
        super.init(frame: .zero, options: nil)
        delegate = self
        scene = sceneToShow
        pointOfView = camera
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A returning scene gets the first camera in it, whatever was set on main. Done here on
    /// the render thread, so it can't wait on the scene lock with the pointer behind it.
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if renderer.pointOfView !== camera { renderer.pointOfView = camera }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowWatch = window.map { WindowWatch($0) { [weak self] in self?.syncShown() } }
        syncShown()
    }

    private func syncShown() {
        let shown = WindowWatch.shows(window)
        if shown, scene == nil { scene = sceneToShow }
        isPlaying = shown
        if !shown { scene = nil }
    }
}
