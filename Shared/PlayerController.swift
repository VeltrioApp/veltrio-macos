import Foundation
import Observation

/// The player that is currently on screen, if any.
///
/// The app's Playback menu has to reach across the view hierarchy to
/// drive the player, but the player owns its controller as `@State`
/// inside `PlayerView`. This registry is the bridge: the player
/// registers itself on appear and clears it on disappear, and the menu
/// commands act on whatever is registered.
///
/// Nil means nothing is playing, so the menu commands disable
/// themselves rather than failing silently.
@Observable
final class ActivePlayback {
    static let shared = ActivePlayback()

    private(set) var controller: PlayerController?

    private init() {}

    func register(_ controller: PlayerController) {
        self.controller = controller
    }

    /// Clears the registration, but only if `controller` is still the
    /// active one — a player being torn down must not unregister the
    /// player that replaced it.
    func unregister(_ controller: PlayerController) {
        if self.controller === controller {
            self.controller = nil
        }
    }
}

/// Observable controller that bridges SwiftUI state and the underlying
/// `mpv_handle`. The MPV view publishes property changes here, and the
/// UI drives commands (seek, pause, volume, track selection) through the
/// same object.
@Observable
final class PlayerController {
    // Playback state (observed from mpv).
    var position: Double = 0
    var duration: Double = 0
    var isPaused: Bool = false
    var isBuffering: Bool = false
    var volume: Double = 100
    var isMuted: Bool = false
    var eofReached: Bool = false
    var speed: Double = 1.0

    // Tracks (refreshed on MPV_EVENT_FILE_LOADED).
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var currentAudioId: Int64 = 0       // 0 = none
    var currentSubtitleId: Int64 = 0    // 0 = off

    // Last error surfaced by mpv (MPV_EVENT_END_FILE reason=error). Nil
    // while playback is healthy; the player page watches this to show the
    // Retry UI instead of a black screen.
    var playbackError: String?

    // A/V sync offsets in seconds.
    var subDelay: Double = 0
    var audioDelay: Double = 0

    // Addon-fetched subtitles (populated by PlayerView after resolve).
    var externalSubtitles: [AddonSubtitle] = []
    var isFetchingExternalSubs: Bool = false

    // --- Image framing ---
    var aspectMode: AspectMode = .auto
    var videoZoom: Double = 0        // 0 = fit, >0 crops, <0 shrinks

    // --- Advanced mpv config ---
    var toneMappingPreset: ToneMappingPreset = .auto
    var audioPassthroughEnabled: Bool = false   // DTS/AC3/EAC3 bitstream
    var playbackProfile: PlaybackProfile = .balanced

    // --- Media-info panel readback ---
    var videoCodec: String?
    var audioCodec: String?
    var videoResolution: String?
    var videoFps: Double?
    var videoBitrate: Int64?
    var hdrDetected: Bool = false

    // --- Chapters / skip-intro ---
    struct Chapter: Hashable {
        let index: Int
        let title: String
        let startSeconds: Double
    }
    var chapters: [Chapter] = []
    var currentChapterIndex: Int = -1
    /// True when the current chapter's title looks like an intro/opening.
    var isInSkippableIntro: Bool = false
    /// Next chapter time — the target of a "Skip intro" click.
    var nextChapterTimeAfterIntro: Double?
    /// External segments from IntroDB (api.introdb.app/segments) when the file
    /// has no chapter markers: recap, intro, and outro.
    var externalRecapWindow: (start: Double, end: Double)?
    var externalIntroWindow: (start: Double, end: Double)?
    var externalOutroWindow: (start: Double, end: Double)?

    enum SkippableKind: Equatable {
        case recap
        case intro
    }

    var activeSkippableSegment: (kind: SkippableKind, end: Double)? {
        guard !isBuffering, position >= 2.0 else { return nil }
        if let w = externalRecapWindow, position >= w.start && position < w.end - 1.0 {
            return (.recap, w.end)
        }
        if isInSkippableIntro, let target = nextChapterTimeAfterIntro {
            return (.intro, target)
        }
        if let w = externalIntroWindow, position >= w.start && position < w.end - 1.0 {
            return (.intro, w.end)
        }
        return nil
    }

