import AVFoundation
import AppKit

/// Owns the NSWindow of one streamed app. Main thread only.
final class StreamWindowController: NSObject, NSWindowDelegate {
  private let surfaceId: Int64
  private let window: NSWindow
  private let videoView: StreamVideoView
  private var videoSize: CGSize
  private var closing = false
  /// WSN_FLAG_REFLOW: the other side lays the streamed window out for this
  /// window's size, so the window resizes freely (picture letterboxed) and
  /// settles to the picture's shape only if that does not follow.
  private let reflow: Bool
  private var settleWork: DispatchWorkItem?
  private var settling = false
  private let volumeControl: WindowVolumeControl

  /// The user changed the volume in the window's control.
  var onVolume: ((Double) -> Void)? {
    get { volumeControl.onChange }
    set { volumeControl.onChange = newValue }
  }

  /// Shapes within this much of each other count as the same.
  private static let aspectTolerance: CGFloat = 0.02
  /// After a resize, how long the other side has to follow before the
  /// window settles to the picture's shape.
  private static let settleDelay: TimeInterval = 2

  init(
    surfaceId: Int64, title: String, videoSize: CGSize, showHud: Bool, reflow: Bool = false,
    volume: Double = 1
  ) {
    self.surfaceId = surfaceId
    self.reflow = reflow
    self.videoSize = videoSize.width > 0 && videoSize.height > 0
      ? videoSize : CGSize(width: 1080, height: 2400)
    NSWindow.allowsAutomaticWindowTabbing = false
    let contentSize = StreamWindowController.initialContentSize(for: self.videoSize)
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    videoView = StreamVideoView(surfaceId: surfaceId, showHud: showHud)
    volumeControl = WindowVolumeControl(surfaceId: surfaceId, volume: volume)
    super.init()
    window.title = title
    window.isReleasedWhenClosed = false
    // Auxiliary, not primary: a primary window opens as its own full-screen
    // space whenever Whisper's main window is full screen. Streamed windows
    // always open as ordinary windows (over a full-screen space if need be).
    window.collectionBehavior = [.fullScreenAuxiliary, .managed]
    window.backgroundColor = .black
    window.contentView = videoView
    if !reflow {
      window.contentAspectRatio = self.videoSize
    }
    window.minSize = NSSize(width: 200, height: 200)
    window.delegate = self
    videoView.videoSize = self.videoSize
    window.center()
  }

  private static func initialContentSize(for video: CGSize) -> NSSize {
    let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
    let maxHeight = max(320, visible.height * 0.82)
    let maxWidth = max(320, visible.width * 0.6)
    var height = min(maxHeight, 900)
    var width = height * video.width / video.height
    if width > maxWidth {
      width = maxWidth
      height = width * video.height / video.width
    }
    return NSSize(width: width.rounded(), height: height.rounded())
  }

  func show() {
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.makeFirstResponder(videoView)
    // The window as it really came out (the screen may have trimmed it):
    // the other side lays the window out for exactly this.
    reportSize()
    // Opened as an ordinary window, it may then go full screen like any
    // other: the green button and ⌃⌘F work.
    DispatchQueue.main.async { [weak self] in
      self?.window.collectionBehavior = [.fullScreenPrimary, .managed]
    }
  }

  func close() {
    closing = true
    settleWork?.cancel()
    settleWork = nil
    volumeControl.close()
    window.delegate = nil
    window.orderOut(nil)
    window.close()
  }

