import Cocoa
import Carbon
import FlutterMacOS
import ScreenCaptureKit

final class ScreenshotPlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private var hotKey: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  private var hotKeyID: UInt32 = 0
  private var shortcut: NSDictionary?
  private var captureSession: ScreenshotSession?
  private static let signature: OSType = 0x57534350

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.vireen.whisper/screenshot", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(ScreenshotPlugin(channel: channel), channel: channel)
  }

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                              eventKind: UInt32(kEventHotKeyReleased))
    // Flutter owns NSApplication's event loop. Receive Carbon events at the
    // dispatcher, as the existing quick-send shortcut does, before that loop.
    InstallEventHandler(GetEventDispatcherTarget(), { _, event, data in
      guard let event = event, let data = data else { return OSStatus(eventNotHandledErr) }
      let plugin = Unmanaged<ScreenshotPlugin>.fromOpaque(data).takeUnretainedValue()
      var id = EventHotKeyID()
      let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
      guard status == noErr, id.signature == ScreenshotPlugin.signature,
            id.id == plugin.hotKeyID else { return OSStatus(eventNotHandledErr) }
      plugin.channel.invokeMethod("shortcutPressed", arguments: nil)
      return noErr
    }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
  }

  deinit {
    if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
    if let eventHandler = eventHandler { RemoveEventHandler(eventHandler) }
    captureSession?.cancel()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setShortcut": setShortcut(call.arguments as? [String: Any], result: result)
    case "captureRegion": captureRegion(call.arguments as? [String: String] ?? [:], result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func setShortcut(_ arguments: [String: Any]?, result: @escaping FlutterResult) {
    guard let arguments = arguments else {
      if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
      hotKey = nil
      shortcut = nil
      result(nil)
      return
    }
    if shortcut?.isEqual(to: arguments) == true { result(nil); return }
    guard let key = arguments["key"] as? String, let keyCode = keyCode(for: key),
          eventHandler != nil else {
      result(FlutterError(code: "shortcut-invalid", message: nil, details: nil))
      return
    }
    var modifiers: UInt32 = 0
    if arguments["control"] as? Bool == true { modifiers |= UInt32(controlKey) }
    if arguments["alt"] as? Bool == true { modifiers |= UInt32(optionKey) }
    if arguments["shift"] as? Bool == true { modifiers |= UInt32(shiftKey) }
    if arguments["meta"] as? Bool == true { modifiers |= UInt32(cmdKey) }
    guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
      result(FlutterError(code: "shortcut-invalid", message: nil, details: nil)); return
    }
    var replacement: EventHotKeyRef?
    let id = EventHotKeyID(signature: Self.signature, id: hotKeyID &+ 1)
    let status = RegisterEventHotKey(keyCode, modifiers, id,
                                    GetEventDispatcherTarget(), 0, &replacement)
    guard status == noErr else {
      result(FlutterError(code: "shortcut-unavailable", message: nil, details: nil)); return
    }
    if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
    hotKey = replacement
    hotKeyID = id.id
    shortcut = arguments as NSDictionary
    result(nil)
  }

  private func keyCode(for key: String) -> UInt32? {
    let functionKeys: [String: UInt32] = [
      "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97,
      "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111]
    if let code = functionKeys[key] { return code }
    guard key.range(of: "^[A-Z0-9]$", options: .regularExpression) != nil,
          let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
      return nil
    }
    let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
    let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
    for code: UInt16 in 0..<128 {
      var deadKey: UInt32 = 0
      var length = 0
      var chars = [UniChar](repeating: 0, count: 8)
      let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0,
          UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
          &deadKey, chars.count, &length, &chars)
      if status == noErr && String(utf16CodeUnits: chars, count: length).uppercased() == key {
        return UInt32(code)
      }
    }
    return nil
  }

  private func captureRegion(_ labels: [String: String], result: @escaping FlutterResult) {
    guard captureSession == nil else {
      result(FlutterError(code: "capture-busy", message: nil, details: nil)); return
    }
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
      result(FlutterError(code: "permission-denied", message: nil, details: nil)); return
    }
    let session = ScreenshotSession(labels: labels) { [weak self] value in
      self?.captureSession = nil
      result(value)
    }
    captureSession = session
    session.start()
  }
}

