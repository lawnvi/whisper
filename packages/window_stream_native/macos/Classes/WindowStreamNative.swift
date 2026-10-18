import AppKit
import Foundation

// C entry points declared in src/window_stream_native.h. Everything here is a
// thin shim over SurfaceRegistry so the ABI stays easy to audit.

public typealias WSNInputCallback = @convention(c) (
  Int64, Int32, Int32, Int32, Double, Double, Double, Double, Int32,
  UnsafeMutablePointer<CChar>?
) -> Void
public typealias WSNWindowCallback = @convention(c) (
  Int64, Int32, Double, Double, Double, Double
) -> Void

@_cdecl("wsn_api_version")
public func wsn_api_version() -> Int32 {
  return 1
}

@_cdecl("wsn_reset_all")
public func wsn_reset_all() {
  SurfaceRegistry.shared.resetAll()
  CaptureRegistry.shared.resetAll()
}

@_cdecl("wsn_set_input_callback")
public func wsn_set_input_callback(_ callback: WSNInputCallback?) {
  SurfaceRegistry.shared.setInputCallback(callback)
}

@_cdecl("wsn_set_window_callback")
public func wsn_set_window_callback(_ callback: WSNWindowCallback?) {
  SurfaceRegistry.shared.setWindowCallback(callback)
}

@_cdecl("wsn_free")
public func wsn_free(_ pointer: UnsafeMutableRawPointer?) {
  free(pointer)
}

@_cdecl("wsn_surface_create")
public func wsn_surface_create(
  _ title: UnsafePointer<CChar>?, _ videoWidth: Int32, _ videoHeight: Int32,
  _ flags: Int32
) -> Int64 {
  let text = title.map { String(cString: $0) } ?? ""
  return SurfaceRegistry.shared.create(
    title: text,
    videoSize: CGSize(width: Int(videoWidth), height: Int(videoHeight)),
    flags: flags)
}

@_cdecl("wsn_surface_set_title")
public func wsn_surface_set_title(_ surface: Int64, _ title: UnsafePointer<CChar>?) {
  let text = title.map { String(cString: $0) } ?? ""
  SurfaceRegistry.shared.surface(surface)?.setTitle(text)
}

@_cdecl("wsn_surface_set_visual")
public func wsn_surface_set_visual(
  _ surface: Int64, _ visual: Int32, _ message: UnsafePointer<CChar>?
) {
  let text = message.map { String(cString: $0) }
  SurfaceRegistry.shared.surface(surface)?.setVisual(visual, message: text)
}

@_cdecl("wsn_surface_set_hud")
public func wsn_surface_set_hud(_ surface: Int64, _ text: UnsafePointer<CChar>?) {
  let value = text.map { String(cString: $0) } ?? ""
  SurfaceRegistry.shared.surface(surface)?.setHudText(value)
}

@_cdecl("wsn_surface_set_icon")
public func wsn_surface_set_icon(_ surface: Int64, _ png: UnsafePointer<UInt8>?, _ length: Int32) {
  guard let png, length > 0 else { return }
  let data = Data(bytes: png, count: Int(length))
  SurfaceRegistry.shared.surface(surface)?.setIcon(data)
}

@_cdecl("wsn_surface_focus")
public func wsn_surface_focus(_ surface: Int64) {
  SurfaceRegistry.shared.surface(surface)?.focus()
}

@_cdecl("wsn_surface_destroy")
public func wsn_surface_destroy(_ surface: Int64) {
  SurfaceRegistry.shared.destroy(surface)
}

@_cdecl("wsn_surface_stats")
public func wsn_surface_stats(
  _ surface: Int64, _ out: UnsafeMutablePointer<Double>?, _ count: Int32
) -> Int32 {
  guard let out = out, count > 0, let target = SurfaceRegistry.shared.surface(surface)
  else { return 0 }
  let values = target.statsSnapshot()
  let written = min(Int(count), values.count)
  for index in 0..<written {
    out[index] = values[index]
  }
  return Int32(written)
}