  func focus() {
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func setTitle(_ title: String) {
    window.title = title
  }

  /// The streamed app's icon: beside the title, the way a document window
  /// shows its file's icon, and as the window's tile in the Dock when it is
  /// minimized, so it reads as that app rather than as Whisper.
  func setIcon(_ png: Data) {
    guard let image = NSImage(data: png) else { return }
    // The title icon belongs to a represented file; any folder will do, its
    // menu and dragging are turned off below.
    window.representedURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    if let button = window.standardWindowButton(.documentIconButton),
      let small = image.copy() as? NSImage
    {
      small.size = NSSize(width: 16, height: 16)
      button.image = small
    }
    window.miniwindowImage = image
    videoView.setLoadingIcon(image)
  }

  func window(_ window: NSWindow, shouldPopUpDocumentPathMenu menu: NSMenu) -> Bool { false }

  func window(
    _ window: NSWindow, shouldDragDocumentWith event: NSEvent, from dragImageLocation: NSPoint,
    with pasteboard: NSPasteboard
  ) -> Bool { false }

  func setVisual(_ visual: Int32, message: String?) {
    videoView.setVisual(visual, message: message)
  }

  func setHudText(_ text: String) {
    videoView.setHudText(text)
  }

  /// The window has sound: its volume control shows in the title bar.
  func showVolumeControl() {
    volumeControl.show(in: window)
  }

  /// From Dart (not reported back).
  func setVolume(_ value: Double) {
    volumeControl.setVolume(value)
  }

  func refreshStrings() {
    volumeControl.refreshStrings()
  }

  func enqueue(_ sampleBuffer: CMSampleBuffer) {
    videoView.enqueue(sampleBuffer)
  }

  /// A frame of [size] went up: the loading cover lifts once they settle.
  func noteFrame(_ size: CGSize) {
    videoView.noteFrame(size)
  }

  /// Keeps the window's height and centre when the stream's size changes,
  /// e.g. after rotation or a display resize.
  func updateVideoSize(_ size: CGSize) {
    guard size.width > 0, size.height > 0, size != videoSize else { return }
    videoSize = size
    videoView.videoSize = size
    let frame = window.frame
    let content = window.contentRect(forFrameRect: frame)
    if reflow {
      // A new picture: the other side answered, nothing to settle.
      settleWork?.cancel()
      settleWork = nil
      // Laid out for this window (near enough), or the user is on it.
      if StreamWindowController.sameShape(content.size, size) || window.inLiveResize
        || window.styleMask.contains(.fullScreen)
      {
        return
      }
    } else {
      window.contentAspectRatio = size
    }
    let height = content.height
    let width = (height * size.width / size.height).rounded()
    let newContent = NSRect(
      x: content.midX - width / 2, y: content.minY, width: width, height: height)
    // Following the picture's new shape is not the user resizing: the other
    // side already has this size.
    followingVideo = true
    window.setFrame(window.frameRect(forContentRect: newContent), display: true, animate: true)
    followingVideo = false
  }

  private var followingVideo = false

  private static func sameShape(_ a: CGSize, _ b: CGSize) -> Bool {
    guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return true }
    return abs((a.width / a.height) / (b.width / b.height) - 1) <= aspectTolerance
  }

