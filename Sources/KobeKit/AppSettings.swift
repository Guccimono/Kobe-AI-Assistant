import Foundation
import Observation

/// How the assistant talks: to the point, friendly, or as little as possible.
public enum AssistantTone: String, CaseIterable, Sendable {
    case direct, warm, brief
}

/// Kobe's preferences, in UserDefaults (domain com.kobe-assistant.app when running as the app).
@MainActor
@Observable
public final class AppSettings {
    public static let autoCloseChoices = [10, 15, 30]

    @ObservationIgnored private let defaults: UserDefaults

    public var serverURL: String {
        didSet {
            defaults.set(serverURL, forKey: "serverURL")
            serverURLMirror.value = Self.url(serverURL)
        }
    }
    public nonisolated static let defaultServerURL = "http://127.0.0.1:8642"
    /// `serverURL` as a URL, readable from any thread (the Hermes client reads it on every request).
    @ObservationIgnored private let serverURLMirror = NSLockedBox(URL(string: AppSettings.defaultServerURL)!)
    public nonisolated var currentServerURL: URL { serverURLMirror.value }
    /// A typed address that doesn't parse falls back to the default.
    public nonisolated static func url(_ text: String) -> URL { URL(string: text) ?? URL(string: defaultServerURL)! }

    public var exchangeFolder: String { didSet { defaults.set(exchangeFolder, forKey: "exchangeFolder") } }
    /// Two-user mode: the engine runs as another macOS user and shares the exchange folder through group `staff`.
    /// Turning it on moves a still-default exchange folder to the shared one (and back when it turns off); a folder
    /// the person typed stays.
    public var engineSeparateUser: Bool {
        didSet {
            defaults.set(engineSeparateUser, forKey: "engineSeparateUser")
            guard oldValue != engineSeparateUser else { return }
            if engineSeparateUser, exchangeFolder == ExchangeSettings.defaultFolder {
                exchangeFolder = ExchangeSettings.sharedFolder
            } else if !engineSeparateUser, exchangeFolder == ExchangeSettings.sharedFolder {
                exchangeFolder = ExchangeSettings.defaultFolder
            }
        }
    }
    /// Where drops, snapshots, requests and results go, and how they are shared.
    public var exchange: ExchangeSettings { ExchangeSettings(folder: exchangeFolder, shared: engineSeparateUser) }
    public var openOnHover: Bool { didSet { defaults.set(openOnHover, forKey: "openOnHover") } }
    /// Off: the open notch stays when the pointer leaves; only a click outside, Esc or ✕ closes it.
    public var closeOnLeave: Bool { didSet { defaults.set(closeOnLeave, forKey: "closeOnLeave") } }
    /// Minutes after folding that the notch reopens on the page it folded on (0: always Home).
    public var resumeMinutes: Int { didSet { defaults.set(resumeMinutes, forKey: "resumeMinutes") } }
    /// What Home opens on (`HomeLayout.opening`).
    public var homeStart: HomeStart { didSet { defaults.set(homeStart.rawValue, forKey: "homeStart") } }
    /// First-run progress, stored as a JSON string under `onboarding`.
    public var onboarding: OnboardingProgress {
        didSet {
            if let data = try? JSONEncoder().encode(onboarding), let text = String(data: data, encoding: .utf8) {
                defaults.set(text, forKey: "onboarding")
            }
        }
    }
    /// Typing into the composer folds Now to its rail.
    public var foldNowOnType: Bool { didSet { defaults.set(foldNowOnType, forKey: "foldNowOnType") } }
    /// How many times the "Return sends" hint has been shown.
    public var returnHintsShown: Int { didSet { defaults.set(returnHintsShown, forKey: "returnHintsShown") } }
    /// The composer's unsent text, kept between launches (never a key; see `DraftRules`).
    public var composerDraft: String { didSet { defaults.set(composerDraft, forKey: "composerDraft") } }
    /// Amounts drawn as "€•••" (the Stripe page's eye, ⌘H).
    public var hideAmounts: Bool { didSet { defaults.set(hideAmounts, forKey: "hideAmounts") } }
    /// How long a finished or notification view stays before the island folds: 10, 15 or 30 seconds.
    public var autoCloseSeconds: Int {
        didSet {
            let clamped = Self.nearestAutoClose(autoCloseSeconds)
            if clamped != autoCloseSeconds { autoCloseSeconds = clamped; return }
            defaults.set(autoCloseSeconds, forKey: "autoCloseSeconds")
        }
    }
    public var soundOn: Bool { didSet { defaults.set(soundOn, forKey: "soundOn") } }
    public var soundVolume: Double { didSet { defaults.set(soundVolume, forKey: "soundVolume") } }
    /// 0 = the default size.
    public var notchHeight: Double { didSet { defaults.set(notchHeight, forKey: "notchHeight") } }
    public var notchWidth: Double { didSet { defaults.set(notchWidth, forKey: "notchWidth") } }
    public var quickAskHotkey: String { didSet { defaults.set(quickAskHotkey, forKey: "quickAskHotkey") } }
    /// Seconds the Claude Code hook waits for an answer in the notch (read by kobe-hook as `claudeWait`).
    public var claudeWait: Int { didSet { defaults.set(claudeWait, forKey: "claudeWait") } }
    public var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin") } }
    /// Kobe reads its replies aloud (Kokoro on this Mac, else the best macOS voice).
    public var voiceOn: Bool { didSet { defaults.set(voiceOn, forKey: "voiceOn") } }
    /// Kokoro's English voice.
    public var voiceName: String { didSet { defaults.set(voiceName, forKey: "voiceName") } }
    public var voiceSpeed: Double { didSet { defaults.set(voiceSpeed, forKey: "voiceSpeed") } }
    /// The Mac connectors, each off until turned on in Settings › Connections (that click asks macOS).
    public var mailOn: Bool { didSet { defaults.set(mailOn, forKey: "mailOn") } }
    public var agendaOn: Bool { didSet { defaults.set(agendaOn, forKey: "agendaOn") } }
    public var remindersOn: Bool { didSet { defaults.set(remindersOn, forKey: "remindersOn") } }
    public var notesOn: Bool { didSet { defaults.set(notesOn, forKey: "notesOn") } }
    /// Mail and Notes were read once (Automation allowed): "finish setup" is no longer asked.
    public var mailReady: Bool { didSet { defaults.set(mailReady, forKey: "mailReady") } }
    public var notesReady: Bool { didSet { defaults.set(notesReady, forKey: "notesReady") } }
    /// Seconds the pointer rests on the notch before it opens (0…0.6).
    public var hoverDelay: Double {
        didSet {
            let clamped = min(max(hoverDelay, 0), 0.6)
            if clamped != hoverDelay { hoverDelay = clamped; return }
            defaults.set(hoverDelay, forKey: "hoverDelay")
        }
    }
    /// Where Kobe shows: the notch island, the menu bar dropdown, or both. One always stays on.
    public var showNotch: Bool {
        didSet {
            if !showNotch && !showMenuBar { showMenuBar = true }
            defaults.set(showNotch, forKey: "showNotch")
        }
    }
    /// What the assistant is called in the app's copy ("Kobe" until the user picks another name).
    public var assistantName: String { didSet { defaults.set(assistantName, forKey: "assistantName") } }
    /// What the assistant does for the user, in their words ("" until asked).
    public var assistantRole: String { didSet { defaults.set(assistantRole, forKey: "assistantRole") } }
    public var assistantTone: AssistantTone { didSet { defaults.set(assistantTone.rawValue, forKey: "assistantTone") } }
    /// The brain picked in onboarding; the connect step hands its key to the engine.
    public var selectedBrain: Brain { didSet { defaults.set(selectedBrain.rawValue, forKey: "selectedBrain") } }
    /// Kobe wrote the engine's SOUL.md, so the personality is already there: chats need no system prompt.
    public var profileInSoul: Bool { didSet { defaults.set(profileInSoul, forKey: "profileInSoul") } }
    /// The engine ignored the session's system prompt: the personality applies only through the Kobe skill.
    public var profileSkillOnly: Bool { didSet { defaults.set(profileSkillOnly, forKey: "profileSkillOnly") } }
    /// Onboarding's brain step: the person kept the brain Hermes already had, so Kobe hands over no key.
    public var brainKeptFromHermes: Bool { didSet { defaults.set(brainKeptFromHermes, forKey: "brainKeptFromHermes") } }
    /// The app's words about the assistant, in its name.
    public var copy: Copy { Copy(name: assistantName) }

