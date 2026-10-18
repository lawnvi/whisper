import AppKit
import ApplicationServices
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

/// Capture-side constants shared with Dart (see window_stream_native.h).
enum WSNCapture {
  static let kindPacket: Int32 = 1
  static let kindFailed: Int32 = 2
  static let kindSize: Int32 = 3
  static let kindCatalog: Int32 = 4
  static let kindThumbnail: Int32 = 5
  static let kindIcon: Int32 = 6
  static let kindStopped: Int32 = 7
  static let kindLaunched: Int32 = 8
  /// data = UTF-8 text for the host's log (staging, fallbacks, errors).
  static let kindNote: Int32 = 9
  /// flags = 1 when the app's keyboard focus is somewhere to type, else 0.
  static let kindTextFocus: Int32 = 10
  /// data = PCM s16le interleaved, width = sample rate, height = channels,
  /// pts on the video's clock (see WindowAudio).
  static let kindAudio: Int32 = 11

  static let errorUnknown: Int32 = 1
  static let errorUnsupported: Int32 = 2
  static let errorPermission: Int32 = 3
  static let errorNotFound: Int32 = 4
  static let errorEncoder: Int32 = 5
}

public typealias WSNCaptureCallback = @convention(c) (
  Int64, Int32, UnsafeMutablePointer<UInt8>?, Int32, Int64, Int32, Int32, Int32
) -> Void

/// Holds running captures and delivers their output to Dart.
final class CaptureRegistry {
  static let shared = CaptureRegistry()

  private let lock = NSLock()
  private let callbackQueue = DispatchQueue(
    label: "whisper.window_stream.capture_callbacks", qos: .userInteractive)
  private var callback: WSNCaptureCallback?
  private var captures: [Int64: AnyObject] = [:]
  private var nextId: Int64 = 1

  func setCallback(_ value: WSNCaptureCallback?) {
    lock.lock()
    callback = value
    lock.unlock()
  }

  func newId() -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    let id = nextId
    nextId += 1
    return id
  }

  func register(_ id: Int64, _ capture: AnyObject) {
    lock.lock()
    captures[id] = capture
    lock.unlock()
  }

  func capture(_ id: Int64) -> AnyObject? {
    lock.lock()
    defer { lock.unlock() }
    return captures[id]
  }

  func remove(_ id: Int64) -> AnyObject? {
    lock.lock()
    defer { lock.unlock() }
    return captures.removeValue(forKey: id)
  }

  func resetAll() {
    lock.lock()
    let all = Array(captures.values)
    captures.removeAll()
    callback = nil
    lock.unlock()
    if #available(macOS 12.3, *) {
      for capture in all {
        (capture as? CaptureSession)?.windowCapture?.stop()
      }
    }
  }

  /// A line for the host's log about capture [id].
  func note(id: Int64, _ text: String) {
    let bytes = Array(text.utf8)
    guard let buffer = malloc(max(bytes.count, 1))?.assumingMemoryBound(to: UInt8.self) else { return }
    bytes.withUnsafeBufferPointer { buffer.update(from: $0.baseAddress!, count: bytes.count) }
    emit(id: id, kind: WSNCapture.kindNote, data: buffer, length: Int32(bytes.count))
  }

  /// Delivers asynchronously; `data` (malloc'd) is owned by the receiver.
  func emit(
    id: Int64, kind: Int32, data: UnsafeMutablePointer<UInt8>? = nil, length: Int32 = 0,
    ptsUs: Int64 = 0, flags: Int32 = 0, width: Int32 = 0, height: Int32 = 0
  ) {
    callbackQueue.async { [weak self] in
      guard let self = self else {
        free(data)
        return
      }
      self.lock.lock()
      let callback = self.callback
      self.lock.unlock()
      guard let callback = callback else {
        free(data)
        return
      }
      callback(id, kind, data, length, ptsUs, flags, width, height)
    }
  }
}