  /// REFLOW, after the user resized: if the picture has not taken the
  /// window's new shape by `settleDelay`, the window takes the picture's,
  /// shrinking one side around its centre so the picture fits the frame.
  private func scheduleSettle() {
    settleWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.settle() }
    settleWork = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + StreamWindowController.settleDelay, execute: work)
  }

  private func settle() {
    settleWork = nil
    guard !closing, !window.inLiveResize, !window.isMiniaturized,
      !window.styleMask.contains(.fullScreen)
    else { return }
    let content = window.contentRect(forFrameRect: window.frame)
    guard !StreamWindowController.sameShape(content.size, videoSize) else { return }
    var fitted = AVMakeRect(aspectRatio: videoSize, insideRect: content)
    // No smaller than the window may be.
    let grow = max(1, window.minSize.width / fitted.width, window.minSize.height / fitted.height)
    fitted.size = CGSize(
      width: (fitted.width * grow).rounded(), height: (fitted.height * grow).rounded())
    fitted.origin = CGPoint(
      x: (content.midX - fitted.width / 2).rounded(), y: (content.midY - fitted.height / 2).rounded())
    settling = true
    window.setFrame(
      window.frameRect(forContentRect: fitted), display: true,
      animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    settling = false
    // The other side lays the window out for its settled size.
    reportSize()
  }

  /// Tells the other side how much room the window has, in points.
  private func reportSize() {
    let size = window.contentRect(forFrameRect: window.frame).size
    SurfaceRegistry.shared.emitWindow(
      surface: surfaceId, kind: WSNConst.windowResized, a: Double(size.width),
      b: Double(size.height), c: Double(window.backingScaleFactor))
  }

  // MARK: NSWindowDelegate

  /// Zoom (double-clicking the title bar, ⌥ + green button) fills the
  /// screen as far as the picture's shape allows; with REFLOW all of it
  /// (the other side lays the window out for it).
  func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
    if reflow {
      return newFrame
    }
    let available = window.contentRect(forFrameRect: newFrame)
    guard videoSize.width > 0, videoSize.height > 0 else { return newFrame }
    let scale = min(available.width / videoSize.width, available.height / videoSize.height)
    let width = (videoSize.width * scale).rounded(.down)
    let height = (videoSize.height * scale).rounded(.down)
    let content = NSRect(
      x: available.midX - width / 2, y: available.maxY - height, width: width, height: height)
    return window.frameRect(forContentRect: content)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if !closing {
      SurfaceRegistry.shared.emitWindow(surface: surfaceId, kind: WSNConst.windowCloseRequested)
    }
    return true
  }

  func windowDidBecomeKey(_ notification: Notification) {
    SurfaceRegistry.shared.emitWindow(surface: surfaceId, kind: WSNConst.windowFocus, a: 1)
  }

  func windowDidResignKey(_ notification: Notification) {
    SurfaceRegistry.shared.emitWindow(surface: surfaceId, kind: WSNConst.windowFocus, a: 0)
  }

  func windowDidChangeOcclusionState(_ notification: Notification) {
    let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized
    SurfaceRegistry.shared.emitWindow(
      surface: surfaceId, kind: WSNConst.windowVisibility, a: visible ? 1 : 0)
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    reportSize()
    if reflow {
      scheduleSettle()
    }
  }

  func windowWillStartLiveResize(_ notification: Notification) {
    settleWork?.cancel()
    settleWork = nil
  }

  /// Zoom, full screen, or the screen trimming it: resized without a drag.
  func windowDidResize(_ notification: Notification) {
    if !window.inLiveResize && !followingVideo && !settling {
      reportSize()
    }
  }

  /// Moved to a screen with another scale.
  func windowDidChangeBackingProperties(_ notification: Notification) {
    reportSize()
  }
}

/// Shows the video and turns mouse, trackpad and keyboard input into
/// normalised events (0–1 inside the video rect, origin top-left).
final class StreamVideoView: NSView {
  private let surfaceId: Int64
  private let displayLayer = AVSampleBufferDisplayLayer()
  private let hudLabel = NSTextField(labelWithString: "")
  private let overlay = NSVisualEffectView()
  private let overlayLabel = NSTextField(labelWithString: "")
  private var visual: Int32 = WSNConst.visualConnecting
  private var pressedButton: Int32 = -1

  // The loading cover: the app's icon and a spinner over black, from the
  // moment the window opens until the picture has settled at its final
  // size (the other side resizes the window for this one first), so the
  // first frames at the wrong size never show.
  private let loading = NSView()
  private let loadingIcon = NSImageView()
  private let spinner = NSProgressIndicator()
  private let loadingLabel = NSTextField(labelWithString: "")
  private var settled = false
  private var firstFrameAt: CFTimeInterval?
  private var frameSize = CGSize.zero
  private var sizeChangedAt: CFTimeInterval = 0
  private var settleCheck: DispatchWorkItem?
  private var connectingHint: DispatchWorkItem?
  private var connectingMessage = ""
  /// Resumed after a pause, waiting for the picture to come back.
  private var awaitingFrame = false
  private var resumeCheck: DispatchWorkItem?

  /// Sizes stop changing for this long before the picture shows.
  private static let settleQuiet: CFTimeInterval = 0.3
  /// Shown this long after the first frame whatever the sizes do.
  private static let settleCap: CFTimeInterval = 2.5
  /// Connecting this long, the cover says so in words too.
  private static let hintAfter: TimeInterval = 8