    var effectiveIsInSkippableIntro: Bool { activeSkippableSegment != nil }

    var isInOutroWindow: Bool {
        if let w = externalOutroWindow, position >= w.start && position < w.end {
            return true
        }
        // Fallback when IntroDB has no outro or file timing differs: trigger in the last 45s of an episode.
        if duration > 180 && position > 0 && (duration - position) <= 45 {
            return true
        }
        return false
    }

    // Set by MPVOpenGLView when it initializes. Weak so a torn-down view
    // doesn't keep itself alive through a controller the UI still holds.
    weak var view: MPVEngine?

    enum AspectMode: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case fit = "Fit"
        case fill = "Fill"
        case stretch = "Stretch"
        case s16_9 = "16:9"
        case s4_3  = "4:3"
        case s21_9 = "21:9"
        case s235_1 = "2.35:1"
        var id: String { rawValue }

        /// mpv `video-aspect-override` value.
        var mpvValue: String {
            switch self {
            case .auto:    return "-1"
            case .fit:     return "no"
            case .fill, .stretch: return "no"
            case .s16_9:   return "16:9"
            case .s4_3:    return "4:3"
            case .s21_9:   return "21:9"
            case .s235_1:  return "2.35"
            }
        }
        var mpvUnscaled: String {
            switch self {
            case .fill, .stretch: return "yes"
            default: return "no"
            }
        }
    }

    enum ToneMappingPreset: String, CaseIterable, Identifiable {
        case auto       = "Auto"
        case bt2446a    = "BT.2446A (balanced)"
        case bt2390     = "BT.2390 (cinematic)"
        case hable      = "Hable"
        case reinhard   = "Reinhard"
        case clip       = "Clip (no tone-map)"
        var id: String { rawValue }
        /// mpv `tone-mapping` value.
        var mpvValue: String {
            switch self {
            case .auto:     return "auto"
            case .bt2446a:  return "bt.2446a"
            case .bt2390:   return "bt.2390"
            case .hable:    return "hable"
            case .reinhard: return "reinhard"
            case .clip:     return "clip"
            }
        }
    }

    /// Macro profile for one-click tuning: each preset collapses several
    /// mpv options. Overridable per-session via the dedicated pickers.
    enum PlaybackProfile: String, CaseIterable, Identifiable {
        case balanced   = "Balanced"
        case quality    = "Max quality"
        case performance = "Performance"
        case audiophile = "Audiophile"
        var id: String { rawValue }
        var blurb: String {
            switch self {
            case .balanced:    return "Safe defaults — good on any Mac."
            case .quality:     return "Best picture, higher CPU; HDR tone-mapping tuned."
            case .performance: return "Low CPU, low power; drops advanced scalers."
            case .audiophile:  return "Bitstream DTS/AC3/EAC3 to AVR; higher audio buffer."
            }
        }
    }

    func togglePause() {
        isPaused.toggle()
        view?.setPaused(isPaused)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        view?.setPaused(paused)
    }

    func seek(to seconds: Double) {
        let clamped = max(0, duration > 0 ? min(seconds, duration) : seconds)
        position = clamped
        view?.seek(to: clamped)
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    func setVolume(_ v: Double) {
        let clamped = max(0, min(100, v))
        volume = clamped
        view?.setVolume(clamped)
    }

    func toggleMute() {
        isMuted.toggle()
        view?.setMuted(isMuted)
    }

    func setAudioTrack(_ id: Int64) {
        currentAudioId = id
        view?.setAudioTrack(id)
    }

    func setSubtitleTrack(_ id: Int64) {
        currentSubtitleId = id
        view?.setSubtitleTrack(id)
    }

    func setSpeed(_ s: Double) {
        speed = s
        view?.setSpeed(s)
    }

    func setSubDelay(_ s: Double) { subDelay = s; view?.setSubDelay(s) }
    func bumpSubDelay(by step: Double) { setSubDelay(subDelay + step) }

    func setAudioDelay(_ s: Double) { audioDelay = s; view?.setAudioDelay(s) }
    func bumpAudioDelay(by step: Double) { setAudioDelay(audioDelay + step) }

    func addExternalSubtitle(url: String, title: String? = nil, lang: String? = nil, select: Bool = true) {
        view?.addSubtitle(url: url, select: select, title: title, lang: lang)
    }

    // MARK: - advanced playback controls

    func setAspectMode(_ mode: AspectMode) {
        aspectMode = mode
        view?.setAspectMode(mode)
    }

    func setZoom(_ z: Double) {
        let clamped = max(-1.0, min(2.0, z))
        videoZoom = clamped
        view?.setZoom(clamped)
    }

    func bumpZoom(by step: Double) { setZoom(videoZoom + step) }
    func resetZoom() { setZoom(0); setAspectMode(.auto) }

    func setToneMappingPreset(_ p: ToneMappingPreset) {
        toneMappingPreset = p
        view?.setToneMapping(p)
    }

    func setAudioPassthrough(_ enabled: Bool) {
        audioPassthroughEnabled = enabled
        view?.setAudioPassthrough(enabled)
    }

    /// Seek to the end of the current recap/intro chapter or IntroDB window.
    func skipIntro() {
        if let seg = activeSkippableSegment {
            seek(to: seg.end)
        }
    }

    func applyPlaybackProfile(_ p: PlaybackProfile) {
        playbackProfile = p
        view?.applyPlaybackProfile(p)
    }

    func setSubtitleAppearance(scale: Double, color: String) {
        view?.setSubtitleAppearance(scale: scale, color: color)
    }

    func applyLanguagePreferences(audio: String, subtitle: String) {
        view?.setPreferredAudioLanguage(audio.isEmpty ? nil : audio)
        view?.setPreferredSubtitleLanguage(subtitle.isEmpty ? nil : subtitle)
        let d = UserDefaults.standard
        let scale = (d.object(forKey: "veltrio.pref.subtitleScale") as? Double) ?? 1.0
        let color = d.string(forKey: "veltrio.pref.subtitleColor") ?? "#FFFFFFFF"
        view?.setSubtitleAppearance(scale: scale, color: color)
    }
}

