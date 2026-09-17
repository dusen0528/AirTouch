import SwiftUI
import AVFoundation
import AirTouchCore

final class PreviewHost: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    private weak var camera: CameraService?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer = CALayer()
        preview.videoGravity = .resizeAspect
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); preview.frame = bounds }
    func connect(to camera: CameraService) {
        guard self.camera !== camera else { return }
        disconnect()
        self.camera = camera
        camera.attachPreview(preview)
    }
    func disconnect() {
        camera?.detachPreview(preview)
        camera = nil
    }
    deinit { camera?.detachPreview(preview) }
}

struct CameraPreview: NSViewRepresentable {
    let camera: CameraService
    func makeNSView(context: Context) -> PreviewHost {
        let view = PreviewHost(frame: .zero); view.connect(to: camera); return view
    }
    func updateNSView(_ view: PreviewHost, context: Context) {}
    static func dismantleNSView(_ view: PreviewHost, coordinator: ()) { view.disconnect() }
}

struct SkeletonOverlay: View {
    let joints: [Joint: Landmark]
    var body: some View {
        Canvas { context, size in
            func position(_ joint: Joint) -> CGPoint? {
                guard let p = joints[joint], p.confidence >= 0.35 else { return nil }
                return CGPoint(x: p.point.x * size.width, y: p.point.y * size.height)
            }
            for chain in Joint.chains {
                for pair in zip(chain, chain.dropFirst()) {
                    if let a = position(pair.0), let b = position(pair.1) {
                        var path = Path(); path.move(to: a); path.addLine(to: b)
                        context.stroke(path, with: .color(.mint), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                }
            }
            for joint in Joint.allCases {
                if let p = position(joint) {
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white))
                }
            }
        }.allowsHitTesting(false)
    }
}
