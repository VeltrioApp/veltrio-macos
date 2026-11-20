import SwiftUI
import AppKit
import OpenGL.GL
import OpenGL.GL3
import Darwin
import Libmpv

/// SwiftUI view backed by libmpv. HDR, 10-bit, DTS/TrueHD passthrough,
/// hardware decode: all handled by mpv. We just hand it a URL and render
/// into an `NSOpenGLView` via mpv's render API.
struct MPVPlayer: NSViewRepresentable {
    let url: URL
    let controller: PlayerController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MPVOpenGLView {
        let view = MPVOpenGLView(frame: .zero)
        view.engine.controller = controller
        controller.view = view.engine
        view.engine.load(url: url.absoluteString)
        context.coordinator.view = view
        context.coordinator.lastURL = url.absoluteString
        return view
    }

    func updateNSView(_ nsView: MPVOpenGLView, context: Context) {
        if context.coordinator.lastURL != url.absoluteString {
            nsView.engine.load(url: url.absoluteString)
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

/// The Mac's video surface: an OpenGL view mpv draws into through its
/// render API. The engine (Shared/MPVEngine.swift) does the rest.
final class MPVOpenGLView: NSOpenGLView {
    let engine = MPVEngine()
    private var mpvGL: OpaquePointer?

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

        // CRITICAL: route video output through the libmpv render API so mpv
        // draws into our NSOpenGLView's FBO instead of spawning its own
        // standalone window (the default `vo=gpu` would do exactly that).
        engine.start { mpv in _ = mpv_set_option_string(mpv, "vo", "libmpv") }
        setupRenderContext()
    }

    // MARK: - render context

    private func setupRenderContext() {
        guard let mpv = engine.mpv else { return }
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
        guard let mpvGL = mpvGL, !engine.isShutdown else { return }

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

    // MARK: - teardown

    func shutdown() {
        Self.liveLock.lock()
        Self.liveViews.removeValue(forKey: selfToken)
        Self.liveLock.unlock()
        engine.shutdown { [self] _ in
            // Render context must be freed with the GL context current +
            // locked; otherwise mpv may touch GL state mid-draw.
            guard let gl = mpvGL else { return }
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
    }

    deinit { shutdown() }
}