@_cdecl("wsn_surface_snapshot")
public func wsn_surface_snapshot(
  _ surface: Int64, _ path: UnsafePointer<CChar>?, _ maxEdge: Int32
) -> Int32 {
  guard let path = path, let target = SurfaceRegistry.shared.surface(surface) else { return -1 }
  return target.writeSnapshot(to: String(cString: path), maxEdge: Int(maxEdge)) ? 0 : -2
}

/// The window's sound level, 0 (muted) to 1; its own control follows
/// without reporting WSN_WINDOW_VOLUME back.
@_cdecl("wsn_surface_set_volume")
public func wsn_surface_set_volume(_ surface: Int64, _ volume: Double) {
  SurfaceRegistry.shared.surface(surface)?.setVolume(volume)
}

/// Localized words for the windows' controls, as JSON.
@_cdecl("wsn_set_strings")
public func wsn_set_strings(_ json: UnsafePointer<CChar>?) {
  guard let json = json else { return }
  WindowStreamStrings.shared.update(json: String(cString: json))
  SurfaceRegistry.shared.refreshStrings()
}

@_cdecl("wsn_buffer_alloc")
public func wsn_buffer_alloc(_ length: Int32) -> UnsafeMutablePointer<UInt8>? {
  guard length > 0 else { return nil }
  return malloc(Int(length))?.assumingMemoryBound(to: UInt8.self)
}

@_cdecl("wsn_video_push")
public func wsn_video_push(
  _ surface: Int64, _ buffer: UnsafeMutablePointer<UInt8>?, _ length: Int32,
  _ ptsUs: Int64, _ flags: Int32
) {
  guard let buffer = buffer else { return }
  guard length > 0, let target = SurfaceRegistry.shared.surface(surface) else {
    free(buffer)
    return
  }
  target.pushVideo(OwnedBuffer(pointer: buffer, length: Int(length)), ptsUs: ptsUs, flags: flags)
}

@_cdecl("wsn_audio_configure")
public func wsn_audio_configure(
  _ surface: Int64, _ codec: Int32, _ sampleRate: Int32, _ channels: Int32
) {
  SurfaceRegistry.shared.surface(surface)?.configureAudio(
    codec: codec, sampleRate: Int(sampleRate), channels: Int(channels))
}

@_cdecl("wsn_audio_push")
public func wsn_audio_push(
  _ surface: Int64, _ buffer: UnsafeMutablePointer<UInt8>?, _ length: Int32, _ ptsUs: Int64
) {
  guard let buffer = buffer else { return }
  guard length > 0, let target = SurfaceRegistry.shared.surface(surface) else {
    free(buffer)
    return
  }
  target.pushAudio(OwnedBuffer(pointer: buffer, length: Int(length)), ptsUs: ptsUs)
}

// MARK: Capture (this Mac as a window source)

/// One streamed local window: its capture pipeline and its input replayer.
final class CaptureSession {
  let capture: AnyObject
  let injector: WindowInjector
  let textFocus: TextFocusWatcher?

  init(capture: AnyObject, injector: WindowInjector, textFocus: TextFocusWatcher? = nil) {
    self.capture = capture
    self.injector = injector
    self.textFocus = textFocus
  }

  @available(macOS 12.3, *)
  var windowCapture: WindowCapture? { capture as? WindowCapture }
}

@_cdecl("wsn_set_capture_callback")
public func wsn_set_capture_callback(_ callback: WSNCaptureCallback?) {
  CaptureRegistry.shared.setCallback(callback)
  // The host is up: put back windows an earlier run left on no Space.
  if #available(macOS 12.3, *), callback != nil {
    DispatchQueue.main.async { StrandedWindows.rescueSoon() }
  }
}

@_cdecl("wsn_capture_supported")
public func wsn_capture_supported() -> Int32 {
  if #available(macOS 12.3, *) {
    return 1
  }
  return 0
}

@_cdecl("wsn_capture_input_permission")
public func wsn_capture_input_permission() -> Int32 {
  return WindowInjector.hasPermission ? 1 : 0
}

@_cdecl("wsn_capture_request_catalog")
public func wsn_capture_request_catalog() -> Int64 {
  let id = CaptureRegistry.shared.newId()
  CaptureCatalog.requestCatalog(requestId: id)
  return id
}

