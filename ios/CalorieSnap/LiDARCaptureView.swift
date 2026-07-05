import ARKit
import SceneKit
import SwiftUI
import UIKit

/// Result of a LiDAR capture: the RGB photo plus a measured food volume (mL),
/// or nil volume when depth/plane wasn't available (falls back to photo-only).
struct CaptureResult {
    let image: UIImage
    let volumeML: Double?
}

/// SwiftUI wrapper around an ARKit-based capture screen that measures the
/// volume of food sitting above the table using the LiDAR depth sensor.
///
/// NOTE: This runs only on LiDAR-equipped devices (iPhone Pro / iPad Pro).
/// On other devices `deviceSupportsLiDAR` is false — the app should fall back
/// to the plain CameraView. The volume math below is a solid first cut and is
/// expected to need on-device threshold tuning.
struct LiDARCaptureView: UIViewControllerRepresentable {
    var onCapture: (CaptureResult) -> Void

    static var deviceSupportsLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    func makeUIViewController(context: Context) -> LiDARCaptureController {
        let vc = LiDARCaptureController()
        vc.onCapture = onCapture
        return vc
    }

    func updateUIViewController(_ vc: LiDARCaptureController, context: Context) {}
}

final class LiDARCaptureController: UIViewController, ARSCNViewDelegate {
    var onCapture: ((CaptureResult) -> Void)?

    private let sceneView = ARSCNView()
    private var tablePlane: ARPlaneAnchor?
    private let hint = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        view.addSubview(sceneView)

        setupHint()
        setupCaptureButton()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    // Track the largest horizontal plane as the "table".
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal else { return }
        promoteIfLarger(plane)
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal else { return }
        promoteIfLarger(plane)
    }

    private func promoteIfLarger(_ plane: ARPlaneAnchor) {
        let area = plane.planeExtent.width * plane.planeExtent.height
        if let current = tablePlane {
            let curArea = current.planeExtent.width * current.planeExtent.height
            if area > curArea { tablePlane = plane }
        } else {
            tablePlane = plane
        }
        DispatchQueue.main.async {
            self.hint.text = "Table found — hold ~30–40 cm above the plate, roughly top-down, then tap."
        }
    }

    // MARK: - Capture

    @objc private func capture() {
        let image = sceneView.snapshot()
        let volume = measureVolume()
        onCapture?(CaptureResult(image: image, volumeML: volume))
        dismiss(animated: true)
    }

    /// Integrate depth above the table plane to estimate food volume (mL).
    /// Returns nil if depth or a table plane isn't available.
    private func measureVolume() -> Double? {
        guard
            let frame = sceneView.session.currentFrame,
            let sceneDepth = frame.sceneDepth,
            let plane = tablePlane
        else { return nil }

        let depthMap = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        // Intrinsics correspond to the full camera image; scale to depth-map size.
        let imageRes = frame.camera.imageResolution
        let sx = Float(w) / Float(imageRes.width)
        let sy = Float(h) / Float(imageRes.height)
        let K = frame.camera.intrinsics
        let fx = K[0][0] * sx
        let fy = K[1][1] * sy
        let cx = K[2][0] * sx
        let cy = K[2][1] * sy

        let camToWorld = frame.camera.transform

        // Table height (world Y) and its horizontal centre/extent, to reject background.
        let planeY = plane.transform.columns.3.y
        let planeCenterWorld = plane.transform * simd_float4(plane.center, 1)
        let halfW = plane.planeExtent.width / 2 + 0.05    // +5 cm margin
        let halfH = plane.planeExtent.height / 2 + 0.05

        let minHeight: Float = 0.005   // ignore < 5 mm (plane noise)
        let maxHeight: Float = 0.25    // ignore > 25 cm (not a plate of food)

        var volume: Double = 0

        for v in stride(from: 0, to: h, by: 1) {
            let row = base.advanced(by: v * rowBytes).assumingMemoryBound(to: Float32.self)
            for u in stride(from: 0, to: w, by: 1) {
                let d = row[u]                       // metres, along the camera ray
                guard d.isFinite, d > 0.1, d < 2.0 else { continue }

                // Pixel → camera space (camera looks down -Z; image v grows downward).
                let xCam = (Float(u) - cx) * d / fx
                let yCam = -(Float(v) - cy) * d / fy
                let pCam = simd_float4(xCam, yCam, -d, 1)
                let pWorld = camToWorld * pCam

                let height = pWorld.y - planeY
                guard height > minHeight, height < maxHeight else { continue }

                // Reject points outside the plate's horizontal footprint.
                let dx = abs(pWorld.x - planeCenterWorld.x)
                let dz = abs(pWorld.z - planeCenterWorld.z)
                guard dx < halfW, dz < halfH else { continue }

                // Footprint of one depth pixel on a fronto-parallel patch at depth d.
                let pixelArea = (d / fx) * (d / fy)          // m²
                volume += Double(pixelArea * height)          // m³
            }
        }

        let ml = volume * 1_000_000                           // m³ → mL
        // Guard against garbage; treat implausible results as "unmeasured".
        return (ml > 20 && ml < 4000) ? ml : nil
    }

    // MARK: - UI

    private func setupHint() {
        hint.text = "Point at your plate and move slowly to detect the table…"
        hint.numberOfLines = 0
        hint.textColor = .white
        hint.textAlignment = .center
        hint.font = .systemFont(ofSize: 15, weight: .medium)
        hint.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        hint.layer.cornerRadius = 10
        hint.clipsToBounds = true
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])
    }

    private func setupCaptureButton() {
        let button = UIButton(type: .system)
        button.setTitle("Capture", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        button.tintColor = .white
        button.backgroundColor = .systemGreen
        button.layer.cornerRadius = 16
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(capture), for: .touchUpInside)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            button.widthAnchor.constraint(equalToConstant: 200),
            button.heightAnchor.constraint(equalToConstant: 56),
        ])
    }
}