private struct ScreenshotDisplay {
  let screen: NSScreen
  let image: CGImage
  var frame: CGRect { screen.frame }
  var scale: CGFloat { CGFloat(image.width) / frame.width }
}

private final class ScreenshotPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private final class ScreenshotSession {
  let labels: [String: String]
  private var completion: FlutterResult?
  private var displays: [ScreenshotDisplay] = []
  private var panels: [ScreenshotPanel] = []
  private var timeout: DispatchWorkItem?
  private var screenObserver: NSObjectProtocol?
  private var desktop = CGRect.zero
  private var anchor = CGPoint.zero
  private var original = CGRect.zero
  private var operation = 0
  private var actionScreen = CGRect.zero
  private weak var previousKeyWindow: NSWindow?
  private(set) var selection = CGRect.zero
  private(set) var selected = false
  private(set) var pointer = CGPoint.zero
  var dragging: Bool { operation != 0 }
  private let move = 16, create = 32

  init(labels: [String: String], completion: @escaping FlutterResult) {
    self.labels = labels
    self.completion = completion
  }

  func start() {
    let screens = NSScreen.screens
    guard !screens.isEmpty,
          screens.reduce(CGFloat(0), { $0 + $1.frame.width * $1.frame.height *
            $1.backingScaleFactor * $1.backingScaleFactor }) <= 128 * 1024 * 1024 else {
      fail(); return
    }
    previousKeyWindow = NSApp.keyWindow
    desktop = screens.dropFirst().reduce(screens[0].frame) { $0.union($1.frame) }
    pointer = NSEvent.mouseLocation
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.cancel() }
    let deadline = DispatchWorkItem { [weak self] in self?.fail() }
    timeout = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: deadline)
    if #available(macOS 14.0, *) {
      SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) {
        [weak self] content, _ in
        DispatchQueue.main.async {
          guard let self = self, self.completion != nil else { return }
          guard let content = content else { self.fail(); return }
          self.capture(screens: screens, content: content, index: 0)
        }
      }
    } else {
      captureLegacy(screens)
    }
  }

  @available(macOS 14.0, *)
  private func capture(screens: [NSScreen], content: SCShareableContent, index: Int) {
    guard completion != nil else { return }
    if index == screens.count { showOverlays(); return }
    let screen = screens[index]
    let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    guard let display = content.displays.first(where: { $0.displayID == id }) else {
      fail(); return
    }
    let config = SCStreamConfiguration()
    config.width = Int(screen.frame.width * screen.backingScaleFactor)
    config.height = Int(screen.frame.height * screen.backingScaleFactor)
    config.showsCursor = false
    let filter = SCContentFilter(display: display, excludingWindows: [])
    SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
      [weak self] image, _ in
      DispatchQueue.main.async {
        guard let self = self, self.completion != nil else { return }
        guard let image = image else { self.fail(); return }
        self.displays.append(ScreenshotDisplay(screen: screen, image: image))
        self.capture(screens: screens, content: content, index: index + 1)
      }
    }
  }

  private func captureLegacy(_ screens: [NSScreen]) {
    // Older systems lack SCScreenshotManager. Only this fallback uses private
    // temporary files; neither path changes the user's clipboard before confirm.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("whisper-capture-\(UUID().uuidString)", isDirectory: true)
      var images: [CGImage] = []
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = screens.indices.map { directory.appendingPathComponent("\($0).png") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-t", "png"] + files.map(\.path)
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
          images = files.compactMap {
            guard let source = CGImageSourceCreateWithURL($0 as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
          }
        }
      } catch { /* Report a single capture error on the main thread. */ }
      DispatchQueue.main.async {
        guard let self = self, self.completion != nil else { return }
        guard images.count == screens.count else { self.fail(); return }
        self.displays = zip(screens, images).map { ScreenshotDisplay(screen: $0, image: $1) }
        self.showOverlays()
      }
    }
  }

  private func showOverlays() {
    timeout?.cancel()
    timeout = nil
    for display in displays {
      let panel = ScreenshotPanel(contentRect: display.frame,
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      // The panel contains a desktop snapshot; window transitions would scale
      // the whole desktop image when entering or leaving region selection.
      panel.animationBehavior = .none
      panel.level = .screenSaver
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel.isOpaque = true
      panel.hasShadow = false
      panel.hidesOnDeactivate = false
      panel.isReleasedWhenClosed = false
      panel.acceptsMouseMovedEvents = true
      let view = ScreenshotCanvas(frame: CGRect(origin: .zero, size: display.frame.size),
        display: display, session: self)
      panel.contentView = view
      panels.append(panel)
      panel.orderFrontRegardless()
    }
    let active = displays.firstIndex { $0.frame.contains(pointer) } ?? 0
    panels[active].makeKey()
    panels[active].makeFirstResponder(panels[active].contentView)
    NSCursor.crosshair.set()
  }

  func hitTest(_ point: CGPoint) -> Int {
    guard selected, selection.insetBy(dx: -9, dy: -9).contains(point) else { return 0 }
    var hit = 0
    if abs(point.x - selection.minX) <= 9 { hit |= 1 }
    else if abs(point.x - selection.maxX) <= 9 { hit |= 2 }
    if abs(point.y - selection.minY) <= 9 { hit |= 4 }
    else if abs(point.y - selection.maxY) <= 9 { hit |= 8 }
    return hit == 0 ? move : hit
  }

  func begin(_ point: CGPoint) {
    guard completion != nil else { return }
    pointer = point
    if selected && !dragging {
      let toolbar = actionRect
      if toolbar.contains(point) {
        if point.x < toolbar.midX { cancel() } else { confirm() }
        return
      }
    }
    anchor = clamp(point)
    original = selection
    operation = hitTest(point)
    if operation == 0 {
      operation = create
      selected = false
      selection = CGRect(origin: anchor, size: .zero)
    }
    redraw()
  }

  func update(_ point: CGPoint) {
    guard completion != nil else { return }
    pointer = point
    guard dragging else { updateCursor(); redraw(); return }
    let point = clamp(point)
    if operation == create {
      selection = rect(anchor, point)
    } else if operation == move {
      let dx = max(desktop.minX - original.minX,
        min(point.x - anchor.x, desktop.maxX - original.maxX))
      let dy = max(desktop.minY - original.minY,
        min(point.y - anchor.y, desktop.maxY - original.maxY))
      selection = original.offsetBy(dx: dx, dy: dy)
    } else {
      let first = CGPoint(x: operation & 1 != 0 ? point.x : original.minX,
                          y: operation & 4 != 0 ? point.y : original.minY)
      let last = CGPoint(x: operation & 2 != 0 ? point.x : original.maxX,
                         y: operation & 8 != 0 ? point.y : original.maxY)
      selection = rect(first, last)
    }
    redraw()
  }

  func end(_ point: CGPoint) {
    guard completion != nil, dragging else { return }
    update(point)
    operation = 0
    selected = selection.width >= 2 && selection.height >= 2
    if !selected { selection = .zero }
    actionScreen = displays.first(where: { $0.frame.contains(point) })?.frame ?? displays[0].frame
    updateCursor()
    redraw()
  }

  private func updateCursor() {
    if selected && actionRect.contains(pointer) { NSCursor.pointingHand.set(); return }
    switch hitTest(pointer) {
    case move: NSCursor.openHand.set()
    case 1, 2: NSCursor.resizeLeftRight.set()
    case 4, 8: NSCursor.resizeUpDown.set()
    default: NSCursor.crosshair.set()
    }
  }

  var actionRect: CGRect {
    let x = max(actionScreen.minX + 12, min(selection.maxX - 84, actionScreen.maxX - 96))
    var y = selection.minY - 50
    if y < actionScreen.minY + 12 { y = selection.maxY + 12 }
    y = max(actionScreen.minY + 12, min(y, actionScreen.maxY - 50))
    return CGRect(x: x, y: y, width: 84, height: 38)
  }

  private func clamp(_ point: CGPoint) -> CGPoint {
    CGPoint(x: max(desktop.minX, min(point.x, desktop.maxX)),
            y: max(desktop.minY, min(point.y, desktop.maxY)))
  }
  private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
  }
  private func redraw() {
    panels.forEach {
      ($0.contentView as? ScreenshotCanvas)?.updateActionHints()
      $0.contentView?.needsDisplay = true
    }
  }

  func confirm() {
    guard selected, !dragging else { return }
    let intersections = displays.filter { $0.frame.intersects(selection) }
    guard let scale = intersections.map(\.scale).max() else { return }
    let width = Int(ceil(selection.width * scale)), height = Int(ceil(selection.height * scale))
    guard width > 0, height > 0, Int64(width) * Int64(height) <= 128 * 1024 * 1024,
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail(); return }
    for display in intersections {
      let area = display.frame.intersection(selection)
      let crop = CGRect(x: (area.minX - display.frame.minX) * display.scale,
        y: (display.frame.maxY - area.maxY) * display.scale,
        width: area.width * display.scale, height: area.height * display.scale).integral
      guard let image = display.image.cropping(to: crop) else { fail(); return }
      context.draw(image, in: CGRect(x: (area.minX - selection.minX) * scale,
        y: (area.minY - selection.minY) * scale, width: area.width * scale, height: area.height * scale))
    }
    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
      fail(); return
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if pasteboard.setData(data, forType: .png) { finish(true) }
    else { finish(FlutterError(code: "clipboard-failed", message: nil, details: nil)) }
  }

  func cancel() { finish(false) }
  private func fail() { finish(FlutterError(code: "capture-failed", message: nil, details: nil)) }
  private func finish(_ value: Any) {
    guard let completion = completion else { return }
    self.completion = nil
    timeout?.cancel()
    if let observer = screenObserver { NotificationCenter.default.removeObserver(observer) }
    screenObserver = nil
    let restoreKey = panels.contains { $0.isKeyWindow }
    panels.forEach { $0.close() }
    panels.removeAll()
    displays.removeAll()
    if restoreKey { previousKeyWindow?.makeKey() }
    NSCursor.arrow.set()
    completion(value)
  }
}