    public var showMenuBar: Bool {
        didSet {
            if !showMenuBar && !showNotch { showNotch = true }
            defaults.set(showMenuBar, forKey: "showMenuBar")
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverURL = defaults.string(forKey: "serverURL") ?? Self.defaultServerURL
        exchangeFolder = defaults.string(forKey: "exchangeFolder") ?? ExchangeSettings.defaultFolder
        engineSeparateUser = defaults.bool(forKey: "engineSeparateUser")
        openOnHover = defaults.object(forKey: "openOnHover") as? Bool ?? true
        closeOnLeave = defaults.object(forKey: "closeOnLeave") as? Bool ?? true
        resumeMinutes = defaults.object(forKey: "resumeMinutes") as? Int ?? 5
        homeStart = defaults.string(forKey: "homeStart").flatMap(HomeStart.init(rawValue:)) ?? .writing
        onboarding = defaults.string(forKey: "onboarding")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(OnboardingProgress.self, from: $0) } ?? OnboardingProgress()
        foldNowOnType = defaults.object(forKey: "foldNowOnType") as? Bool ?? true
        returnHintsShown = defaults.integer(forKey: "returnHintsShown")
        composerDraft = defaults.string(forKey: "composerDraft") ?? ""
        hideAmounts = defaults.bool(forKey: "hideAmounts")
        autoCloseSeconds = Self.nearestAutoClose(defaults.object(forKey: "autoCloseSeconds") as? Int ?? 15)
        soundOn = defaults.object(forKey: "soundOn") as? Bool ?? false
        soundVolume = defaults.object(forKey: "soundVolume") as? Double ?? 0.5
        notchHeight = defaults.double(forKey: "notchHeight")
        notchWidth = defaults.double(forKey: "notchWidth")
        quickAskHotkey = defaults.string(forKey: "quickAskHotkey") ?? "ctrl+opt+space"
        claudeWait = defaults.object(forKey: "claudeWait") as? Int ?? 90
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? true
        hoverDelay = min(max(defaults.object(forKey: "hoverDelay") as? Double ?? 0.1, 0), 0.6)
        voiceOn = defaults.object(forKey: "voiceOn") as? Bool ?? false
        voiceName = defaults.string(forKey: "voiceName") ?? "af_heart"
        voiceSpeed = defaults.object(forKey: "voiceSpeed") as? Double ?? 1.0
        mailOn = defaults.bool(forKey: "mailOn")
        agendaOn = defaults.bool(forKey: "agendaOn")
        remindersOn = defaults.bool(forKey: "remindersOn")
        notesOn = defaults.bool(forKey: "notesOn")
        mailReady = defaults.bool(forKey: "mailReady")
        notesReady = defaults.bool(forKey: "notesReady")
        let notch = defaults.object(forKey: "showNotch") as? Bool ?? true
        let menuBar = defaults.object(forKey: "showMenuBar") as? Bool ?? true
        showNotch = notch || !menuBar
        showMenuBar = menuBar
        assistantName = defaults.string(forKey: "assistantName") ?? Copy.defaultName
        assistantRole = defaults.string(forKey: "assistantRole") ?? ""
        assistantTone = defaults.string(forKey: "assistantTone").flatMap(AssistantTone.init(rawValue:)) ?? .direct
        selectedBrain = defaults.string(forKey: "selectedBrain").flatMap(Brain.init(rawValue:)) ?? .claude
        profileInSoul = defaults.bool(forKey: "profileInSoul")
        profileSkillOnly = defaults.bool(forKey: "profileSkillOnly")
        brainKeptFromHermes = defaults.bool(forKey: "brainKeptFromHermes")
        serverURLMirror.value = Self.url(serverURL)
    }

    public func isOn(_ kind: MacKind) -> Bool {
        switch kind {
        case .mail: mailOn
        case .agenda: agendaOn
        case .reminders: remindersOn
        case .notes: notesOn
        }
    }

    public func setOn(_ kind: MacKind, _ on: Bool) {
        switch kind {
        case .mail: mailOn = on
        case .agenda: agendaOn = on
        case .reminders: remindersOn = on
        case .notes: notesOn = on
        }
    }

    static func nearestAutoClose(_ seconds: Int) -> Int {
        autoCloseChoices.min { abs($0 - seconds) < abs($1 - seconds) } ?? 15
    }
}
