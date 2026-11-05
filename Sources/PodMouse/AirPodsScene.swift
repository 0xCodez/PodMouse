import AppKit
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
    private var yaw = 0.0
    private var pitch = 0.0
    private var followTime: TimeInterval?

    private static let openLidAngle = 1.9
    /// A three-quarter view, so it reads as an object at any size.
    private static let restingTilt = SCNVector3(0.2, -0.42, 0)
    private static let followLimit = 40.0
    /// Seconds for the on-screen case to drift back to its resting pose.
    private static let followReturn = 1.6

    init(light: AuraLight) {
        self.light = light
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = Self.studioLighting()
        scene.lightingEnvironment.intensity = 1.7
        addLight(.directional, intensity: 150, euler: SCNVector3(-0.95, -0.5, 0))
        addLight(.directional, intensity: 45, euler: SCNVector3(-0.2, 0.9, 0))

        let camera = SCNCamera()
        camera.projectionDirection = .vertical
        camera.fieldOfView = 22
        camera.zNear = 10
        camera.zFar = 1000
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = 0
        camera.minimumExposure = -2
        camera.maximumExposure = 2
        camera.bloomIntensity = 0.3
        camera.bloomThreshold = 0.95
        camera.bloomBlurRadius = 6
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 3, 196)
        cameraNode.name = "camera"
        scene.rootNode.addChildNode(cameraNode)

        scene.rootNode.addChildNode(floatNode)
        floatNode.addChildNode(poseNode)
        poseNode.eulerAngles = Self.restingTilt
        buildModel()

        let rise = SCNAction.moveBy(x: 0, y: 1.6, z: 0, duration: 2.2)
        rise.timingMode = .easeInEaseOut
        floatNode.runAction(.repeatForever(.sequence([rise, rise.reversed()])))
    }

    private func addLight(_ type: SCNLight.LightType, intensity: CGFloat, euler: SCNVector3 = SCNVector3Zero) {
        let light = SCNLight()
        light.type = type
        light.intensity = intensity
        light.color = NSColor.white
        let node = SCNNode()
        node.light = light
        node.eulerAngles = euler
        scene.rootNode.addChildNode(node)
    }

    var pointOfView: SCNNode? { scene.rootNode.childNode(withName: "camera", recursively: false) }

    func setLidOpen(_ open: Bool, animated: Bool = true) {
        let angle = open ? -Self.openLidAngle : 0
        lidNode.removeAllActions()
        guard animated else {
            lidNode.eulerAngles.x = CGFloat(angle)
            return
        }
        let swing = SCNAction.rotateTo(x: CGFloat(angle), y: 0, z: 0, duration: 0.7, usesShortestUnitArc: true)
        swing.timingMode = .easeInEaseOut
        lidNode.runAction(swing)
    }

    func setLight(on: Bool) {
        ledMaterial.emission.contents = NSColor(red: 0.2, green: 1, blue: 0.48, alpha: 1).withAlphaComponent(on ? 1 : 0)
        ledMaterial.emission.intensity = on ? 1.6 : 0
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
    func setMood(_ mood: AuraMood) {}

    private func applyPose() {
        let rest = Self.restingTilt
        poseNode.eulerAngles = SCNVector3(rest.x - CGFloat(pitch * .pi / 180), rest.y + CGFloat(yaw * .pi / 180), 0)
    }

    /// A still of the scene, for checking the look without a window.
    func snapshot(side: CGFloat, framing: AirPodsFraming = .hero) -> NSImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = pointOfView
        return renderer.snapshot(atTime: 0, with: CGSize(width: side, height: side), antialiasingMode: .multisampling4X)
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
            material.clearCoatRoughness.contents = 0.14
            material.isDoubleSided = doubleSided
            return material
        }
        led.lightingModel = .physicallyBased
        led.diffuse.contents = NSColor(white: 0.1, alpha: 1)
        led.roughness.contents = 0.3
        return [
            make(0.95, roughness: 0.3, clearCoat: 1),
            make(0.96, roughness: 0.28, clearCoat: 1),
            make(0.89, roughness: 0.62, doubleSided: true),
            make(0.04, roughness: 0.82),
            make(0.1, roughness: 0.7, metalness: 0.3),
            make(0.8, roughness: 0.26, metalness: 1),
            led,
        ]
    }

    /// A photographer's studio, wrapped around the scene as an image: soft boxes on a dim
    /// room, so white plastic gets long clean highlights instead of flat grey.
    private static func studioLighting() -> NSImage {
        let size = NSSize(width: 1024, height: 512)
        return NSImage(size: size, flipped: false) { bounds in
            NSGradient(starting: NSColor(white: 0.62, alpha: 1), ending: NSColor(white: 0.16, alpha: 1))?
                .draw(in: bounds, angle: -90)

            func softBox(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ brightness: CGFloat) {
                let rect = NSRect(x: x * bounds.width, y: y * bounds.height, width: w * bounds.width, height: h * bounds.height)
                NSGradient(starting: NSColor(white: brightness, alpha: 1), ending: NSColor(white: brightness, alpha: 0))?
                    .draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: .zero)
            }
            softBox(0.26, 0.62, 0.48, 0.36, 1)
            softBox(0.02, 0.28, 0.2, 0.55, 1)
            softBox(0.78, 0.28, 0.2, 0.55, 1)
            softBox(0.4, 0.4, 0.2, 0.2, 0.75)
            return true
        }
    }
}

/// How a view frames the case. A persistent HUD view moves between these with its camera
/// alone, so nothing is laid out or resized on the main thread while the pointer is live.
enum AirPodsFraming: Equatable {
    case hero, hudStatus, hudCalibration
}

/// The live scene, or in a snapshot a still of it: `ImageRenderer` can't draw an `SCNView`.
struct AirPodsView: View {
    let airpods: AirPodsScene
    var framing = AirPodsFraming.hero
    @Environment(\.stillRendering) private var still

    var body: some View {
        if still {
            GeometryReader { box in
                if let image = airpods.snapshot(side: max(box.size.width, box.size.height) * 2, framing: framing) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: box.size.width, height: box.size.height)
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

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: nil)
        view.scene = airpods.scene
        view.pointOfView = airpods.pointOfView
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true
        view.rendersContinuously = false
        view.allowsCameraControl = false
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {}
}
