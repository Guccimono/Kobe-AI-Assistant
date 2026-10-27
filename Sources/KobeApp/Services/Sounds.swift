import AppKit
import KobeKit

/// Short, quiet system sounds, only when Sound is on. (No sound files are shipped.)
enum Sounds {
    enum Kind {
        case done, needsYou, error, pop

        var name: NSSound.Name {
            switch self {
            case .done: "Glass"
            case .needsYou: "Funk"
            case .error: "Basso"
            case .pop: "Pop"
            }
        }
    }

    @MainActor
    static func play(_ kind: Kind, settings: AppSettings) {
        guard settings.soundOn, let sound = NSSound(named: kind.name)?.copy() as? NSSound else { return }
        sound.volume = Float(settings.soundVolume)
        sound.play()
    }
}