  var videoSize = CGSize(width: 1080, height: 2400) {
    didSet { needsLayout = true }
  }

  init(surfaceId: Int64, showHud: Bool) {
    self.surfaceId = surfaceId
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = NSColor.black.cgColor
    layer?.addSublayer(displayLayer)

    hudLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
    hudLabel.textColor = .white
    hudLabel.drawsBackground = true
    hudLabel.backgroundColor = NSColor.black.withAlphaComponent(0.55)
    hudLabel.isHidden = !showHud
    hudLabel.maximumNumberOfLines = 0
    addSubview(hudLabel)

    overlay.material = .hudWindow
    overlay.blendingMode = .withinWindow
    overlay.state = .active
    overlayLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    overlayLabel.textColor = .labelColor
    overlayLabel.alignment = .center
    overlayLabel.maximumNumberOfLines = 3
    overlayLabel.lineBreakMode = .byWordWrapping
    overlay.addSubview(overlayLabel)

    loading.wantsLayer = true
    loading.layer?.backgroundColor = NSColor.black.cgColor
    loading.appearance = NSAppearance(named: .darkAqua)
    loadingIcon.imageScaling = .scaleProportionallyUpOrDown
    loading.addSubview(loadingIcon)
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    loading.addSubview(spinner)
    loadingLabel.font = .systemFont(ofSize: 13, weight: .medium)
    loadingLabel.textColor = NSColor.white.withAlphaComponent(0.72)
    loadingLabel.alignment = .center
    loadingLabel.maximumNumberOfLines = 2
    loadingLabel.lineBreakMode = .byWordWrapping
    loadingLabel.isHidden = true
    loading.addSubview(loadingLabel)
    addSubview(loading)
    spinner.startAnimation(nil)

    addSubview(overlay)
    updateOverlay(message: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("not supported")
  }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    displayLayer.frame = bounds
    CATransaction.commit()
    hudLabel.sizeToFit()
    hudLabel.frame.origin = NSPoint(x: 8, y: bounds.height - hudLabel.frame.height - 8)
    overlay.frame = bounds
    let labelWidth = min(bounds.width - 48, 320)
    overlayLabel.frame = NSRect(
      x: (bounds.width - labelWidth) / 2, y: bounds.midY - 40, width: labelWidth, height: 80)
    loading.frame = bounds
    let icon: CGFloat = loadingIcon.image == nil ? 0 : 64
    let gap: CGFloat = icon > 0 ? 18 : 0
    let spin: CGFloat = 16
    let top = bounds.midY + (icon + gap + spin) / 2
    loadingIcon.frame = NSRect(x: bounds.midX - icon / 2, y: top - icon, width: icon, height: icon)
    spinner.frame = NSRect(
      x: bounds.midX - spin / 2, y: top - icon - gap - spin, width: spin, height: spin)
    loadingLabel.frame = NSRect(
      x: (bounds.width - labelWidth) / 2, y: spinner.frame.minY - 14 - 36, width: labelWidth,
      height: 36)
  }

  func setLoadingIcon(_ image: NSImage) {
    loadingIcon.image = image
    needsLayout = true
  }

  // MARK: Loading cover

  private static var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private func showLoading() {
    loading.alphaValue = 1
    loading.isHidden = false
    spinner.startAnimation(nil)
  }