@_cdecl("wsn_capture_request_icon")
public func wsn_capture_request_icon(_ bundleId: UnsafePointer<CChar>?, _ size: Int32) -> Int64 {
  let id = CaptureRegistry.shared.newId()
  CaptureCatalog.requestIcon(
    requestId: id, bundleId: bundleId.map { String(cString: $0) } ?? "", size: Int(size))
  return id
}

@_cdecl("wsn_capture_launch_app")
public func wsn_capture_launch_app(_ bundleId: UnsafePointer<CChar>?) -> Int64 {
  let id = CaptureRegistry.shared.newId()
  CaptureCatalog.launchApp(requestId: id, bundleId: bundleId.map { String(cString: $0) } ?? "")
  return id
}

@_cdecl("wsn_capture_request_thumbnail")
public func wsn_capture_request_thumbnail(_ windowId: UInt32, _ maxEdge: Int32) -> Int64 {
  let id = CaptureRegistry.shared.newId()
  CaptureCatalog.requestThumbnail(requestId: id, windowId: windowId, maxEdge: Int(maxEdge))
  return id
}

@_cdecl("wsn_capture_start")
public func wsn_capture_start(
  _ windowId: UInt32, _ pid: Int32, _ maxEdge: Int32, _ fps: Int32, _ bitRate: Int32
) -> Int64 {
  let id = CaptureRegistry.shared.newId()
  guard #available(macOS 12.3, *) else {
    CaptureRegistry.shared.emit(id: id, kind: WSNCapture.kindFailed, flags: WSNCapture.errorUnsupported)
    return id
  }
  let capture = WindowCapture(
    id: id, windowId: windowId, maxEdge: Int(maxEdge), fps: Int(fps), bitRate: Int(bitRate))
  let injector = WindowInjector(windowId: windowId, pid: pid)
  capture.onCaptureDisplay = { [weak injector] display in injector?.setCaptureDisplay(display) }
  injector.onTouch = { [weak capture] in capture?.viewerTouched() }
  injector.onTyped = { [weak capture] wait in capture?.viewerTyped(waited: wait) }
  // Lets a phone bring up its keyboard when a text field takes focus.
  let textFocus = TextFocusWatcher(pid: pid) { typing in
    CaptureRegistry.shared.emit(
      id: id, kind: WSNCapture.kindTextFocus, flags: typing ? 1 : 0)
  }
  let session = CaptureSession(capture: capture, injector: injector, textFocus: textFocus)
  CaptureRegistry.shared.register(id, session)
  capture.start()
  return id
}

@_cdecl("wsn_capture_stop")
public func wsn_capture_stop(_ capture: Int64) {
  guard let session = CaptureRegistry.shared.remove(capture) as? CaptureSession else { return }
  session.textFocus?.stop()
  if #available(macOS 12.3, *) {
    session.windowCapture?.stop()
  }
}

@_cdecl("wsn_capture_set_screen")
public func wsn_capture_set_screen(_ capture: Int64, _ key: Int64) {
  guard let session = CaptureRegistry.shared.capture(capture) as? CaptureSession else { return }
  if #available(macOS 12.3, *) {
    session.windowCapture?.setScreen(key)
  }
}

@_cdecl("wsn_capture_set_inset")
public func wsn_capture_set_inset(_ capture: Int64, _ bottom: Double) {
  guard let session = CaptureRegistry.shared.capture(capture) as? CaptureSession else { return }
  if #available(macOS 12.3, *) {
    session.windowCapture?.setBottomInset(bottom)
  }
}

@_cdecl("wsn_capture_set_viewport")
public func wsn_capture_set_viewport(
  _ capture: Int64, _ width: Double, _ height: Double, _ scale: Double
) {
  guard let session = CaptureRegistry.shared.capture(capture) as? CaptureSession else { return }
  if #available(macOS 12.3, *) {
    session.windowCapture?.setViewport(width: width, height: height, scale: scale)
  }
}

@_cdecl("wsn_capture_close_window")
public func wsn_capture_close_window(_ windowId: UInt32, _ pid: Int32) {
  guard #available(macOS 12.3, *) else { return }
  DispatchQueue.main.async {
    WindowCloser.close(windowId: windowId, pid: pid)
  }
}

