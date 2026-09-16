import AppKit
import AirTouchCore

/// A passive AppKit panel: follows the real pointer without taking focus or clicks.
@MainActor final class CursorStatusOverlay {
    struct StatusSnapshot: Equatable {
        let text: String
        let icon: String
        let progress: Double
        let locked: Bool
    }

    struct PanelSnapshot {
        let isVisible: Bool
        let ignoresMouseEvents: Bool
        let canBecomeKey: Bool
        let canBecomeMain: Bool
        let isNonactivating: Bool
        let canJoinAllSpaces: Bool
        let canJoinFullScreen: Bool
    }

    private let panel: NSPanel
    private let symbol = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var previousText = ""

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 42),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.title = "AirTouch 커서 상태"
        let effect = NSVisualEffectView()
        effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true; effect.layer?.cornerRadius = 10; effect.layer?.masksToBounds = true
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail; label.translatesAutoresizingMaskIntoConstraints = false
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        progress.style = .bar; progress.controlSize = .mini; progress.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(symbol); effect.addSubview(label); effect.addSubview(progress)
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            symbol.centerYAnchor.constraint(equalTo: effect.centerYAnchor, constant: -2),
            symbol.widthAnchor.constraint(equalToConstant: 18), symbol.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: symbol.centerYAnchor),
            progress.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            progress.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -5),
            progress.heightAnchor.constraint(equalToConstant: 3)
        ])
        panel.contentView = effect
    }

    /// Read-only seams keep status and focus checks independent of desktop input.
    var panelSnapshot: PanelSnapshot {
        PanelSnapshot(isVisible: panel.isVisible, ignoresMouseEvents: panel.ignoresMouseEvents,
            canBecomeKey: panel.canBecomeKey, canBecomeMain: panel.canBecomeMain,
            isNonactivating: panel.styleMask.contains(.nonactivatingPanel),
            canJoinAllSpaces: panel.collectionBehavior.contains(.canJoinAllSpaces),
            canJoinFullScreen: panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    static func status(engine: GestureEngine, handoff: Bool, trackingFresh: Bool) -> StatusSnapshot {
        let text: String
        let icon: String
        if handoff { text = "마우스 사용 중"; icon = "computermouse" }
        else if !trackingFresh { text = "손을 찾는 중"; icon = "hand.raised.slash" }
        else if engine.waitingForPinchRelease { text = "끌기 완료 · 손가락 펴기"; icon = "checkmark.circle" }
        else if engine.dragLocked { text = "끌기 잠금 · 집으면 놓기"; icon = "lock.fill" }
        else {
            switch engine.state {
            case .suspended: text = "손가락을 펴서 준비"; icon = "hand.point.up.left"
            case .pointer: text = "이동"; icon = "cursorarrow"
            case .pinchCandidate: text = "클릭 준비"; icon = "hand.pinch"
            case .pressed: text = "누름 · 놓으면 클릭"; icon = "cursorarrow.click"
            case .dragging: text = "끌기"; icon = "hand.draw"
            case .scrolling: text = "스크롤"; icon = "arrow.up.arrow.down"
            }
        }
        return StatusSnapshot(text: text, icon: icon, progress: engine.progress, locked: engine.dragLocked)
    }

    func update(engine: GestureEngine, handoff: Bool, trackingFresh: Bool, visible: Bool) {
        guard visible else { hide(); return }
        let status = Self.status(engine: engine, handoff: handoff, trackingFresh: trackingFresh)
        if status.text != previousText {
            previousText = status.text; label.stringValue = status.text
            symbol.image = NSImage(systemSymbolName: status.icon, accessibilityDescription: status.text)
            symbol.contentTintColor = status.locked ? .systemOrange : .controlAccentColor
            panel.setAccessibilityLabel("AirTouch · \(status.text)")
        }
        progress.doubleValue = status.progress; progress.isHidden = status.progress <= 0
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let bounds = screen.visibleFrame
            let size = panel.frame.size
            let x = min(max(bounds.minX, mouse.x + 20), bounds.maxX - size.width)
            var y = mouse.y - size.height - 16
            if y < bounds.minY { y = min(bounds.maxY - size.height, mouse.y + 20) }
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { if panel.isVisible { panel.orderOut(nil) } }
}
