import Foundation
import AirTouchCore

/// Stores the aggregate profile, never calibration frames or hand coordinates.
/// The profile blob is written last and is authoritative on subsequent loads.
/// UserDefaults does not provide a transaction spanning the three preference keys.
final class CalibrationProfileStore {
    private static let profileKey = "personalCalibration.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> PersonalCalibrationProfile? {
        guard let data = defaults.data(forKey: Self.profileKey),
              let profile = try? JSONDecoder().decode(PersonalCalibrationProfile.self, from: data),
              profile.isValid else { return nil }
        return profile
    }

    /// Invalid profiles leave both the existing profile and manual settings intact.
    @discardableResult func save(_ profile: PersonalCalibrationProfile) -> Bool {
        guard profile.isValid, let data = try? JSONEncoder().encode(profile) else { return false }
        defaults.set(profile.sensitivity, forKey: "sensitivity")
        defaults.set(profile.minimumCutoff, forKey: "smoothing")
        defaults.set(data, forKey: Self.profileKey)
        return true
    }

    /// The caller separately decides whether to reset manually adjustable settings.
    func clear() { defaults.removeObject(forKey: Self.profileKey) }
}
