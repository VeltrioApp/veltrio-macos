import SwiftUI
import AppKit
import OpenGL.GL
import OpenGL.GL3
import Darwin
import Observation
import Libmpv


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

    // Set by MPVOpenGLView when it initializes. Weak so a torn-down view
    // doesn't keep itself alive through a controller the UI still holds.
    weak var view: MPVOpenGLView?

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

    /// Seek to the end of the current "intro" chapter. No-op when no
    /// intro is detected at the playhead.
    func skipIntro() {
        guard let target = nextChapterTimeAfterIntro else { return }
        seek(to: target)
    }

    func applyPlaybackProfile(_ p: PlaybackProfile) {
        playbackProfile = p
        view?.applyPlaybackProfile(p)
    }

    func applyLanguagePreferences(audio: String, subtitle: String) {
        view?.setPreferredAudioLanguage(audio.isEmpty ? nil : audio)
        view?.setPreferredSubtitleLanguage(subtitle.isEmpty ? nil : subtitle)
    }
}

/// SwiftUI view backed by libmpv. HDR, 10-bit, DTS/TrueHD passthrough,
/// hardware decode: all handled by mpv. We just hand it a URL and render
/// into an `NSOpenGLView` via mpv's render API.
struct MPVPlayer: NSViewRepresentable {
    let url: URL
    let controller: PlayerController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MPVOpenGLView {
        let view = MPVOpenGLView(frame: .zero)
        view.controller = controller
        controller.view = view
        view.load(url: url.absoluteString)
        context.coordinator.view = view
        context.coordinator.lastURL = url.absoluteString
        return view
    }

    func updateNSView(_ nsView: MPVOpenGLView, context: Context) {
        if context.coordinator.lastURL != url.absoluteString {
            nsView.load(url: url.absoluteString)
            context.coordinator.lastURL = url.absoluteString
        }
    }

    static func dismantleNSView(_ nsView: MPVOpenGLView, coordinator: Coordinator) {
        nsView.shutdown()
    }

    final class Coordinator {
        weak var view: MPVOpenGLView?
        var lastURL: String?
    }
}

/// Owns the `mpv_handle` and its OpenGL render context. The view's lifetime
/// is explicitly scoped: it's safe to create, swap URLs on, and tear down —
/// `shutdown()` is idempotent and must be called before the view disappears.
final class MPVOpenGLView: NSOpenGLView {
    private var mpv: OpaquePointer?
    private var mpvGL: OpaquePointer?
    private var queuedURL: String?
    private var initialized = false
    private var isShutdown = false
    weak var controller: PlayerController?

    /// Live-pointer registry so the C callbacks can decide whether the
    /// view is still around without holding a strong reference to it.
    /// Opaque pointer into this dictionary is handed to `mpv_*_callback`,
    /// so a freed view simply isn't in the map any more.
    private static var liveViews: [UnsafeMutableRawPointer: Weak] = [:]
    private static let liveLock = NSLock()
    private final class Weak { weak var view: MPVOpenGLView?; init(_ v: MPVOpenGLView) { view = v } }
    private var selfToken: UnsafeMutableRawPointer!

