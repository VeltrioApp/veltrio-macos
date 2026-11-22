import Foundation
import Libmpv

/// libmpv without the drawing: the handle, its options, the property
/// observers and the event drain that feed `PlayerController`, and the
/// commands the UI sends. The platform view around it draws: on a Mac an
/// OpenGL view through mpv's render API, on iOS a Metal layer mpv renders
/// into itself. `shutdown()` is idempotent.
final class MPVEngine {
    private(set) var mpv: OpaquePointer?
    private var queuedURL: String?
    private var initialized = false
    private(set) var isShutdown = false
    weak var controller: PlayerController?

    /// Live-pointer registry so the C callbacks can decide whether the
    /// engine is still around without holding a strong reference to it.
    private static var live: [UnsafeMutableRawPointer: Weak] = [:]
    private static let liveLock = NSLock()
    private final class Weak { weak var engine: MPVEngine?; init(_ e: MPVEngine) { engine = e } }
    private(set) var token: UnsafeMutableRawPointer!

    init() {
        token = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        Self.liveLock.lock()
        Self.live[token] = Weak(self)
        Self.liveLock.unlock()
    }

    /// The engine for a token handed to a C callback; nil once torn down.
    static func resolve(_ token: UnsafeMutableRawPointer?) -> MPVEngine? {
        guard let token else { return nil }
        liveLock.lock(); defer { liveLock.unlock() }
        return live[token]?.engine
    }

    /// Turns the video track off and on (iOS, around the background).
    func setVideoEnabled(_ on: Bool) {
        guard let mpv else { return }
        _ = mpv_set_property_string(mpv, "vid", on ? "auto" : "no")
    }

    /// No picture and no sound (tests).
    static let headless: (OpaquePointer) -> Void = { mpv in
        _ = mpv_set_option_string(mpv, "vo", "null")
        _ = mpv_set_option_string(mpv, "ao", "null")
    }

    /// Creates and initializes mpv. `videoOutput` sets the platform's
    /// video options (vo, wid…) before initialization.
    func start(videoOutput: (OpaquePointer) -> Void) {
        mpv = mpv_create()
        guard let mpv else { return }

        setOption("force-window", "no")
        setOption("terminal", "no")
        setOption("input-default-bindings", "no")
        setOption("input-vo-keyboard", "no")
        videoOutput(mpv)

        // Lock mpv down to the network protocols we actually route through
        // it. Without this a hostile addon stream could hand us a
        // file://, smb://, cdda:// or EDL playlist that reads local files
        // or probes the local network on our behalf.
        setOption("demuxer-lavf-o", "protocol_whitelist=file,crypto,data,http,https,tcp,tls,hls,rtmp,rtmps,udp,rtp")
        setOption("load-unsafe-playlists", "no")

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

        // Wakeup callback → main-thread event drain, through the token so
        // a late callback after teardown resolves to nil safely.
        mpv_set_wakeup_callback(mpv, { data in
            DispatchQueue.main.async { [data] in
                MPVEngine.resolve(data)?.drainEvents()
            }
        }, token)

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

    /// Subtitle size multiplier and color.
    func setSubtitleAppearance(scale: Double, color: String) {
        guard let mpv else { return }
        var s = scale
        _ = mpv_set_property(mpv, "sub-scale", MPV_FORMAT_DOUBLE, &s)
        _ = mpv_set_property_string(mpv, "sub-color", color)
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

    /// Stops callbacks; `beforeDestroy` frees what the platform view built
    /// on the handle (the render context), then the handle goes.
    func shutdown(beforeDestroy: (OpaquePointer?) -> Void = { _ in }) {
        guard !isShutdown else { return }
        isShutdown = true
        Self.liveLock.lock()
        Self.live.removeValue(forKey: token)
        Self.liveLock.unlock()
        if let m = mpv { mpv_set_wakeup_callback(m, nil, nil) }
        beforeDestroy(mpv)
        // terminate_destroy can block while mpv drains cache/network: off
        // the main queue, so leaving the player on a slow stream doesn't hitch.
        if let m = mpv {
            mpv = nil
            DispatchQueue.global(qos: .utility).async { mpv_terminate_destroy(m) }
        }
        initialized = false
    }

    deinit { shutdown() }
}