/// Streams one window: ScreenCaptureKit frames → VideoToolbox H.264 (Annex-B,
/// parameter sets in a separate config packet before each keyframe).
///
/// With the viewer's screen size known, the window is first staged on a
/// virtual display of its own (see VirtualStage): it leaves the Mac's screen,
/// takes the size the viewer wants and is captured from that display. When
/// that is not possible it is captured where it is, as a plain window.
@available(macOS 12.3, *)
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
  let id: Int64
  let windowId: CGWindowID
  private let maxEdge: Int
  private let fps: Int
  private var bitRate: Int
  private let queue: DispatchQueue
  private var stream: SCStream?
  /// The running stream's settings, to change the pointer on the fly.
  private var configuration: SCStreamConfiguration?
  /// Whether the pointer is in the picture: yes for the Mac's own mouse
  /// moved over to the display, no while the viewer's finger drives (the
  /// pointer jumping to every tap is only noise there).
  private var cursorShown = true
  private var cursorHiddenUntil = 0.0
  private var encoder: VTCompressionSession?
  private var encodedSize = CGSize.zero
  private var forceKeyframe = true
  private var inFlight = 0
  /// The newest frame waiting for the encoder; a newer one replaces it.
  private var pending: (CVPixelBuffer, CMTime)?
  /// The last frame captured: a still window sends no new ones, so a
  /// viewer that asks for a picture gets this one again.
  private var lastFrame: (CVPixelBuffer, CMTime)?
  /// The network is behind: frames are not encoded (so none queue up and
  /// none has to be dropped later, which would need a keyframe); the
  /// newest one goes out once it catches up.
  private var busy = false
  private var skippedWhileBusy = false
  private var stopped = false
  private var paused = false
  private var lastParameterSets = Data()

  /// The viewer's screen in its points, and its text scale (Aa). Queue.
  private var viewport = CGSize.zero
  private var textScale: CGFloat = 1
  /// The viewer's pixels per point, at most 2 (0: not told; the Mac's own
  /// density). A 1x screen gets the window at 1x, not a 2x picture to
  /// shrink. Queue.
  private var viewerPixelRatio: CGFloat = 0
  /// The running stream's start, to restart it at another size. Queue.
  private var lastStart: (target: CaptureTarget, content: CGSize, sourceRect: CGRect?)?
  /// What the staged stream shows (see CaptureTarget), to restart it.
  private var stagedTarget: CaptureTarget?
  /// Frames are dropped: the filter is being narrowed (a window of the app
  /// that must not be seen appeared) or the window left its display.
  private var holdingFrames = false
  /// The window's app; set once the window is known, before any stream.
  private var windowPid: pid_t = 0
  /// When start() was called and whether a picture went out since, for the log.
  private var startedAt = 0.0
  private var firstPictureNoted = false

  // Main thread only.
  private var stage: VirtualStage?
  /// Tells the input side which display the picture is (nil: the window).
  var onCaptureDisplay: ((CGDirectDisplayID?) -> Void)?
  private var window: SCWindow?
  private var watch: Timer?
  private var missingPolls = 0
  private var restaging = false
  /// The window went home while paused.
  private var parked = false
  private var parkTimer: Timer?
  /// The window's app sound (off until Dart turns it on).
  private let audio: WindowAudio
  /// The staged display (for narrowing the filter later).
  private var stagedDisplay: SCDisplay?
  /// The app's other top-level windows: never in the picture. Main.
  private var exceptedWindows = Set<CGWindowID>()
  /// Those of them the running filter already leaves out. Main.
  private var filteredExcepted = Set<CGWindowID>()
  /// The app's windows that belong to this one (sheets, dialogs, popovers). Main.
  private var allowedWindows = Set<CGWindowID>()
  private var windowWatch: Timer?
  private var narrowing = false

  /// This capture's window is the one on its viewer's display.
  @MainActor
  private var onStage: Bool { stage?.owner === self && stage?.isStaged == true }

  @MainActor
  private func park() {
    guard let stage = stage, onStage, queue.sync(execute: { paused }) else { return }
    CaptureRegistry.shared.note(id: id, "paused a minute: window back home")
    stage.releaseWindow()
    stage.owner = nil
    stepAside()
  }

  /// Off the display (paused long enough, or another window of the same
  /// viewer took it): stop capturing until the viewer comes back to it.
  @MainActor
  private func stepAside() {
    onCaptureDisplay?(nil)
    watch?.invalidate()
    watch = nil
    parked = true
    // Back on the Mac (or another window on the viewer): its sound plays here.
    audio.setSuspended(true)
    windowWatch?.invalidate()
    windowWatch = nil
    queue.async {
      self.stagedTarget = nil
      if let old = self.stream {
        self.stream = nil
        old.stopCapture(completionHandler: nil)
      }
    }
  }

  /// The viewer this capture shows on (a phone): its windows share one
  /// display. Defaults to this capture alone.
  private var screenKey: Int64?

  func setScreen(_ key: Int64) {
    DispatchQueue.main.async { self.screenKey = key }
  }

  init(id: Int64, windowId: CGWindowID, maxEdge: Int, fps: Int, bitRate: Int) {
    self.id = id
    self.windowId = windowId
    self.maxEdge = maxEdge
    self.fps = max(1, min(fps, 120))
    self.bitRate = bitRate
    queue = DispatchQueue(label: "whisper.window_stream.capture.\(id)", qos: .userInteractive)
    audio = WindowAudio(id: id)
  }

  /// WSNCaptureAudioMode: the window's app sound, delivered as kindAudio.
  func setAudio(_ mode: Int32) {
    audio.setMode(mode)
  }

  /// The viewer's pixels per point (wsn_capture_set_pixel_ratio).
  func setPixelRatio(_ ratio: Double) {
    queue.async { [weak self] in
      guard let self = self else { return }
      let value = ratio > 0 ? CGFloat(min(max(ratio, 1), 2)) : 0
      guard value != self.viewerPixelRatio else { return }
      self.viewerPixelRatio = value
      if self.stream != nil, let last = self.lastStart {
        self.restartStream(target: last.target, content: last.content, sourceRect: last.sourceRect)
      }
    }
  }

  private var isStopped: Bool { queue.sync { stopped } }

  func start() {
    queue.async { self.startedAt = CACurrentMediaTime() }
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) {
      [weak self] content, error in
      guard let self = self else { return }
      guard let window = content?.windows.first(where: { $0.windowID == self.windowId }) else {
        CaptureRegistry.shared.emit(
          id: self.id, kind: WSNCapture.kindFailed,
          flags: error == nil ? WSNCapture.errorNotFound : WSNCapture.errorPermission)
        return
      }
      DispatchQueue.main.async {
        Task { @MainActor in await self.begin(window) }
      }
    }
  }

  @MainActor
  private func begin(_ window: SCWindow) async {
    // Only ever the window asked for (start() looked it up by its id).
    guard window.windowID == windowId else {
      refuse("window \(window.windowID) is not the one asked for")
      return
    }
    self.window = window
    if let pid = window.owningApplication?.processID {
      queue.sync { windowPid = pid }
      audio.setApp(pid: pid)
    }
    audio.setSuspended(false)
    let (screen, scale) = queue.sync { (viewport, textScale) }
    if screen.width > 0, screen.height > 0, await stage(window, screen: screen, scale: scale) {
      return
    }
    guard !isStopped else { return }
    // Plain window capture. macOS only renders windows that are on screen:
    // a minimized window or one on another desktop gives no frames at all,
    // so bring it back first (needs Accessibility, like input does).
    if !window.isOnScreen, let pid = window.owningApplication?.processID {
      let revealed = WindowInjector.reveal(pid: pid, frame: window.frame)
      queue.asyncAfter(deadline: .now() + (revealed ? 0.6 : 0)) {
        self.startStream(target: .window(window), content: window.frame.size, sourceRect: nil)
      }
      return
    }
    queue.async {
      self.startStream(target: .window(window), content: window.frame.size, sourceRect: nil)
    }
  }

  /// Puts the window on its virtual display and starts capturing it there.
  /// False when staging is not possible (the caller captures the window).
  @MainActor
  private func stage(_ window: SCWindow, screen: CGSize, scale: CGFloat) async -> Bool {
    let stage = self.stage ?? VirtualStage.forScreen(screenKey ?? id)
    self.stage = stage
    // Another window of this viewer may be on the display: it steps aside.
    stage.take(for: self) { [weak self] in
      guard let self = self else { return }
      CaptureRegistry.shared.note(id: self.id, "another window took the display")
      self.stepAside()
    }
    stage.onLost = { [weak self] in self?.fallBack() }
    do {
      let prepared = try await stage.prepare(
        window: window, screen: VirtualStage.displaySize(viewport: screen, scale: scale))
      onCaptureDisplay?(stage.displayID)
      if isStopped {
        stage.leave(self)
        self.stage = nil
        return true
      }
      let narrowingStarted = CACurrentMediaTime()
      stagedDisplay = prepared.display
      guard let target = await stagedTarget(window, content: prepared.content), !isStopped else {
        // Fail closed: never the display as a whole.
        CaptureRegistry.shared.note(
          id: id, "staged display could not be limited to the window's app, streaming the window in place")
        stagedDisplay = nil
        onCaptureDisplay?(nil)
        stage.leave(self)
        self.stage = nil
        return false
      }
      let narrowingMs = Int((CACurrentMediaTime() - narrowingStarted) * 1000)
      CaptureRegistry.shared.note(
        id: id,
        "staged on its display, \(Int(prepared.sourceRect.width))x\(Int(prepared.sourceRect.height)) pt"
          + " (staging \(prepared.timings); filter \(narrowingMs) ms, the app's other windows left out:"
          + " \(exceptedWindows.count))")
      queue.async {
        self.stagedTarget = target
        self.restartStream(
          target: target, content: prepared.sourceRect.size, sourceRect: prepared.sourceRect)
      }
      startWatch()
      startWindowWatch()
      return true
    } catch {
      CaptureRegistry.shared.note(id: id, "staging failed (\(error)), streaming the window in place")
      onCaptureDisplay?(nil)
      stage.leave(self)
      self.stage = nil
      return false
    }
  }

  /// The display went away under the stream: capture the window where the
  /// window server left it.
  @MainActor
  private func fallBack() {
    CaptureRegistry.shared.note(id: id, "virtual display lost, streaming the window in place")
    onCaptureDisplay?(nil)
    watch?.invalidate()
    watch = nil
    stage?.leave(self)
    stage = nil
    windowWatch?.invalidate()
    windowWatch = nil
    stagedDisplay = nil
    guard let window = window, !isStopped else { return }
    queue.async {
      self.stagedTarget = nil
      self.restartStream(target: .window(window), content: window.frame.size, sourceRect: nil)
    }
  }

  /// Once a second: is the staged window still there, still on its display,
  /// still the size the stream is cropped to?
  @MainActor
  private func startWatch() {
    watch?.invalidate()
    watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.check() }
    }
  }

  @MainActor
  private func check() {
    guard let stage = stage, onStage, !restaging, !isStopped else { return }
    if stage.windowGone {
      missingPolls += 1
      // Between Spaces a window is off every list for about a second.
      if missingPolls >= 3 {
        CaptureRegistry.shared.emit(id: id, kind: WSNCapture.kindStopped, flags: WSNCapture.errorNotFound)
        watch?.invalidate()
      }
      return
    }
    missingPolls = 0
    if stage.windowLeftDisplay, let window = window {
      // Until it is back, the display would show without it: nothing goes out.
      queue.async { self.hold() }
      restage(window)
      return
    }
    stage.evictStrangers()

  }

  @MainActor
  private func restage(_ window: SCWindow) {
    let (screen, scale) = queue.sync { (viewport, textScale) }
    guard screen.width > 0 else { return }
    restaging = true
    // A new size replaces the display. Let go of its stream first: a stream
    // whose display vanishes stops with an error, which would end the
    // whole session as if the window had closed.
    queue.sync {
      if let old = self.stream {
        self.stream = nil
        old.stopCapture(completionHandler: nil)
      }
    }
    Task { @MainActor in
      defer { restaging = false }
      if await !self.stage(window, screen: screen, scale: scale) {
        self.fallBack()
      }
    }
  }

  /// The viewer's screen or text scale changed (rotation, Aa).
  func setViewport(width: Double, height: Double, scale: Double) {
    queue.async { [weak self] in
      guard let self = self else { return }
      let screen = CGSize(width: width, height: height)
      let changed = screen != self.viewport || CGFloat(scale) != self.textScale
      self.viewport = screen
      self.textScale = scale > 0 ? CGFloat(scale) : 1
      guard changed, self.stream != nil else { return }
      DispatchQueue.main.async {
        guard let stage = self.stage, self.onStage, let window = self.window else { return }
        let wanted = VirtualStage.displaySize(viewport: screen, scale: CGFloat(scale))
        if !stage.matches(windowID: self.windowId, size: wanted) {
          CaptureRegistry.shared.note(
            id: self.id, "viewer screen now \(Int(width))x\(Int(height)), display resized")
          self.restage(window)
        }
      }
    }
  }

  /// Queue.
  private func targetSize(for content: CGSize) -> CGSize {
    let scale = viewerPixelRatio > 0
      ? viewerPixelRatio : max(NSScreen.screens.map(\.backingScaleFactor).max() ?? 2, 2)
    var width = content.width * scale
    var height = content.height * scale
    let longest = max(width, height)
    if maxEdge > 0, longest > CGFloat(maxEdge) {
      width *= CGFloat(maxEdge) / longest
      height *= CGFloat(maxEdge) / longest
    }
    // H.264 wants even dimensions.
    return CGSize(width: max(16, Int(width) & ~1), height: max(16, Int(height) & ~1))
  }

  /// Queue. Stops the running stream (if any) and starts one on [target].
  private func restartStream(target: CaptureTarget, content: CGSize, sourceRect: CGRect?) {
    lastFrame = nil
    if let old = stream {
      stream = nil
      old.stopCapture(completionHandler: nil)
    }
    startStream(target: target, content: content, sourceRect: sourceRect)
  }

  /// Queue.
  private func startStream(target: CaptureTarget, content: CGSize, sourceRect: CGRect?) {
    guard !stopped else { return }
    guard let filter = filter(for: target) else { return }
    holdingFrames = false
    lastStart = (target, content, sourceRect)
    let size = targetSize(for: content)
    let configuration = SCStreamConfiguration()
    configuration.width = Int(size.width)
    configuration.height = Int(size.height)
    configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    // A wedged encoder may keep one buffer; the mailbox keeps another.
    configuration.queueDepth = 5
    if let sourceRect = sourceRect {
      // A display of its own, shown whole: the Mac's mouse may be over
      // there, so the pointer is part of the picture.
      configuration.sourceRect = sourceRect
      configuration.showsCursor = cursorShown
      configuration.backgroundColor = .black
      if #available(macOS 14.0, *) {
        configuration.ignoreShadowsDisplay = true
      }
    } else {
      configuration.showsCursor = false
      configuration.scalesToFit = true
    }
    self.configuration = configuration
    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    do {
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    } catch {
      CaptureRegistry.shared.emit(id: id, kind: WSNCapture.kindFailed, flags: WSNCapture.errorUnknown)
      return
    }
    self.stream = stream
    forceKeyframe = true
    stream.startCapture { [weak self] error in
      guard let self = self, error != nil else { return }
      CaptureRegistry.shared.emit(id: self.id, kind: WSNCapture.kindFailed, flags: WSNCapture.errorPermission)
    }
  }

  func stop() {
    // Strong on purpose: the registry has just let go of this capture, and
    // the window still has to go home and the display away.
    queue.async { [self] in
      guard !self.stopped else { return }
      self.stopped = true
      self.audio.stop()
      self.stream?.stopCapture(completionHandler: nil)
      self.stream = nil
      self.pending = nil
      self.lastFrame = nil
      if let encoder = self.encoder {
        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(encoder)
      }
      self.encoder = nil
      DispatchQueue.main.async {
        self.watch?.invalidate()
        self.watch = nil
        self.windowWatch?.invalidate()
        self.windowWatch = nil
        self.parkTimer?.invalidate()
        self.parkTimer = nil
        self.stage?.leave(self)
        self.stage = nil
      }
    }
  }

  /// Typing latency: from a key reaching the Mac to the first picture
  /// sent after it, summed up in the log every few seconds.
  private let typedLock = NSLock()
  private var typedAt: Double?
  private var typedWait = 0.0
  private var typedLoggedAt = 0.0
  private var typedSamples: [Double] = []
  private var typedWaitMax = 0.0

  func viewerTyped(waited: Double) {
    typedLock.lock()
    if typedAt == nil {
      typedAt = CACurrentMediaTime()
      typedWait = waited
    }
    typedLock.unlock()
  }

  /// A packet went out: if it is the first since a key, how long it took.
  private func timeTyping() {
    let now = CACurrentMediaTime()
    typedLock.lock()
    guard let at = typedAt else {
      typedLock.unlock()
      return
    }
    typedAt = nil
    // Over 1 s: the key changed nothing on screen, not a slow picture.
    if now - at < 1 {
      typedSamples.append((now - at) * 1000)
      typedWaitMax = max(typedWaitMax, typedWait * 1000)
    }
    var summary: String?
    if now - typedLoggedAt > 3, !typedSamples.isEmpty {
      typedLoggedAt = now
      let sorted = typedSamples.sorted()
      summary =
        "keys \(sorted.count): key to picture median \(Int(sorted[sorted.count / 2])) ms, "
        + "max \(Int(sorted.last!)) ms (waiting for the app up to \(Int(typedWaitMax)) ms)"
      typedSamples.removeAll()
      typedWaitMax = 0
    }
    typedLock.unlock()
    if let summary = summary {
      CaptureRegistry.shared.note(id: id, summary)
    }
  }

  /// The viewer's keyboard covers [fraction] of the picture's bottom.
  func setBottomInset(_ fraction: Double) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, let stage = self.stage, self.onStage else { return }
      stage.setBottomInset(CGFloat(fraction))
    }
  }

  /// The viewer touched the picture.
  func viewerTouched() {
    queue.async { [weak self] in
      guard let self = self else { return }
      self.cursorHiddenUntil = CACurrentMediaTime() + 2.5
      self.setCursorShown(false)
      self.queue.asyncAfter(deadline: .now() + 2.6) { [weak self] in
        guard let self = self, CACurrentMediaTime() >= self.cursorHiddenUntil else { return }
        self.setCursorShown(true)
      }
    }
  }

  /// Queue.
  private func setCursorShown(_ shown: Bool) {
    guard shown != cursorShown else { return }
    cursorShown = shown
    guard stagedTarget != nil, let stream = stream, let configuration = configuration else { return }
    configuration.showsCursor = shown
    stream.updateConfiguration(configuration, completionHandler: nil)
  }

  func setBusy(_ value: Bool) {
    queue.async { [weak self] in
      guard let self = self, self.busy != value else { return }
      self.busy = value
      if !value, self.skippedWhileBusy, !self.stopped, !self.paused, self.inFlight == 0,
        let (buffer, time) = self.lastFrame
      {
        self.skippedWhileBusy = false
        self.encode(buffer, pts: time)
      }
    }
  }

  func requestKeyframe() {
    queue.async { [weak self] in
      self?.forceKeyframe = true
      self?.repeatLastFrameSoon()
    }
  }

  /// Queue. If no new frame turns up shortly, encode the last one again.
  private func repeatLastFrameSoon() {
    queue.asyncAfter(deadline: .now() + 0.06) { [weak self] in
      guard let self = self, self.forceKeyframe, !self.stopped, !self.paused,
        self.inFlight == 0, let (buffer, time) = self.lastFrame
      else { return }
      self.encode(buffer, pts: CMTimeAdd(time, CMTime(value: 1, timescale: 1000)))
    }
  }

  /// Paused means nobody is looking: a staged window goes back to the Mac
  /// meanwhile (and its display away), and returns when the viewer does.
  func setPaused(_ value: Bool) {
    queue.async { [weak self] in
      guard let self = self else { return }
      self.paused = value
      self.audio.setPaused(value)
      if !value {
        self.forceKeyframe = true
        self.repeatLastFrameSoon()
      }
      DispatchQueue.main.async {
        self.parkTimer?.invalidate()
        self.parkTimer = nil
        if value {
          // Switching between apps on the phone pauses for a moment; only a
          // longer pause sends the window home.
          guard self.stage != nil, self.onStage else { return }
          self.parkTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
            Task { @MainActor in self.park() }
          }
        } else if self.parked, let window = self.window {
          self.parked = false
          Task { @MainActor in await self.begin(window) }
        }
      }
    }
  }

  func setBitRate(_ value: Int) {
    queue.async { [weak self] in
      guard let self = self else { return }
      self.bitRate = value
      if let encoder = self.encoder {
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: value))
      }
    }
  }

  // MARK: What may be in the picture

  /// The only two things a stream may show. A viewer must see the window
  /// it opened and nothing else of this Mac:
  /// - in place: that one window (ScreenCaptureKit's desktop-independent
  ///   window, nothing around or over it);
  /// - staged: the window's own app on the virtual display it was put on,
  ///   so its menus, sheets, dialogs and popovers show too, minus the app's
  ///   other top-level windows. Never the display as a whole: other apps'
  ///   windows land there too (macOS puts windows back on a display it
  ///   remembers), and so do the menu bar's status items.
  enum CaptureTarget {
    case window(SCWindow)
    case staged(display: SCDisplay, app: SCRunningApplication, excepted: [SCWindow])
  }

  /// Queue. The filter for [target], or nil (and the capture fails) when it
  /// would not be limited to this window.
  private func filter(for target: CaptureTarget) -> SCContentFilter? {
    let filter: SCContentFilter
    switch target {
    case .window(let window):
      guard window.windowID == windowId else {
        refuse("in-place filter for window \(window.windowID)")
        return nil
      }
      filter = SCContentFilter(desktopIndependentWindow: window)
    case .staged(let display, let app, let excepted):
      guard windowPid > 0, app.processID == windowPid,
        excepted.allSatisfy({ $0.windowID != windowId })
      else {
        refuse("staged filter for pid \(app.processID), window pid \(windowPid)")
        return nil
      }
      filter = SCContentFilter(display: display, including: [app], exceptingWindows: excepted)
    }
    // Where the system can say what a filter holds, check it again.
    if #available(macOS 15.2, *) {
      let pid = windowPid
      let apps = filter.includedApplications.map(\.processID)
      let windows = filter.includedWindows
      let ok: Bool
      switch target {
      case .window:
        ok = windows.allSatisfy { $0.windowID == windowId } && apps.allSatisfy { $0 == pid }
      case .staged:
        ok = apps.allSatisfy { $0 == pid }
          && windows.allSatisfy { $0.owningApplication?.processID == pid }
      }
      guard ok else {
        refuse("filter holds apps \(apps), windows \(windows.map(\.windowID))")
        return nil
      }
    }
    return filter
  }

  /// Queue. No picture goes out until the filter is right again, not even
  /// one already taken or in the encoder.
  private func hold() {
    holdingFrames = true
    lastFrame = nil
    pending = nil
  }

  /// Fails closed: no stream at all rather than a wrong one.
  private func refuse(_ why: String) {
    CaptureRegistry.shared.note(id: id, "refused to capture: \(why) (asked for window \(windowId))")
    CaptureRegistry.shared.emit(id: id, kind: WSNCapture.kindFailed, flags: WSNCapture.errorNotFound)
  }

  /// The staged target for [window] on [stagedDisplay]: its app, minus the
  /// app's top-level windows other than this one. Nil when the app or the
  /// display cannot be matched.
  @MainActor
  private func stagedTarget(_ window: SCWindow, content given: SCShareableContent?) async
    -> CaptureTarget?
  {
    let pid = queue.sync { windowPid }
    guard pid > 0, window.windowID == windowId, let display = stagedDisplay else {
      CaptureRegistry.shared.note(id: id, "filter: no pid (\(pid)) or no staged display")
      return nil
    }
    var content = given
    if content?.applications.contains(where: { $0.processID == pid }) != true {
      // All windows, on screen or not: an app whose windows were on another
      // Space is not listed otherwise, and its other windows must be known.
      do {
        content = try await SCShareableContent.excludingDesktopWindows(
          false, onScreenWindowsOnly: false)
      } catch {
        CaptureRegistry.shared.note(id: id, "filter: no shareable content (\(error))")
        return nil
      }
    }
    guard let content = content,
      let app = content.applications.first(where: { $0.processID == pid })
    else {
      CaptureRegistry.shared.note(id: id, "filter: app \(pid) not in the shareable content")
      return nil
    }
    let unknown = content.windows.filter {
      $0.owningApplication?.processID == pid && $0.windowID != windowId && $0.windowLayer == 0
        && !exceptedWindows.contains($0.windowID) && !allowedWindows.contains($0.windowID)
    }
    if !unknown.isEmpty {
      let roles = AppWindowRoles.roles(pid: pid)
      let targetFrame = VirtualStage.liveBounds(of: windowId)
      for other in unknown {
        if roles.belongsToTarget(other.windowID, frame: other.frame, targetFrame: targetFrame) {
          allowedWindows.insert(other.windowID)
        } else {
          exceptedWindows.insert(other.windowID)
        }
      }
    }
    let excepted = content.windows.filter { exceptedWindows.contains($0.windowID) }
    filteredExcepted = Set(excepted.map(\.windowID))
    return .staged(display: display, app: app, excepted: excepted)
  }

  /// Four times a second while staged: a new top-level window of the app on
  /// the display (a second document macOS put back there, say) is left out
  /// of the picture before it is ever seen for long; frames wait meanwhile.
  @MainActor
  private func startWindowWatch() {
    windowWatch?.invalidate()
    windowWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.checkWindows() }
    }
  }

  @MainActor
  private func checkWindows() {
    guard !narrowing, !restaging, let stage = stage, onStage, let displayID = stage.displayID,
      let window = window,
      // Every window, not only those on screen: the window server reports
      // windows on Whisper's display as off screen while the Mac's own
      // screen shows a full-screen Space, and ScreenCaptureKit still
      // captures them.
      let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return }
    let pid = queue.sync { windowPid }
    let bounds = CGDisplayBounds(displayID)
    var narrow = false
    var roles: AppWindowRoles.Roles?
    for info in list {
      guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
        (info[kCGWindowLayer as String] as? Int) == 0,
        let other = info[kCGWindowNumber as String] as? CGWindowID, other != windowId,
        !allowedWindows.contains(other),
        let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
        let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
        frame.intersects(bounds)
      else { continue }
      if exceptedWindows.contains(other) {
        narrow = narrow || !filteredExcepted.contains(other)
        continue
      }
      if roles == nil {
        roles = AppWindowRoles.roles(pid: pid)
      }
      if roles!.belongsToTarget(other, frame: frame, targetFrame: VirtualStage.liveBounds(of: windowId)) {
        allowedWindows.insert(other)
      } else {
        exceptedWindows.insert(other)
        narrow = true
      }
    }
    guard narrow else { return }
    narrowing = true
    queue.async { self.hold() }
    CaptureRegistry.shared.note(id: id, "another window of the app came onto the display: left out")
    Task { @MainActor in
      defer { narrowing = false }
      guard let target = await stagedTarget(window, content: nil),
        let filter = queue.sync(execute: { () -> SCContentFilter? in
          guard !stopped, stagedTarget != nil else { return nil }
          return self.filter(for: target)
        })
      else { return }
      queue.async {
        guard let stream = self.stream, self.stagedTarget != nil else { return }
        self.stagedTarget = target
        stream.updateContentFilter(filter) { [weak self] error in
          guard let self = self else { return }
          self.queue.async {
            if let error = error {
              // Could not narrow it: stop rather than show it.
              CaptureRegistry.shared.note(
                id: self.id, "could not leave the window out (\(error.localizedDescription))")
              CaptureRegistry.shared.emit(
                id: self.id, kind: WSNCapture.kindStopped, flags: WSNCapture.errorUnknown)
              return
            }
            self.holdingFrames = false
            self.forceKeyframe = true
          }
        }
      }
    }
  }

  // MARK: SCStreamOutput

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
              of type: SCStreamOutputType) {
    guard type == .screen, !stopped, !paused, !holdingFrames, stream === self.stream,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]],
      let rawStatus = attachments.first?[.status] as? Int,
      SCFrameStatus(rawValue: rawStatus) == .complete,
      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    lastFrame = (pixelBuffer, pts)
    if busy {
      skippedWhileBusy = true
      return
    }
    // One frame in the encoder at a time; the newest waiting frame replaces
    // an older one, so a slow moment never builds a backlog.
    if inFlight > 0 {
      pending = (pixelBuffer, pts)
      return
    }
    encode(pixelBuffer, pts: pts)
  }

  private func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
    let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    if encoder == nil || size != encodedSize {
      guard createEncoder(size: size) else { return }
      CaptureRegistry.shared.emit(
        id: id, kind: WSNCapture.kindSize, width: Int32(size.width), height: Int32(size.height))
    }
    guard let encoder = encoder else { return }
    inFlight += 1
    var properties: CFDictionary?
    if forceKeyframe {
      forceKeyframe = false
      properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
    }
    let status = VTCompressionSessionEncodeFrame(
      encoder, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
      frameProperties: properties, infoFlagsOut: nil
    ) { [weak self] status, _, encoded in
      self?.queue.async {
        guard let self = self else { return }
        self.inFlight -= 1
        if status == noErr, let encoded = encoded, !self.stopped, !self.holdingFrames {
          self.emit(encoded)
        }
        if let (buffer, time) = self.pending, !self.stopped, !self.paused, !self.holdingFrames {
          self.pending = nil
          self.encode(buffer, pts: time)
        }
      }
    }
    if status != noErr {
      inFlight -= 1
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    guard stream === self.stream else { return }
    CaptureRegistry.shared.note(id: id, "capture stopped: \(error.localizedDescription)")
    CaptureRegistry.shared.emit(id: id, kind: WSNCapture.kindStopped, flags: WSNCapture.errorUnknown)
  }

  // MARK: Encoder

  private func createEncoder(size: CGSize) -> Bool {
    if let old = encoder {
      VTCompressionSessionInvalidate(old)
      encoder = nil
    }
    var session: VTCompressionSession?
    func create(_ spec: [CFString: Any]) -> OSStatus {
      VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault, width: Int32(size.width), height: Int32(size.height),
        codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
        refcon: nil, compressionSessionOut: &session)
    }
    // The low-latency mode made for calls: frames come out as soon as they
    // are encoded, with rate control that never holds one back. Constrained
    // High is what it encodes; older Macs fall back to the usual encoder.
    var lowLatency = false
    if #available(macOS 12.0, *) {
      lowLatency = create([
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
      ]) == noErr && session != nil
    }
    if !lowLatency {
      session = nil
      _ = create([kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true])
    }
    guard let created = session else {
      CaptureRegistry.shared.emit(id: id, kind: WSNCapture.kindFailed, flags: WSNCapture.errorEncoder)
      return false
    }
    VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    if #available(macOS 12.0, *), lowLatency {
      VTSessionSetProperty(
        created, key: kVTCompressionPropertyKey_ProfileLevel,
        value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
      VTSessionSetProperty(
        created, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
        value: kCFBooleanTrue)
    } else {
      VTSessionSetProperty(
        created, key: kVTCompressionPropertyKey_ProfileLevel,
        value: kVTProfileLevel_H264_Main_AutoLevel)
    }
    VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    // Each frame comes out before the next goes in.
    VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0))
    VTSessionSetProperty(
      created, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitRate))
    VTSessionSetProperty(
      created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 4))
    VTSessionSetProperty(
      created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
    VTCompressionSessionPrepareToEncodeFrames(created)
    encoder = created
    encodedSize = size
    forceKeyframe = true
    return true
  }

  private static let startCode: [UInt8] = [0, 0, 0, 1]

  /// AVCC sample → Annex-B packets; parameter sets go out as a separate
  /// config packet whenever they change or a keyframe is sent.
  private func emit(_ sample: CMSampleBuffer) {
    guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
      as? [[CFString: Any]]
    let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
    let isKey = !notSync
    let ptsUs = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1_000_000)

    if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
      var config = Data()
      var count = 0
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
        parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
      for index in 0..<count {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
          format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
          parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
          == noErr, let pointer = pointer
        {
          config.append(contentsOf: WindowCapture.startCode)
          config.append(pointer, count: size)
        }
      }
      if !config.isEmpty {
        lastParameterSets = config
        emitPacket(config, ptsUs: 0, flags: WSNConst.packetConfig)
      }
    }

    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<CChar>?
    guard
      CMBlockBufferGetDataPointer(
        block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength,
        dataPointerOut: &dataPointer) == kCMBlockBufferNoErr, let base = dataPointer
    else { return }
    var annexB = Data(capacity: totalLength + 16)
    var offset = 0
    base.withMemoryRebound(to: UInt8.self, capacity: totalLength) { bytes in
      while offset + 4 <= totalLength {
        let length =
          Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8
          | Int(bytes[offset + 3])
        offset += 4
        guard length > 0, offset + length <= totalLength else { break }
        annexB.append(contentsOf: WindowCapture.startCode)
        annexB.append(bytes + offset, count: length)
        offset += length
      }
    }
    emitPacket(annexB, ptsUs: ptsUs, flags: isKey ? WSNConst.packetKey : 0)
  }

  private func emitPacket(_ data: Data, ptsUs: Int64, flags: Int32) {
    timeTyping()
    if !firstPictureNoted, flags & WSNConst.packetConfig == 0 {
      firstPictureNoted = true
      let ms = Int((CACurrentMediaTime() - startedAt) * 1000)
      CaptureRegistry.shared.note(id: id, "first picture \(ms) ms after the capture started")
    }
    guard let buffer = malloc(max(data.count, 1))?.assumingMemoryBound(to: UInt8.self) else { return }
    data.copyBytes(to: buffer, count: data.count)
    CaptureRegistry.shared.emit(
      id: id, kind: WSNCapture.kindPacket, data: buffer, length: Int32(data.count), ptsUs: ptsUs,
      flags: flags, width: Int32(encodedSize.width), height: Int32(encodedSize.height))
  }
}

