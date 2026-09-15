import AppKit

@MainActor enum AppInstallation {
    static var installed: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
    static let destination = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/AirTouch.app", isDirectory: true)

    static func installAndRelaunch(completion: @escaping (String?) -> Void) {
        let fm = FileManager.default, source = Bundle.main.bundleURL
        guard source.pathExtension == "app" else { completion(".app 패키지에서 실행해주세요"); return }
        let backups = fm.temporaryDirectory.appendingPathComponent("AirTouch-Install", isDirectory: true)
        let backup = backups.appendingPathComponent("\(UUID().uuidString).airtouch-backup", isDirectory: true)
        let stagedContents = destination.deletingLastPathComponent().appendingPathComponent(".airtouch-stage-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stagedContents) }
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }) {
            completion("설치된 AirTouch를 먼저 종료한 뒤 다시 설치해주세요"); return
        }
        var backedUp = false
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source.appendingPathComponent("Contents"), to: stagedContents)
            if fm.fileExists(atPath: destination.path) {
                guard let identifier = Bundle(url: destination)?.bundleIdentifier,
                      ["dev.airtouch.practice", "dev.airtouch.mac"].contains(identifier) else {
                    completion("설치 위치에 다른 앱이 있습니다. Finder에서 확인해주세요"); return
                }
                try fm.createDirectory(at: backup, withIntermediateDirectories: true)
                try fm.moveItem(at: destination.appendingPathComponent("Contents"), to: backup.appendingPathComponent("Contents"))
                backedUp = true
            }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try fm.moveItem(at: stagedContents, to: destination.appendingPathComponent("Contents"))
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
                Task { @MainActor in
                    if let error { completion("설치됐지만 실행하지 못했습니다: \(error.localizedDescription)") }
                    else {
                        try? FileManager.default.removeItem(at: backup)
                        NSApp.terminate(nil)
                    }
                }
            }
        } catch {
            try? fm.removeItem(at: stagedContents)
            if backedUp, !fm.fileExists(atPath: destination.appendingPathComponent("Contents").path) {
                try? fm.moveItem(at: backup.appendingPathComponent("Contents"), to: destination.appendingPathComponent("Contents"))
            }
            if !fm.fileExists(atPath: backup.appendingPathComponent("Contents").path) { try? fm.removeItem(at: backup) }
            completion("설치 실패: \(error.localizedDescription)")
        }
    }
}