  private func hideLoading() {
    guard !loading.isHidden else { return }
    connectingHint?.cancel()
    if StreamVideoView.reduceMotion {
      loading.isHidden = true
      spinner.stopAnimation(nil)
      return
    }
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.18
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      loading.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      guard let self = self, self.loading.alphaValue == 0 else { return }
      self.loading.isHidden = true
      self.spinner.stopAnimation(nil)
    })
  }

  /// A frame of [size] went up. The cover lifts once sizes have stopped
  /// changing for a moment with the picture at its size, or a little after
  /// the first frame whatever they do.
  func noteFrame(_ size: CGSize) {
    let now = CACurrentMediaTime()
    if firstFrameAt == nil {
      firstFrameAt = now
    }
    if size != frameSize {
      frameSize = size
      sizeChangedAt = now
    }
    if awaitingFrame {
      awaitingFrame = false
      resumeCheck?.cancel()
      if visual == WSNConst.visualLive {
        hideLoading()
      }
    }
    if !settled {
      scheduleSettleCheck()
    }
  }

  private func scheduleSettleCheck() {
    settleCheck?.cancel()
    guard let first = firstFrameAt else { return }
    let due = min(sizeChangedAt + StreamVideoView.settleQuiet, first + StreamVideoView.settleCap)
    let work = DispatchWorkItem { [weak self] in self?.checkSettled() }
    settleCheck = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + max(0, due - CACurrentMediaTime()), execute: work)
  }

  private func checkSettled() {
    guard !settled, let first = firstFrameAt else { return }
    let now = CACurrentMediaTime()
    guard now - sizeChangedAt >= StreamVideoView.settleQuiet - 0.005
      || now - first >= StreamVideoView.settleCap - 0.005
    else {
      scheduleSettleCheck()
      return
    }
    settled = true
    if visual == WSNConst.visualLive {
      hideLoading()
    }
  }

  /// Back from a pause: the cover returns only if the picture is slow to.
  private func awaitResumedFrame() {
    awaitingFrame = true
    resumeCheck?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, self.awaitingFrame, self.visual == WSNConst.visualLive else { return }
      self.loadingLabel.isHidden = true
      self.showLoading()
    }
    resumeCheck = work
    DispatchQueue.main.asyncAfter(deadline: .now() + StreamVideoView.settleQuiet, execute: work)
  }

  func enqueue(_ sampleBuffer: CMSampleBuffer) {
    if displayLayer.status == .failed {
      displayLayer.flush()
      SurfaceRegistry.shared.emitWindow(surface: surfaceId, kind: WSNConst.windowNeedKeyframe)
    }
    displayLayer.enqueue(sampleBuffer)
  }

  func setHudText(_ text: String) {
    hudLabel.stringValue = text
    needsLayout = true
  }

  func setVisual(_ newVisual: Int32, message: String?) {
    let previous = visual
    visual = newVisual
    connectingHint?.cancel()
    if newVisual == WSNConst.visualConnecting {
      // Connecting: the cover alone; its words only if it takes a while.
      connectingMessage = message ?? ""
      loadingLabel.isHidden = true
      if !settled {
        showLoading()
      }
      let work = DispatchWorkItem { [weak self] in
        guard let self = self, self.visual == WSNConst.visualConnecting else { return }
        self.loadingLabel.stringValue = self.connectingMessage
        self.loadingLabel.isHidden = self.connectingMessage.isEmpty
      }
      connectingHint = work
      DispatchQueue.main.asyncAfter(deadline: .now() + StreamVideoView.hintAfter, execute: work)
    } else if newVisual == WSNConst.visualLive {
      if !settled {
        loadingLabel.isHidden = true
        showLoading()
      } else {
        if previous == WSNConst.visualPaused || previous == WSNConst.visualReconnecting {
          awaitResumedFrame()
        } else if !awaitingFrame {
          hideLoading()
        }
      }
    } else {
      awaitingFrame = false
      resumeCheck?.cancel()
      loading.isHidden = true
      loading.alphaValue = 0
    }
    updateOverlay(message: message)
  }

  private func updateOverlay(message: String?) {
    overlay.isHidden = visual == WSNConst.visualLive || visual == WSNConst.visualConnecting
    overlayLabel.stringValue = message ?? ""
    overlay.alphaValue = visual == WSNConst.visualPaused ? 0.86 : 1
  }

  // MARK: Coordinates

  private var videoRect: CGRect {
    AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
  }

  private func normalized(_ event: NSEvent) -> CGPoint? {
    let point = convert(event.locationInWindow, from: nil)
    let rect = videoRect
    guard rect.width > 0, rect.height > 0 else { return nil }
    let x = (point.x - rect.minX) / rect.width
    let y = 1 - (point.y - rect.minY) / rect.height
    return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
  }

  private func isInsideVideo(_ event: NSEvent) -> Bool {
    videoRect.contains(convert(event.locationInWindow, from: nil))
  }

  private static func modifiers(_ flags: NSEvent.ModifierFlags) -> Int32 {
    var value: Int32 = 0
    if flags.contains(.shift) { value |= WSNConst.modShift }
    if flags.contains(.control) { value |= WSNConst.modControl }
    if flags.contains(.option) { value |= WSNConst.modOption }
    if flags.contains(.command) { value |= WSNConst.modCommand }
    if flags.contains(.capsLock) { value |= WSNConst.modCapsLock }
    if flags.contains(.function) { value |= WSNConst.modFunction }
    return value
  }

  // MARK: Pointer

  private func pointer(_ kind: Int32, button: Int32, event: NSEvent) {
    guard let point = normalized(event) else { return }
    SurfaceRegistry.shared.emitInput(
      surface: surfaceId, kind: kind, code: button,
      modifiers: StreamVideoView.modifiers(event.modifierFlags), x: point.x, y: point.y)
  }

  private func handleDown(_ event: NSEvent, button: Int32) {
    if visual == WSNConst.visualPaused || visual == WSNConst.visualDisplaced {
      SurfaceRegistry.shared.emitWindow(
        surface: surfaceId, kind: WSNConst.windowAction,
        a: visual == WSNConst.visualPaused ? 1 : 2)
      return
    }
    guard visual == WSNConst.visualLive, pressedButton < 0, isInsideVideo(event) else { return }
    pressedButton = button
    pointer(WSNConst.inputPointerDown, button: button, event: event)
  }

  private func handleDrag(_ event: NSEvent, button: Int32) {
    guard pressedButton == button else { return }
    pointer(WSNConst.inputPointerMove, button: button, event: event)
  }

  private func handleUp(_ event: NSEvent, button: Int32) {
    guard pressedButton == button else { return }
    pressedButton = -1
    pointer(WSNConst.inputPointerUp, button: button, event: event)
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    handleDown(event, button: 0)
  }

  override func mouseDragged(with event: NSEvent) { handleDrag(event, button: 0) }
  override func mouseUp(with event: NSEvent) { handleUp(event, button: 0) }
  override func rightMouseDown(with event: NSEvent) { handleDown(event, button: 1) }
  override func rightMouseDragged(with event: NSEvent) { handleDrag(event, button: 1) }
  override func rightMouseUp(with event: NSEvent) { handleUp(event, button: 1) }
  override func otherMouseDown(with event: NSEvent) { handleDown(event, button: 2) }
  override func otherMouseDragged(with event: NSEvent) { handleDrag(event, button: 2) }
  override func otherMouseUp(with event: NSEvent) { handleUp(event, button: 2) }

  override func scrollWheel(with event: NSEvent) {
    guard visual == WSNConst.visualLive, let point = normalized(event) else { return }
    // phase: low byte = gesture phase, second byte = momentum phase,
    // bit 16 = precise (trackpad) deltas.
    var phase = Int32(truncatingIfNeeded: event.phase.rawValue & 0xFF)
    phase |= Int32(truncatingIfNeeded: event.momentumPhase.rawValue & 0xFF) << 8
    if event.hasPreciseScrollingDeltas {
      phase |= 1 << 16
    }
    // Trackpad deltas are sent as fractions of the video rect so the source
    // can move a finger by the same distance; wheel deltas stay in lines.
    var dx = Double(event.scrollingDeltaX)
    var dy = Double(event.scrollingDeltaY)
    if event.hasPreciseScrollingDeltas {
      let rect = videoRect
      dx = rect.width > 0 ? dx / Double(rect.width) : 0
      dy = rect.height > 0 ? dy / Double(rect.height) : 0
    }
    SurfaceRegistry.shared.emitInput(
      surface: surfaceId, kind: WSNConst.inputScroll, code: 0,
      modifiers: StreamVideoView.modifiers(event.modifierFlags), x: point.x, y: point.y,
      dx: dx, dy: dy, phase: phase)
  }

  // MARK: Keyboard

  /// The key being handled while the input method decides what it means.
  private var pendingKey: NSEvent?
  /// Whether the input method was composing when that key arrived.
  private var composingBefore = false
  /// Keys sent down as keys (not as text), so their release follows.
  private var keysDown = Set<UInt16>()
  /// Pinyin and the like being composed; not sent until committed.
  private var marked = NSMutableAttributedString()

  override func keyDown(with event: NSEvent) {
    guard visual == WSNConst.visualLive else { return }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == .command, event.keyCode == 9 {
      paste(nil)
      return
    }
    // Shortcuts go to the source as keys. Everything else goes through the
    // input method first, so pinyin, kana and dead keys compose here and
    // only the committed text is sent.
    if flags.contains(.command) || flags.contains(.control) {
      sendKeyDown(event)
      return
    }
    pendingKey = event
    composingBefore = hasMarkedText()
    let handled = inputContext?.handleEvent(event) ?? false
    pendingKey = nil
    if !handled {
      sendKeyDown(event)
    }
  }

  override func keyUp(with event: NSEvent) {
    guard visual == WSNConst.visualLive, keysDown.remove(event.keyCode) != nil else { return }
    SurfaceRegistry.shared.emitInput(
      surface: surfaceId, kind: WSNConst.inputKeyUp, code: Int32(event.keyCode),
      modifiers: StreamVideoView.modifiers(event.modifierFlags), text: event.characters)
  }

  private func sendKeyDown(_ event: NSEvent) {
    keysDown.insert(event.keyCode)
    SurfaceRegistry.shared.emitInput(
      surface: surfaceId, kind: WSNConst.inputKeyDown, code: Int32(event.keyCode),
      modifiers: StreamVideoView.modifiers(event.modifierFlags),
      phase: event.isARepeat ? 1 : 0, text: event.characters)
  }

  /// ⌘V from the Edit menu: send the Mac clipboard as text to paste.
  @objc func paste(_ sender: Any?) {
    guard visual == WSNConst.visualLive,
      let text = NSPasteboard.general.string(forType: .string), !text.isEmpty
    else { return }
    SurfaceRegistry.shared.emitInput(surface: surfaceId, kind: WSNConst.inputText, code: 1, text: text)
  }
}