@_cdecl("wsn_capture_set_busy")
public func wsn_capture_set_busy(_ capture: Int64, _ busy: Int32) {
  guard let session = CaptureRegistry.shared.capture(capture) as? CaptureSession else { return }
  if #available(macOS 12.3, *) {
    session.windowCapture?.setBusy(busy != 0)
  }
}

@_cdecl("wsn_capture_request_keyframe")
public func wsn_capture_request_keyframe(_ capture: Int64) {
  guard let session = CaptureRegistry.shared.capture(capture) as? CaptureSession else { return }
  if #available(macOS 12.3, *) {
    session.windowCapture?.requestKeyframe()
  }
}

@_cdecl("wsn_capture_set_paused")
public func wsn_capture_set_paused(_ capture: Int64, _ paused: Int32) {
  guard let session = CaptureRegistry.shared.capture(capture) as? CaptureSession else { return }
  if #available(macOS 12.3, *) {
    session.windowCapture?.setPaused(paused != 0)
  }
}

@_cdecl("wsn_capture_set_bit_rate")
public func wsn_capture_set_bit_rate(_ capture: Int64, _ bitRate: Int32) {
  guard let session = CaptureRegistry.shared.capture(capture) as? CaptureSession else { return }
  if #available(macOS 12.3, *) {
    session.windowCapture?.setBitRate(Int(bitRate))
  }
}

/// WSN_CAPTURE_AUDIO_*: the window's app sound (see WindowAudio).
@_cdecl("wsn_capture_set_audio")
public func wsn_capture_set_audio(_ capture: Int64, _ mode: Int32) {
  guard let session = CaptureRegistry.shared.capture(capture) as? CaptureSession else { return }
  if #available(macOS 12.3, *) {
    session.windowCapture?.setAudio(mode)
  }
}

/// The viewer's pixels per point: no more pixels than it can show.
@_cdecl("wsn_capture_set_pixel_ratio")
public func wsn_capture_set_pixel_ratio(_ capture: Int64, _ ratio: Double) {
  guard let session = CaptureRegistry.shared.capture(capture) as? CaptureSession else { return }
  if #available(macOS 12.3, *) {
    session.windowCapture?.setPixelRatio(ratio)
  }
}

@_cdecl("wsn_capture_input")
public func wsn_capture_input(
  _ capture: Int64, _ kind: Int32, _ code: Int32, _ modifiers: Int32, _ x: Double, _ y: Double,
  _ dx: Double, _ dy: Double, _ phase: Int32, _ text: UnsafePointer<CChar>?
) {
  guard let session = CaptureRegistry.shared.capture(capture) as? CaptureSession else { return }
  session.injector.handle(
    kind: kind, code: code, modifiers: modifiers, x: x, y: y, dx: dx, dy: dy, phase: phase,
    text: text.map { String(cString: $0) })
}

/// A malloc'd buffer handed over by Dart. Freed exactly once.
final class OwnedBuffer {
  let pointer: UnsafeMutablePointer<UInt8>
  let length: Int
  private var released = false

  init(pointer: UnsafeMutablePointer<UInt8>, length: Int) {
    self.pointer = pointer
    self.length = length
  }

  /// Gives the memory away (e.g. to a CMBlockBuffer that frees it).
  func detach() -> UnsafeMutablePointer<UInt8> {
    released = true
    return pointer
  }

  deinit {
    if !released {
      free(pointer)
    }
  }
}

final class SurfaceRegistry {
  static let shared = SurfaceRegistry()

  private let lock = NSLock()
  private let callbackQueue = DispatchQueue(
    label: "whisper.window_stream.callbacks", qos: .userInteractive)
  private var surfaces: [Int64: StreamSurface] = [:]
  private var nextId: Int64 = 1
  private var inputCallback: WSNInputCallback?
  private var windowCallback: WSNWindowCallback?

  func setInputCallback(_ callback: WSNInputCallback?) {
    lock.lock()
    inputCallback = callback
    lock.unlock()
  }

  func setWindowCallback(_ callback: WSNWindowCallback?) {
    lock.lock()
    windowCallback = callback
    lock.unlock()
  }