    override init(frame frameRect: NSRect) {
        // Try accelerated core-profile first, then fall back for VMs and
        // remote sessions. Crashing the app on a missing pixel format isn't
        // acceptable; we just lose hardware acceleration.
        let primary: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFAAllowOfflineRenderers),
            0,
        ]
        let fallback: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAAllowOfflineRenderers),
            0,
        ]
        let pf = NSOpenGLPixelFormat(attributes: primary)
            ?? NSOpenGLPixelFormat(attributes: fallback)
            ?? NSOpenGLPixelFormat(attributes: [UInt32(NSOpenGLPFADoubleBuffer), 0])
        if let pf {
            super.init(frame: frameRect, pixelFormat: pf)!
        } else {
            NSLog("MPV: no usable OpenGL pixel format; running without one")
            super.init(frame: frameRect, pixelFormat: NSOpenGLPixelFormat())!
        }
        wantsBestResolutionOpenGLSurface = true
        autoresizingMask = [.width, .height]

        selfToken = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        Self.liveLock.lock()
        Self.liveViews[selfToken] = Weak(self)
        Self.liveLock.unlock()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Look up a view by its token; returns nil if the view has been
    /// deallocated or torn down. Called from the mpv C thread.
    private static func resolve(_ token: UnsafeMutableRawPointer?) -> MPVOpenGLView? {
        guard let token else { return nil }
        liveLock.lock(); defer { liveLock.unlock() }
        return liveViews[token]?.view
    }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        guard let context = openGLContext else { return }
        context.makeCurrentContext()
        var swap: GLint = 1
        context.setValues(&swap, for: .swapInterval)

        mpv = mpv_create()
        guard let mpv else { return }

        // CRITICAL: route video output through the libmpv render API so mpv
        // draws into our NSOpenGLView's FBO instead of spawning its own
        // standalone window (the default `vo=gpu` would do exactly that).
        setOption("vo", "libmpv")
        setOption("force-window", "no")
        setOption("terminal", "no")
        setOption("input-default-bindings", "no")
        setOption("input-vo-keyboard", "no")

        // Lock mpv down to the network protocols we actually route through
        // it. Without this a hostile addon stream could hand us a
        // file://, smb://, cdda:// or EDL playlist that reads local files
        // or probes the local network on our behalf.
        setOption("demuxer-lavf-o", "protocol_whitelist=file,crypto,data,http,https,tcp,tls,hls,rtmp,rtmps,udp,rtp")
        setOption("load-unsafe-playlists", "no")

        // Sensible defaults; user prefs can override later via a plist.
        setOption("hwdec", "auto-safe")
        setOption("keep-open", "yes")
        setOption("audio-channels", "auto-safe")
        setOption("cache", "yes")
        setOption("demuxer-max-bytes", "150MiB")
        setOption("demuxer-max-back-bytes", "75MiB")
        setOption("ytdl", "no")  // we hand mpv direct URLs, never YouTube pages
        setOption("osc", "no")

        mpv_request_log_messages(mpv, "warn")
        guard mpv_initialize(mpv) >= 0 else {
            NSLog("MPV: mpv_initialize failed")
            return
        }

        // Listen for property changes we'd like to drive the UI with.
        mpv_observe_property(mpv, 1, "time-pos",    MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 2, "duration",    MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 3, "pause",       MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 4, "volume",      MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 5, "mute",        MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 6, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 7, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 8, "aid",         MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 9, "sid",         MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 10, "speed",      MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 11, "sub-delay",  MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 12, "audio-delay", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 13, "chapter",     MPV_FORMAT_INT64)

        // Wakeup callback → main-thread event drain. Keeps SwiftUI state
        // updates on the right queue without us polling. We pass a token
        // into our weak-view registry rather than an unretained pointer
        // so a late-firing callback after teardown resolves to nil safely.
        mpv_set_wakeup_callback(mpv, { data in
            DispatchQueue.main.async { [data] in
                guard let view = MPVOpenGLView.resolve(data) else { return }
                view.drainEvents()
            }
        }, selfToken)

        setupRenderContext()
        initialized = true

        if let url = queuedURL {
            loadInternal(url)
            queuedURL = nil
        }
    }

    // MARK: - event drain

    private func drainEvents() {
        guard let mpv, !isShutdown else { return }
        while true {
            guard let evPtr = mpv_wait_event(mpv, 0) else { break }
            let event = evPtr.pointee
            if event.event_id == MPV_EVENT_NONE { break }
            if event.event_id == MPV_EVENT_SHUTDOWN { return }

            switch event.event_id {
            case MPV_EVENT_FILE_LOADED:
                // Fresh file → re-read the track list so audio/subs menus
                // reflect what's actually available. Also wipe any stale
                // end-of-file state carried from the previous file.
                controller?.eofReached = false
                controller?.playbackError = nil
                refreshTracks()
                refreshMediaInfo()
                refreshChapters()

            case MPV_EVENT_END_FILE:
                if let data = event.data {
                    let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    if end.reason == MPV_END_FILE_REASON_ERROR {
                        // Translate the mpv error code into a readable string.
                        let cmsg = mpv_error_string(end.error)
                        let msg = cmsg.map { String(cString: $0) } ?? String(localized: "Unknown playback error")
                        controller?.playbackError = msg
                    } else if end.reason == MPV_END_FILE_REASON_EOF {
                        controller?.eofReached = true
                    }
                }

            case MPV_EVENT_LOG_MESSAGE:
                if let data = event.data {
                    let log = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    let prefix = String(cString: log.prefix)
                    let text = String(cString: log.text).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        NSLog("MPV[%@] %@", prefix, DebugLog.redact(text))
                    }
                }

            case MPV_EVENT_PROPERTY_CHANGE:
                if let data = event.data {
                    let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                    let name = String(cString: prop.name)
                    apply(propertyName: name, format: prop.format, data: prop.data)
                }

            default:
                break
            }
        }
    }

    /// Enumerate `track-list/*` and push audio + subtitle tracks into the
    /// controller. Called on MPV_EVENT_FILE_LOADED (and anywhere else the
    /// track set might have changed).
    private func refreshTracks() {
        guard let mpv, let controller else { return }
        var count: Int64 = 0
        guard mpv_get_property(mpv, "track-list/count", MPV_FORMAT_INT64, &count) >= 0 else { return }

        var audio: [MediaTrack] = []
        var subs:  [MediaTrack] = []

        for i in 0..<count {
            let base = "track-list/\(i)"
            guard let type = readString("\(base)/type") else { continue }
            let id       = readInt64("\(base)/id") ?? 0
            let lang     = readString("\(base)/lang")
            let title    = readString("\(base)/title")
            let codec    = readString("\(base)/codec")
            let isDef    = readFlag("\(base)/default") ?? false
            let isForced = readFlag("\(base)/forced") ?? false

            let track = MediaTrack(
                id: id, lang: lang, title: title, codec: codec,
                isDefault: isDef, isForced: isForced
            )
            switch type {
            case "audio": audio.append(track)
            case "sub":   subs.append(track)
            default: break
            }
        }

        controller.audioTracks    = audio
        controller.subtitleTracks = subs
        controller.currentAudioId    = readInt64("aid") ?? 0
        controller.currentSubtitleId = readInt64("sid") ?? 0
        controller.speed             = readDouble("speed") ?? 1.0
    }

    /// Read codec / resolution / bitrate / HDR flag and push into the
    /// controller so the media-info panel can display them. One-shot on
    /// file-loaded.
    private func refreshMediaInfo() {
        guard let controller else { return }
        controller.videoCodec = readString("video-codec")
        controller.audioCodec = readString("audio-codec")
        let w = readInt64("width")
        let h = readInt64("height")
        if let w, let h, w > 0, h > 0 {
            controller.videoResolution = "\(w)×\(h)"
        } else {
            controller.videoResolution = nil
        }
        controller.videoFps = readDouble("estimated-vf-fps")
        controller.videoBitrate = readInt64("video-bitrate")
        // HDR detection: presence of HDR primaries or PQ transfer tags.
        let prim = readString("video-params/primaries")?.lowercased() ?? ""
        let gamma = readString("video-params/gamma")?.lowercased() ?? ""
        controller.hdrDetected = prim.contains("bt.2020")
            || gamma.contains("pq")
            || gamma.contains("hlg")
    }

    // ---- small typed helpers over mpv_get_property ----

    private func readString(_ name: String) -> String? {
        guard let mpv else { return nil }
        guard let cstr = mpv_get_property_string(mpv, name) else { return nil }
        let s = String(cString: cstr)
        mpv_free(UnsafeMutableRawPointer(cstr))
        return s.isEmpty ? nil : s
    }

    private func readInt64(_ name: String) -> Int64? {
        guard let mpv else { return nil }
        var v: Int64 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_INT64, &v) >= 0 ? v : nil
    }

    private func readDouble(_ name: String) -> Double? {
        guard let mpv else { return nil }
        var v: Double = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &v) >= 0 ? v : nil
    }

    private func readFlag(_ name: String) -> Bool? {
        guard let mpv else { return nil }
        var v: Int32 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &v) >= 0 ? v != 0 : nil
    }

    private func apply(propertyName name: String, format: mpv_format, data: UnsafeMutableRawPointer?) {
        guard let controller else { return }
        switch (name, format) {
        case ("time-pos", MPV_FORMAT_DOUBLE):
            if let p = data?.assumingMemoryBound(to: Double.self).pointee {
                controller.position = p
            }
        case ("duration", MPV_FORMAT_DOUBLE):
            if let p = data?.assumingMemoryBound(to: Double.self).pointee {
                controller.duration = p
            }
        case ("pause", MPV_FORMAT_FLAG):
            if let p = data?.assumingMemoryBound(to: Int32.self).pointee {
                controller.isPaused = p != 0
            }
        case ("volume", MPV_FORMAT_DOUBLE):
            if let p = data?.assumingMemoryBound(to: Double.self).pointee {
                controller.volume = p
            }
        case ("mute", MPV_FORMAT_FLAG):
            if let p = data?.assumingMemoryBound(to: Int32.self).pointee {
                controller.isMuted = p != 0
            }
        case ("eof-reached", MPV_FORMAT_FLAG):
            // Only propagate FALSE (playback resumed) via this path; TRUE
            // comes from MPV_EVENT_END_FILE, which also distinguishes a
            // normal EOF from an error we need to surface.
            if let p = data?.assumingMemoryBound(to: Int32.self).pointee, p == 0 {
                controller.eofReached = false
            }
        case ("paused-for-cache", MPV_FORMAT_FLAG):
            if let p = data?.assumingMemoryBound(to: Int32.self).pointee {
                controller.isBuffering = p != 0
            }
        case ("aid", MPV_FORMAT_INT64):
            controller.currentAudioId = data?.assumingMemoryBound(to: Int64.self).pointee ?? 0
        case ("sid", MPV_FORMAT_INT64):
            controller.currentSubtitleId = data?.assumingMemoryBound(to: Int64.self).pointee ?? 0
        case ("speed", MPV_FORMAT_DOUBLE):
            if let p = data?.assumingMemoryBound(to: Double.self).pointee {
                controller.speed = p
            }
        case ("sub-delay", MPV_FORMAT_DOUBLE):
            if let p = data?.assumingMemoryBound(to: Double.self).pointee {
                controller.subDelay = p
            }
        case ("audio-delay", MPV_FORMAT_DOUBLE):
            if let p = data?.assumingMemoryBound(to: Double.self).pointee {
                controller.audioDelay = p
            }
        case ("chapter", MPV_FORMAT_INT64):
            let idx = Int(data?.assumingMemoryBound(to: Int64.self).pointee ?? -1)
            controller.currentChapterIndex = idx
            updateSkipIntroState()
        default:
            break
        }
    }

    /// Parse chapters when a file loads. Stashes title + time so the UI
    /// can offer a Skip button.
    private func refreshChapters() {
        guard let mpv, let controller else { return }
        var count: Int64 = 0
        guard mpv_get_property(mpv, "chapter-list/count", MPV_FORMAT_INT64, &count) >= 0 else {
            controller.chapters = []
            controller.isInSkippableIntro = false
            return
        }
        var list: [PlayerController.Chapter] = []
        for i in 0..<count {
            let title = readString("chapter-list/\(i)/title") ?? String(localized: "Chapter \(i + 1)")
            let time  = readDouble("chapter-list/\(i)/time")  ?? 0
            list.append(.init(index: Int(i), title: title, startSeconds: time))
        }
        controller.chapters = list
        controller.currentChapterIndex = Int(readInt64("chapter") ?? -1)
        updateSkipIntroState()
    }

    /// Decide whether the active chapter looks like an intro/opening
    /// sequence; pick the start of the next chapter as the skip target.
    private func updateSkipIntroState() {
        guard let controller else { return }
        let idx = controller.currentChapterIndex
        guard idx >= 0, idx < controller.chapters.count else {
            controller.isInSkippableIntro = false
            controller.nextChapterTimeAfterIntro = nil
            return
        }
        let title = controller.chapters[idx].title.lowercased()
        let hits = ["intro", "opening", "op ", "theme song", "generique", "générique"]
        let looksLikeIntro = hits.contains { title.contains($0) }
        controller.isInSkippableIntro = looksLikeIntro
        if looksLikeIntro, idx + 1 < controller.chapters.count {
            controller.nextChapterTimeAfterIntro = controller.chapters[idx + 1].startSeconds
        } else {
            controller.nextChapterTimeAfterIntro = nil
        }
    }

    // MARK: - render context

    private func setupRenderContext() {
        guard let mpv else { return }
        var apiType: [CChar] = Array("opengl".utf8CString)
        var oglInit = mpv_opengl_init_params(
            get_proc_address: { _, name -> UnsafeMutableRawPointer? in
                guard let name else { return nil }
                return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)  // RTLD_DEFAULT
            },
            get_proc_address_ctx: nil
        )

        var ctx: OpaquePointer?
        apiType.withUnsafeMutableBufferPointer { apiBuf in
            withUnsafeMutablePointer(to: &oglInit) { oglPtr in
                var params: [mpv_render_param] = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                                     data: UnsafeMutableRawPointer(apiBuf.baseAddress)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                                     data: UnsafeMutableRawPointer(oglPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                params.withUnsafeMutableBufferPointer { buf in
                    _ = mpv_render_context_create(&ctx, mpv, buf.baseAddress)
                }
            }
        }
        guard let ctx else {
            NSLog("MPV: render_context_create failed")
            return
        }
        self.mpvGL = ctx

        mpv_render_context_set_update_callback(ctx, { data in
            DispatchQueue.main.async { [data] in
                guard let view = MPVOpenGLView.resolve(data) else { return }
                view.needsDisplay = true
            }
        }, selfToken)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = openGLContext else {
            super.draw(dirtyRect)
            return
        }
        context.makeCurrentContext()
        CGLLockContext(context.cglContextObj!)
        defer { CGLUnlockContext(context.cglContextObj!) }

        // Re-check mpvGL AFTER taking the lock: shutdown() races the main
        // queue and we don't want to render against a freed render context.
        guard let mpvGL = mpvGL, !isShutdown else { return }

        let backing = convertToBacking(bounds.size)
        var fbo = mpv_opengl_fbo(
            fbo: 0,
            w: Int32(backing.width),
            h: Int32(backing.height),
            internal_format: 0
        )
        var flipY: CInt = 1
        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                var params: [mpv_render_param] = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO,
                                     data: UnsafeMutableRawPointer(fboPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y,
                                     data: UnsafeMutableRawPointer(flipPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                params.withUnsafeMutableBufferPointer { buf in
                    _ = mpv_render_context_render(mpvGL, buf.baseAddress)
                }
            }
        }
        context.flushBuffer()
    }

    // MARK: - commands

    func load(url: String) {
        // Reset per-file state so a stale EOF from the previous file can't
        // bounce the player out of a channel zap.
        controller?.eofReached = false
        controller?.playbackError = nil
        controller?.position = 0
        controller?.duration = 0

        if initialized {
            loadInternal(url)
        } else {
            queuedURL = url
        }
    }

    func load(url: String, startSeconds: Double) {
        // Resume playback at a saved offset using mpv's loadfile `start=`
        // option so we don't flash the first frames before seeking.
        controller?.eofReached = false
        controller?.playbackError = nil
        controller?.position = startSeconds
        controller?.duration = 0

        if initialized {
            guard mpv != nil else { return }
            runCommand(["loadfile", url, "replace", "start=\(startSeconds)"])
        } else {
            queuedURL = url
        }
    }

    private func loadInternal(_ url: String) {
        guard mpv != nil else { return }
        runCommand(["loadfile", url])
    }

    func setPaused(_ paused: Bool) {
        guard let mpv else { return }
        var flag: Int32 = paused ? 1 : 0
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
    }

    func setMuted(_ muted: Bool) {
        guard let mpv else { return }
        var flag: Int32 = muted ? 1 : 0
        mpv_set_property(mpv, "mute", MPV_FORMAT_FLAG, &flag)
    }

    func setVolume(_ volume: Double) {
        guard let mpv else { return }
        var v = volume
        mpv_set_property(mpv, "volume", MPV_FORMAT_DOUBLE, &v)
    }

    func seek(to seconds: Double) {
        runCommand(["seek", String(seconds), "absolute", "exact"])
    }

    func setAudioTrack(_ id: Int64) {
        guard let mpv else { return }
        _ = mpv_set_property_string(mpv, "aid", id > 0 ? String(id) : "no")
    }

    func setSubtitleTrack(_ id: Int64) {
        guard let mpv else { return }
        _ = mpv_set_property_string(mpv, "sid", id > 0 ? String(id) : "no")
    }

    func setSpeed(_ speed: Double) {
        guard let mpv else { return }
        var v = speed
        mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &v)
    }

    /// Load an external subtitle file (local or http) and select it.
    /// mpv assigns it the next free sid; refreshTracks picks it up on the
    /// next track-list change.
    func addSubtitle(url: String, select: Bool = true, title: String? = nil, lang: String? = nil) {
        guard mpv != nil else { return }
        var args = ["sub-add", url, select ? "select" : "auto"]
        if let title { args.append(title) }
        if let lang { args.append(lang) }
        runCommand(args)
    }

    /// Positive = subs appear earlier; negative = later. Seconds.
    func setSubDelay(_ seconds: Double) {
        guard let mpv else { return }
        var v = seconds
        mpv_set_property(mpv, "sub-delay", MPV_FORMAT_DOUBLE, &v)
    }

    /// Positive = audio appears earlier relative to video. Seconds.
    func setAudioDelay(_ seconds: Double) {
        guard let mpv else { return }
        var v = seconds
        mpv_set_property(mpv, "audio-delay", MPV_FORMAT_DOUBLE, &v)
    }

    /// Preferred audio language (ISO 639-2/3 code). mpv picks the best
    /// matching track when `aid=auto`.
    func setPreferredAudioLanguage(_ code: String?) {
        guard let mpv else { return }
        _ = mpv_set_property_string(mpv, "alang", code ?? "")
    }

    /// Preferred subtitle language (ISO 639-2/3 code).
    func setPreferredSubtitleLanguage(_ code: String?) {
        guard let mpv else { return }
        _ = mpv_set_property_string(mpv, "slang", code ?? "")
    }

    // MARK: - advanced controls

    func setAspectMode(_ mode: PlayerController.AspectMode) {
        guard let mpv else { return }
        _ = mpv_set_property_string(mpv, "video-aspect-override", mode.mpvValue)
        _ = mpv_set_property_string(mpv, "video-unscaled",        mode.mpvUnscaled)
    }

    func setZoom(_ z: Double) {
        guard let mpv else { return }
        var v = z
        mpv_set_property(mpv, "video-zoom", MPV_FORMAT_DOUBLE, &v)
    }

    func setToneMapping(_ p: PlayerController.ToneMappingPreset) {
        guard let mpv else { return }
        _ = mpv_set_property_string(mpv, "tone-mapping",          p.mpvValue)
        _ = mpv_set_property_string(mpv, "target-prim",           "auto")
        // Peak-detect gives smoother highlight compression across scenes;
        // cheap enough to always enable on tone-mapped content.
        _ = mpv_set_property_string(mpv, "hdr-compute-peak",      "yes")
    }

    func setAudioPassthrough(_ on: Bool) {
        guard let mpv else { return }
        _ = mpv_set_property_string(mpv, "audio-spdif", on ? "ac3,eac3,dts,dts-hd,truehd" : "")
    }

    /// One-call macro. Collapses several options tuned per profile.
    func applyPlaybackProfile(_ p: PlayerController.PlaybackProfile) {
        guard let mpv else { return }
        switch p {
        case .balanced:
            _ = mpv_set_property_string(mpv, "scale",          "spline36")
            _ = mpv_set_property_string(mpv, "dscale",         "mitchell")
            _ = mpv_set_property_string(mpv, "cscale",         "spline36")
            _ = mpv_set_property_string(mpv, "deband",         "yes")
            _ = mpv_set_property_string(mpv, "video-sync",     "display-resample")
            _ = mpv_set_property_string(mpv, "demuxer-max-bytes", "150MiB")
            setAudioPassthrough(false)
        case .quality:
            _ = mpv_set_property_string(mpv, "scale",          "ewa_lanczossharp")
            _ = mpv_set_property_string(mpv, "dscale",         "mitchell")
            _ = mpv_set_property_string(mpv, "cscale",         "spline36")
            _ = mpv_set_property_string(mpv, "deband",         "yes")
            _ = mpv_set_property_string(mpv, "deband-iterations", "4")
            _ = mpv_set_property_string(mpv, "video-sync",     "display-resample")
            _ = mpv_set_property_string(mpv, "tone-mapping",   "bt.2446a")
            _ = mpv_set_property_string(mpv, "hdr-compute-peak", "yes")
        case .performance:
            _ = mpv_set_property_string(mpv, "scale",          "bilinear")
            _ = mpv_set_property_string(mpv, "dscale",         "bilinear")
            _ = mpv_set_property_string(mpv, "cscale",         "bilinear")
            _ = mpv_set_property_string(mpv, "deband",         "no")
            _ = mpv_set_property_string(mpv, "video-sync",     "audio")
        case .audiophile:
            // Keep video sane; tune audio side.
            _ = mpv_set_property_string(mpv, "audio-buffer",   "0.5")
            _ = mpv_set_property_string(mpv, "audio-exclusive","yes")
            setAudioPassthrough(true)
        }
    }

    private func setOption(_ name: String, _ value: String) {
        guard let mpv else { return }
        _ = mpv_set_option_string(mpv, name, value)
    }

    private func runCommand(_ args: [String]) {
        guard let mpv else { return }
        // mpv wants a null-terminated argv. We strdup each arg so the array
        // outlives this call synchronously (mpv_command copies internally).
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { $0.map { free($0) } } }
        cArgs.withUnsafeMutableBufferPointer { buf in
            _ = mpv_command(mpv, buf.baseAddress.map { UnsafeMutablePointer<UnsafePointer<CChar>?>(OpaquePointer($0)) })
        }
    }

    // MARK: - teardown

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true

        // Drop the view from the live registry so any pending C callbacks
        // currently dispatched to main become no-ops as soon as they run.
        Self.liveLock.lock()
        Self.liveViews.removeValue(forKey: selfToken)
        Self.liveLock.unlock()

        // Clear mpv callbacks BEFORE freeing anything. Otherwise a pending
        // wakeup or render-update could fire against a dead handle.
        if let m = mpv {
            mpv_set_wakeup_callback(m, nil, nil)
        }

        // Render context must be freed with the GL context current + locked;
        // otherwise mpv may touch GL state while another draw is mid-flight.
        if let gl = mpvGL {
            if let context = openGLContext, let cgl = context.cglContextObj {
                context.makeCurrentContext()
                CGLLockContext(cgl)
                mpv_render_context_set_update_callback(gl, nil, nil)
                mpv_render_context_free(gl)
                CGLUnlockContext(cgl)
            } else {
                mpv_render_context_set_update_callback(gl, nil, nil)
                mpv_render_context_free(gl)
            }
            mpvGL = nil
        }

        // terminate_destroy can block while mpv drains cache/network. Hand
        // the pointer to a background queue so the UI doesn't hitch when
        // leaving the player on a slow stream.
        if let m = mpv {
            mpv = nil
            DispatchQueue.global(qos: .utility).async {
                mpv_terminate_destroy(m)
            }
        }
        initialized = false
    }

    deinit {
        shutdown()
    }
}