// MARK: - Input methods

extension StreamVideoView: NSTextInputClient {
  func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    let wasComposing = composingBefore || hasMarkedText()
    marked = NSMutableAttributedString()
    guard !text.isEmpty else { return }
    // A plain keystroke stays a key (games and shortcuts keep working);
    // what an input method committed goes as text.
    if let key = pendingKey, !wasComposing, key.characters == text {
      sendKeyDown(key)
      return
    }
    SurfaceRegistry.shared.emitInput(surface: surfaceId, kind: WSNConst.inputText, code: 0, text: text)
  }

  /// Return, backspace, arrows… go to the source as the key that was pressed.
  override func doCommand(by selector: Selector) {
    if let key = pendingKey {
      sendKeyDown(key)
    }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    if let attributed = string as? NSAttributedString {
      marked = NSMutableAttributedString(attributedString: attributed)
    } else {
      marked = NSMutableAttributedString(string: string as? String ?? "")
    }
  }

  func unmarkText() {
    marked = NSMutableAttributedString()
  }

  func selectedRange() -> NSRange {
    NSRange(location: marked.length, length: 0)
  }

  func markedRange() -> NSRange {
    marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
  }

  func hasMarkedText() -> Bool { marked.length > 0 }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
    nil
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  /// Where the candidate window opens: low in the middle of the picture,
  /// where it does not cover what is being typed into most of the time.
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    let rect = videoRect
    let anchor = NSRect(x: rect.midX - 120, y: rect.minY + 56, width: 1, height: 22)
    guard let window = window else { return .zero }
    return window.convertToScreen(convert(anchor, to: nil))
  }

  func characterIndex(for point: NSPoint) -> Int { 0 }
}