  func create(title: String, videoSize: CGSize, flags: Int32) -> Int64 {
    lock.lock()
    let id = nextId
    nextId += 1
    let surface = StreamSurface(id: id, title: title, videoSize: videoSize, flags: flags)
    surfaces[id] = surface
    lock.unlock()
    surface.start()
    return id
  }

  func surface(_ id: Int64) -> StreamSurface? {
    lock.lock()
    defer { lock.unlock() }
    return surfaces[id]
  }

  func destroy(_ id: Int64) {
    lock.lock()
    let surface = surfaces.removeValue(forKey: id)
    lock.unlock()
    surface?.stop()
  }

  /// Every window shows the new words of wsn_set_strings.
  func refreshStrings() {
    lock.lock()
    let all = Array(surfaces.values)
    lock.unlock()
    for surface in all {
      surface.refreshStrings()
    }
  }

  /// Called when Dart (re)initialises, e.g. after a hot restart, so no window
  /// keeps calling into callbacks that belong to a dead isolate.
  func resetAll() {
    lock.lock()
    let all = Array(surfaces.values)
    surfaces.removeAll()
    inputCallback = nil
    windowCallback = nil
    lock.unlock()
    for surface in all {
      surface.stop()
    }
  }

  func emitInput(
    surface: Int64, kind: Int32, code: Int32 = 0, modifiers: Int32 = 0,
    x: Double = 0, y: Double = 0, dx: Double = 0, dy: Double = 0, phase: Int32 = 0,
    text: String? = nil
  ) {
    // Callbacks never run inside a call from Dart: a NativeCallable must not
    // be invoked while the calling thread is in an FFI (leaf) call.
    callbackQueue.async { [weak self] in
      guard let self = self else { return }
      self.lock.lock()
      let callback = self.inputCallback
      self.lock.unlock()
      guard let callback = callback else { return }
      let textPointer = text.flatMap { strdup($0) }
      callback(surface, kind, code, modifiers, x, y, dx, dy, phase, textPointer)
    }
  }

  func emitWindow(
    surface: Int64, kind: Int32, a: Double = 0, b: Double = 0, c: Double = 0, d: Double = 0
  ) {
    callbackQueue.async { [weak self] in
      guard let self = self else { return }
      self.lock.lock()
      let callback = self.windowCallback
      self.lock.unlock()
      callback?(surface, kind, a, b, c, d)
    }
  }
}

enum WSNConst {
  static let flagShowHud: Int32 = 0x1
  static let flagReflow: Int32 = 0x2

  static let packetConfig: Int32 = 0x1
  static let packetKey: Int32 = 0x2

  static let visualLive: Int32 = 0
  static let visualConnecting: Int32 = 1
  static let visualPaused: Int32 = 2
  static let visualReconnecting: Int32 = 3
  static let visualDisplaced: Int32 = 4
  static let visualSecure: Int32 = 5
  static let visualExited: Int32 = 6
  static let visualError: Int32 = 7

  static let audioPcmS16le: Int32 = 1

  static let inputPointerDown: Int32 = 1
  static let inputPointerMove: Int32 = 2
  static let inputPointerUp: Int32 = 3
  static let inputScroll: Int32 = 4
  static let inputKeyDown: Int32 = 5
  static let inputKeyUp: Int32 = 6
  static let inputText: Int32 = 7
  static let inputPointerCancel: Int32 = 8

  static let modShift: Int32 = 0x1
  static let modControl: Int32 = 0x2
  static let modOption: Int32 = 0x4
  static let modCommand: Int32 = 0x8
  static let modCapsLock: Int32 = 0x10
  static let modFunction: Int32 = 0x20

  static let windowCloseRequested: Int32 = 1
  static let windowFocus: Int32 = 2
  static let windowVisibility: Int32 = 3
  static let windowResized: Int32 = 4
  static let windowFirstFrame: Int32 = 5
  static let windowNeedKeyframe: Int32 = 6
  static let windowDecodeError: Int32 = 7
  static let windowAction: Int32 = 8
  static let windowVolume: Int32 = 9
}

/// Runs `block` on the main thread, synchronously when already there.
func onMain(_ block: @escaping () -> Void) {
  if Thread.isMainThread {
    block()
  } else {
    DispatchQueue.main.async(execute: block)
  }
}