private final class ScreenshotCanvas: NSView, NSViewToolTipOwner {
  private let display: ScreenshotDisplay
  // A mouse-up may arrive after its mouse-down closed the panel. Keep the
  // completed session alive until that view/event is released.
  private let session: ScreenshotSession
  private var tracking: NSTrackingArea?
  private var toolTipRect = CGRect.null
  private let accent = NSColor(srgbRed: 0.145, green: 0.388, blue: 0.922, alpha: 1)
  private var dark: Bool { session.labels["appearance"] == "dark" }
  private var textColor: NSColor {
    dark ? NSColor(calibratedWhite: 0.90, alpha: 1) : NSColor(srgbRed: 0.39, green: 0.45, blue: 0.54, alpha: 1)
  }
  private var surfaceColor: NSColor {
    dark ? NSColor(calibratedWhite: 0.12, alpha: 0.96) : NSColor(calibratedWhite: 1, alpha: 0.94)
  }
  override var acceptsFirstResponder: Bool { true }

  init(frame: CGRect, display: ScreenshotDisplay, session: ScreenshotSession) {
    self.display = display
    self.session = session
    super.init(frame: frame)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking = tracking { removeTrackingArea(tracking) }
    tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                              owner: self, userInfo: nil)
    addTrackingArea(tracking!)
  }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { session.begin(NSEvent.mouseLocation) }
  override func mouseDragged(with event: NSEvent) { session.update(NSEvent.mouseLocation) }
  override func mouseUp(with event: NSEvent) { session.end(NSEvent.mouseLocation) }
  override func mouseMoved(with event: NSEvent) { session.update(NSEvent.mouseLocation) }
  override func rightMouseDown(with event: NSEvent) { session.cancel() }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { session.cancel() }
    else if event.keyCode == 36 || event.keyCode == 76 { session.confirm() }
  }
  private func local(_ rect: CGRect) -> CGRect {
    rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
  }

  func updateActionHints() {
    let rect = session.selected && !session.dragging ? local(session.actionRect) : .null
    guard rect != toolTipRect else { return }
    toolTipRect = rect
    removeAllToolTips()
    guard !rect.isNull, bounds.intersects(rect) else { return }
    addToolTip(CGRect(x: rect.minX, y: rect.minY, width: 42, height: rect.height), owner: self, userData: nil)
    addToolTip(CGRect(x: rect.midX, y: rect.minY, width: 42, height: rect.height), owner: self, userData: nil)
  }

  func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
            userData data: UnsafeMutableRawPointer?) -> String {
    session.labels[point.x < toolTipRect.midX ? "cancel" : "confirm"] ?? ""
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.draw(display.image, in: bounds)
    NSColor.black.withAlphaComponent(0.36).setFill()
    bounds.fill()
    let rect = local(session.selection)
    if rect.width > 0 && rect.height > 0 {
      context.saveGState()
      context.clip(to: rect)
      context.draw(display.image, in: bounds)
      context.restoreGState()
      let edge = NSBezierPath(rect: rect)
      accent.setStroke()
      edge.lineWidth = 2
      edge.stroke()
      for x in [rect.minX, rect.midX, rect.maxX] {
        for y in [rect.minY, rect.midY, rect.maxY] where x != rect.midX || y != rect.midY {
          let handle = NSBezierPath(ovalIn: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7))
          NSColor.white.setFill(); handle.fill()
          accent.setStroke(); handle.lineWidth = 1.5; handle.stroke()
        }
      }
    }
    let hint = session.labels[session.selected ? "adjustHint" : "hint"] ?? ""
    let hintWidth = min(bounds.width - 32, max(280, CGFloat(hint.count) * 13))
    let hintRect = CGRect(x: (bounds.width - hintWidth) / 2, y: bounds.height - 64,
                          width: hintWidth, height: 34)
    surfaceColor.setFill()
    NSBezierPath(roundedRect: hintRect, xRadius: 9, yRadius: 9).fill()
    drawText(hint, in: hintRect, size: 13)
    if session.selected && !session.dragging && display.frame.intersects(session.actionRect) {
      let toolbar = local(session.actionRect)
      surfaceColor.setFill()
      let outline = NSBezierPath(roundedRect: toolbar, xRadius: 12, yRadius: 12)
      outline.fill()
      textColor.withAlphaComponent(0.20).setStroke()
      outline.lineWidth = 0.75; outline.stroke()
      let cancel = CGRect(x: toolbar.minX + 4, y: toolbar.minY + 4, width: 36, height: 30)
      let confirm = CGRect(x: toolbar.minX + 44, y: toolbar.minY + 4, width: 36, height: 30)
      let pointer = CGPoint(x: session.pointer.x - display.frame.minX, y: session.pointer.y - display.frame.minY)
      if cancel.contains(pointer) {
        textColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: cancel, xRadius: 7, yRadius: 7).fill()
      }
      if confirm.contains(pointer) {
        accent.withAlphaComponent(dark ? 0.20 : 0.10).setFill()
        NSBezierPath(roundedRect: confirm, xRadius: 7, yRadius: 7).fill()
      }
      textColor.setStroke()
      let cross = NSBezierPath()
      cross.move(to: CGPoint(x: cancel.midX - 4, y: cancel.midY - 4))
      cross.line(to: CGPoint(x: cancel.midX + 4, y: cancel.midY + 4))
      cross.move(to: CGPoint(x: cancel.midX - 4, y: cancel.midY + 4))
      cross.line(to: CGPoint(x: cancel.midX + 4, y: cancel.midY - 4))
      cross.lineWidth = 1.6; cross.lineCapStyle = .round; cross.stroke()
      accent.setStroke()
      let back = NSBezierPath()
      back.move(to: CGPoint(x: confirm.midX - 3, y: confirm.midY + 7))
      back.line(to: CGPoint(x: confirm.midX + 5, y: confirm.midY + 7))
      back.line(to: CGPoint(x: confirm.midX + 5, y: confirm.midY - 3))
      back.lineWidth = 1.6; back.lineJoinStyle = .round; back.stroke()
      let front = NSBezierPath(roundedRect: CGRect(x: confirm.midX - 6, y: confirm.midY - 7, width: 9, height: 11),
                               xRadius: 1.5, yRadius: 1.5)
      front.lineWidth = 1.6; front.stroke()
    }
  }

  private func drawText(_ text: String, in rect: CGRect, size: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byTruncatingTail
    let font = NSFont.systemFont(ofSize: size, weight: .medium)
    (text as NSString).draw(in: CGRect(x: rect.minX + 6, y: rect.midY - (font.ascender - font.descender) / 2,
      width: rect.width - 12, height: font.ascender - font.descender + 2), withAttributes: [
        .font: font, .foregroundColor: textColor, .paragraphStyle: style])
  }
}