/// Tells the app's own extra windows (sheets, dialogs, panels, popovers) from
/// its other top-level windows, through Accessibility.
enum AppWindowRoles {
  private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>)
    -> AXError
  /// Private but the only exact AX element → CGWindowID mapping (as in
  /// VirtualStage); without it nothing matches, which leaves windows out.
  private static let getWindow: GetWindowFn? = {
    guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "_AXUIElementGetWindow")
    else { return nil }
    return unsafeBitCast(symbol, to: GetWindowFn.self)
  }()

  /// One pass over the app's windows: which are standard (documents) and
  /// which are its sheets, dialogs and panels.
  struct Roles {
    var standard = Set<CGWindowID>()
    var attached = Set<CGWindowID>()

    /// Whether window [id] is part of the target: a sheet, dialog or panel,
    /// or (unknown to Accessibility) something laid inside the target. A
    /// standard window is not, nor is anything else: unknown means out.
    func belongsToTarget(_ id: CGWindowID, frame: CGRect?, targetFrame: CGRect?) -> Bool {
      if standard.contains(id) { return false }
      if attached.contains(id) { return true }
      guard let frame = frame, let targetFrame = targetFrame else { return false }
      return targetFrame.insetBy(dx: -2, dy: -2).contains(frame)
    }
  }

  static func roles(pid: pid_t) -> Roles {
    var roles = Roles()
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
      let windows = value as? [AXUIElement]
    else { return roles }
    for element in windows {
      if let id = windowID(of: element) {
        if string(element, kAXSubroleAttribute) == (kAXStandardWindowSubrole as String) {
          roles.standard.insert(id)
        } else {
          roles.attached.insert(id)
        }
      }
      // Sheets are children of their window, not in the app's list.
      var children: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        == .success, let children = children as? [AXUIElement]
      {
        for child in children where string(child, kAXRoleAttribute) == (kAXSheetRole as String) {
          if let id = windowID(of: child) {
            roles.attached.insert(id)
          }
        }
      }
    }
    return roles
  }

  private static func windowID(of element: AXUIElement) -> CGWindowID? {
    guard let getWindow = getWindow else { return nil }
    var id: CGWindowID = 0
    return getWindow(element, &id) == .success && id != 0 ? id : nil
  }

  private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    else { return nil }
    return value as? String
  }
}
