import AppKit
import AirTouchCore

/// A passive AppKit panel: follows the real pointer without taking focus or clicks.
@MainActor final class CursorStatusOverlay {
    struct StatusSnapshot: Equatable {
        let text: String
        let icon: String
        let progress: Double
        let locked: Bool
        let instructions: String?
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
    private let guide = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private var previousStatus: StatusSnapshot?
    private var guideHeight: NSLayoutConstraint!

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
        guide.font = .systemFont(ofSize: 12)
        guide.textColor = .secondaryLabelColor
        guide.translatesAutoresizingMaskIntoConstraints = false
        guide.isHidden = true
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        progress.style = .bar; progress.controlSize = .mini; progress.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(symbol); effect.addSubview(label); effect.addSubview(guide); effect.addSubview(progress)
        guideHeight = guide.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            symbol.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),
            symbol.widthAnchor.constraint(equalToConstant: 18), symbol.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: symbol.centerYAnchor),
            guide.topAnchor.constraint(equalTo: effect.topAnchor, constant: 36),
            guide.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 10),
            guide.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            guideHeight,
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
        var instructions: String?
        if handoff { text = "마우스 사용 중"; icon = "computermouse" }
        else if !trackingFresh { text = "손을 찾는 중"; icon = "hand.raised.slash" }
        else if engine.waitingForPinchRelease { text = "끌기 완료 · 손가락 펴기"; icon = "checkmark.circle" }
        else if engine.dragLocked { text = "끌기 잠금 · 집으면 놓기"; icon = "lock.fill" }
        else {
            switch engine.state {
            case .suspended:
                text = "손동작 안내"; icon = "hand.draw"
                let drag = engine.configuration.dragLockEnabled
                    ? "집어 끌기 → 검지만 펴서 이동 → 다시 집어 놓기"
                    : "집은 채 이동 → 손가락 놓기"
                instructions = [
                    "클릭 · 엄지·검지 모았다 놓기",
                    "더블클릭 · 같은 자리에서 빠르게 두 번",
                    "우클릭 · 검지·중지 V → 엄지·중지 모았다 놓기",
                    "스크롤 · 검지·중지 펴고 위아래로",
                    "끌기 · \(drag)"
                ].joined(separator: "\n")
            case .pointer: text = "이동"; icon = "cursorarrow"
            case .pinchCandidate: text = "클릭 준비"; icon = "hand.pinch"
            case .pressed: text = "누름 · 놓으면 클릭"; icon = "cursorarrow.click"
            case .dragging: text = "끌기"; icon = "hand.draw"
            case .scrolling: text = "스크롤"; icon = "arrow.up.arrow.down"
            }
        }
        return StatusSnapshot(text: text, icon: icon, progress: engine.progress,
                              locked: engine.dragLocked, instructions: instructions)
    }

    func update(engine: GestureEngine, handoff: Bool, trackingFresh: Bool, visible: Bool) {
        guard visible else { hide(); return }
        let status = Self.status(engine: engine, handoff: handoff, trackingFresh: trackingFresh)
        apply(status)
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

    private func apply(_ status: StatusSnapshot) {
        if status.text != previousStatus?.text || status.instructions != previousStatus?.instructions {
            label.stringValue = status.text
            symbol.image = NSImage(systemSymbolName: status.icon, accessibilityDescription: status.text)
            symbol.contentTintColor = status.locked ? .systemOrange : .controlAccentColor
            if let instructions = status.instructions {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 5
                let content = NSAttributedString(string: instructions, attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph
                ])
                guide.attributedStringValue = content
                let height = ceil(content.boundingRect(with: NSSize(width: 316, height: 1000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 4
                guideHeight.constant = height; guide.isHidden = false
                panel.setContentSize(NSSize(width: 340, height: 36 + height + 14))
            } else {
                guide.stringValue = ""; guide.isHidden = true; guideHeight.constant = 0
                panel.setContentSize(NSSize(width: 220, height: 42))
            }
            panel.setAccessibilityLabel((["AirTouch", status.text] + [status.instructions].compactMap { $0 }).joined(separator: " · "))
        }
        previousStatus = status
        progress.doubleValue = status.progress; progress.isHidden = status.progress <= 0
    }

    func hide() { if panel.isVisible { panel.orderOut(nil) } }

    #if DEBUG
    /// Render only this app's own hidden view for layout review, never the desktop.
    func previewPNG(status: StatusSnapshot) -> Data? {
        guard !panel.isVisible, let view = panel.contentView else { return nil }
        apply(status)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
    #endif
}
