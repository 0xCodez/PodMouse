import CoreMotion
import PodMouseCore

/// Streams motion from AirPods via CoreMotion, the only public route to their sensors.
final class MotionService: NSObject, CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()

    var onFrame: ((MotionFrame) -> Void)?
    /// The untouched reading, for the sensor recorder.
    var onRawMotion: ((CMDeviceMotion) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    static var authorization: CMAuthorizationStatus { CMHeadphoneMotionManager.authorizationStatus() }

    override init() {
        super.init()
        manager.delegate = self
    }

    /// The first call shows the system's motion permission prompt.
    func start() {
        guard !manager.isDeviceMotionActive else { return }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                self.onError?(error)
                return
            }
            guard let motion else { return }
            self.onRawMotion?(motion)
            let r = motion.rotationRate, a = motion.userAcceleration, g = motion.gravity
            self.onFrame?(MotionFrame(
                timestamp: motion.timestamp,
                rotationRate: Vec3(r.x, r.y, r.z),
                userAcceleration: Vec3(a.x, a.y, a.z),
                gravity: Vec3(g.x, g.y, g.z)
            ))
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// Recovers a stream that stalled after an audio route change.
    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.start()
        }
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { self.onConnectionChange?(true) }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { self.onConnectionChange?(false) }
    }
}
