import Foundation

/// The Phosphor icons Kobe ships (scripts/fetch-icons.sh). Raw value = the SVG file name.
public enum PhosphorIcon: String, CaseIterable, Sendable {
    case chatCircle = "chat-circle"
    case plus
    case sun, sunFill = "sun-fill"
    case gearSix = "gear-six"
    case speakerHigh = "speaker-high", speakerSlash = "speaker-slash"
    case x, list
    case pushPin = "push-pin", pushPinFill = "push-pin-fill"
    case arrowUp = "arrow-up", arrowUpRight = "arrow-up-right"
    case warningCircleFill = "warning-circle-fill"
    case shieldWarningFill = "shield-warning-fill"
    case terminalWindowFill = "terminal-window-fill"
    case githubLogoFill = "github-logo-fill"
    case whatsappLogoFill = "whatsapp-logo-fill"
    case triangleFill = "triangle-fill"
    case plugsConnected = "plugs-connected"
    case magnifyingGlass = "magnifying-glass"
    case sparkleFill = "sparkle-fill"
    case lightning
    case appWindow = "app-window"
    case caretDown = "caret-down", caretUp = "caret-up"
    case checkCircleFill = "check-circle-fill"
    case squaresFour = "squares-four"
    case chatsCircle = "chats-circle"
    case rectangle, plug
    case chartBar = "chart-bar", trash
    case stripeLogoFill = "stripe-logo-fill"
    case caretLeft = "caret-left"
    case starFill = "star-fill", stack
    case image, videoCamera = "video-camera", waveform, file, smiley
    case mapPin = "map-pin", userCircle = "user-circle", chatDots = "chat-dots", usersThreeFill = "users-three-fill"
    case arrowCircleDownFill = "arrow-circle-down-fill"
    case check
    case copySimple = "copy-simple", exclamationMark = "exclamation-mark"
    case calendarBlankFill = "calendar-blank-fill", checkSquareFill = "check-square-fill"
    case googleLogoFill = "google-logo-fill", noteFill = "note-fill"
    case microphone, arrowClockwise = "arrow-clockwise", pencilSimple = "pencil-simple"
    case arrowsOutSimple = "arrows-out-simple", arrowsInSimple = "arrows-in-simple"
    case eye, eyeSlash = "eye-slash"
    // The plan 2 pages (Agenda, Reminders, Notes, Google, Work, Memory) and the work page's run controls.
    case calendarBlank = "calendar-blank", bellRinging = "bell-ringing", note, googleLogo = "google-logo"
    case briefcase, brain, play, stop, pause
    // The Mac connectors: Mail on the strip, the reminder circle, the agenda month arrows.
    case envelopeSimpleFill = "envelope-simple-fill", envelopeSimple = "envelope-simple"
    case checkCircle = "check-circle", circle, caretRight = "caret-right"

    public func url() -> URL? {
        Bundle.module.url(forResource: rawValue, withExtension: "svg", subdirectory: "Icons")
    }
}