/// Automatic TV episode recap / intro / outro detection via IntroDB (api.introdb.app).
enum IntroService {
    struct Segments: Sendable {
        let recap: (start: Double, end: Double)?
        let intro: (start: Double, end: Double)?
        let outro: (start: Double, end: Double)?
    }

    private struct WindowDTO: Decodable {
        let start_sec: Double?
        let end_sec: Double?
        var valid: (start: Double, end: Double)? {
            guard let s = start_sec, let e = end_sec, e > s + 2.0 else { return nil }
            return (s, e)
        }
    }

    private struct SegmentsResp: Decodable {
        let recap: WindowDTO?
        let intro: WindowDTO?
        let outro: WindowDTO?
    }

    static func fetchSegments(imdbId: String, season: Int, episode: Int) async -> Segments? {
        guard imdbId.hasPrefix("tt"), season > 0, episode > 0,
              let url = URL(string: "https://api.introdb.app/segments?imdb_id=\(imdbId)&season=\(season)&episode=\(episode)")
        else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let (data, resp) = try? await URLSession.shared.data(for: req),
           let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
           let decoded = try? JSONDecoder().decode(SegmentsResp.self, from: data) {
            let segs = Segments(recap: decoded.recap?.valid, intro: decoded.intro?.valid, outro: decoded.outro?.valid)
            if segs.recap != nil || segs.intro != nil || segs.outro != nil { return segs }
        }
        // Fallback to /intro endpoint if /segments had nothing.
        if let introUrl = URL(string: "https://api.introdb.app/intro?imdb_id=\(imdbId)&season=\(season)&episode=\(episode)") {
            var ireq = URLRequest(url: introUrl)
            ireq.timeoutInterval = 8
            ireq.setValue("application/json", forHTTPHeaderField: "Accept")
            if let (data, resp) = try? await URLSession.shared.data(for: ireq),
               let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let decoded = try? JSONDecoder().decode(WindowDTO.self, from: data),
               let valid = decoded.valid {
                return Segments(recap: nil, intro: valid, outro: nil)
            }
        }
        return nil
    }
}
