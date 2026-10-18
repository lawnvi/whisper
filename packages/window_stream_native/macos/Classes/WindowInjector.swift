import AppKit
import ApplicationServices

/// Replays a remote viewer's input on one local window. Coordinates arrive as
/// fractions of the window; the window's current frame is looked up (and
/// cached briefly) so moving the window does not break input.
///
/// Before the first click on an app that is not frontmost, the app is
/// activated and its window raised; events that arrive during that short
/// hand-over are delayed, never reordered or dropped.
final class WindowInjector {
  private let windowId: CGWindowID
  private let pid: pid_t
  private let queue: DispatchQueue
  private let source = CGEventSource(stateID: .hidSystemState)
  private var cachedBounds: CGRect?
  private var cachedAt = 0.0
  private var readyAt = 0.0
  private var buttonDown: CGMouseButton?
  /// The picture is this whole display (a staged window), not the window.
  private var captureDisplay: CGDirectDisplayID?
  /// Where the Mac's own pointer was before the viewer's touches took it
  /// over there; it goes back once the finger lifts.
  private var cursorHome: CGPoint?
  private var touchSerial = 0

  /// The viewer touched: its picture leaves the pointer out for a moment.
  var onTouch: (() -> Void)?

  /// A key or text arrived (and how long it waited for the app to come
  /// forward): the capture times how soon the picture shows it.
  var onTyped: ((Double) -> Void)?

  func setCaptureDisplay(_ display: CGDirectDisplayID?) {
    queue.async { [weak self] in
      self?.captureDisplay = display
      self?.cachedBounds = nil
    }
  }

  /// Time given to an app to come to the front before the click lands.
  private let activationDelay = 0.18

  init(windowId: CGWindowID, pid: pid_t) {
    self.windowId = windowId
    self.pid = pid
    queue = DispatchQueue(label: "whisper.window_stream.inject.\(windowId)", qos: .userInteractive)
  }

  static var hasPermission: Bool { AXIsProcessTrusted() }

  func handle(
    kind: Int32, code: Int32, modifiers: Int32, x: Double, y: Double, dx: Double, dy: Double,
    phase: Int32, text: String?
  ) {
    queue.async { [weak self] in
      guard let self = self else { return }
      var now = CACurrentMediaTime()
      if kind == WSNConst.inputPointerDown || kind == WSNConst.inputText || kind == WSNConst.inputKeyDown {
        if self.bringToFront() {
          // Wait only as long as the app takes to come forward (often a
          // few tens of ms), up to the old fixed delay.
          let deadline = now + self.activationDelay
          while CACurrentMediaTime() < deadline, !self.isFrontmost() {
            usleep(8_000)
          }
          now = CACurrentMediaTime()
          // A moment for its window to take the keys.
          self.readyAt = max(self.readyAt, now + 0.02)
        }
      }
      let delay = max(0, self.readyAt - now)
      if kind == WSNConst.inputText || kind == WSNConst.inputKeyDown {
        self.onTyped?(delay)
      }
      let work: () -> Void = { [weak self] in
        self?.inject(
          kind: kind, code: code, modifiers: modifiers, x: x, y: y, dx: dx, dy: dy, phase: phase,
          text: text)
      }
      if delay > 0 {
        self.queue.asyncAfter(deadline: .now() + delay, execute: work)
      } else {
        work()
      }
    }
  }

  // MARK: Window lookup

  /// What the viewer's fractions are of: the display when the window is
  /// staged on one, else the window.
  private func bounds() -> CGRect? {
    if let display = captureDisplay {
      let rect = CGDisplayBounds(display)
      if rect.width > 0 {
        return rect
      }
    }
    let now = CACurrentMediaTime()
    if let cached = cachedBounds, now - cachedAt < 0.1 {
      return cached
    }
    guard
      let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowId) as? [[String: Any]],
      let entry = info.first,
      let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
      let rect = CGRect(dictionaryRepresentation: dictionary)
    else { return nil }
    cachedBounds = rect
    cachedAt = now
    return rect
  }

  private func point(_ x: Double, _ y: Double) -> CGPoint? {
    guard let rect = bounds() else { return nil }
    return CGPoint(
      x: rect.minX + CGFloat(min(max(x, 0), 1)) * rect.width,
      y: rect.minY + CGFloat(min(max(y, 0), 1)) * rect.height)
  }

  /// Activates the owning app and raises this window. Returns true when
  /// anything had to change (so the caller waits a moment).
  private func isFrontmost() -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
  }

  private func bringToFront() -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
    var changed = false
    if !app.isActive {
      if #available(macOS 14.0, *) {
        app.activate()
      } else {
        app.activate(options: [.activateIgnoringOtherApps])
      }
      changed = true
    }
    if raiseWindow() {
      changed = true
    }
    return changed
  }

  /// Un-minimizes and raises the window of [pid] with [frame], activating
  /// its app, so macOS draws it again. Main thread. True when it acted.
  static func reveal(pid: pid_t, frame: CGRect) -> Bool {
    guard hasPermission else { return false }
    let appElement = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
      let windows = value as? [AXUIElement]
    else { return false }
    for window in windows {
      var positionValue: CFTypeRef?
      var sizeValue: CFTypeRef?
      AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
      AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
      var position = CGPoint.zero
      var size = CGSize.zero
      if let positionValue = positionValue {
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
      }
      if let sizeValue = sizeValue {
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
      }
      guard abs(position.x - frame.minX) < 2, abs(position.y - frame.minY) < 2,
        abs(size.width - frame.width) < 2, abs(size.height - frame.height) < 2
      else { continue }
      AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
      AXUIElementPerformAction(window, kAXRaiseAction as CFString)
      if let app = NSRunningApplication(processIdentifier: pid), !app.isActive {
        if #available(macOS 14.0, *) {
          app.activate()
        } else {
          app.activate(options: [.activateIgnoringOtherApps])
        }
      }
      return true
    }
    return false
  }

  /// Raises the AX window whose frame matches ours (best effort).
  private func raiseWindow() -> Bool {
    guard WindowInjector.hasPermission, let rect = bounds() else { return false }
    let appElement = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
      let windows = value as? [AXUIElement]
    else { return false }
    for (index, window) in windows.enumerated() {
      var positionValue: CFTypeRef?
      var sizeValue: CFTypeRef?
      AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
      AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
      var position = CGPoint.zero
      var size = CGSize.zero
      if let positionValue = positionValue {
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
      }
      if let sizeValue = sizeValue {
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
      }
      if abs(position.x - rect.minX) < 2, abs(position.y - rect.minY) < 2,
        abs(size.width - rect.width) < 2, abs(size.height - rect.height) < 2
      {
        // Already the frontmost window of its app.
        if index == 0 {
          return false
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return true
      }
    }
    return false
  }

  // MARK: Injection

  private func flags(_ modifiers: Int32) -> CGEventFlags {
    var flags: CGEventFlags = []
    if modifiers & WSNConst.modShift != 0 { flags.insert(.maskShift) }
    if modifiers & WSNConst.modControl != 0 { flags.insert(.maskControl) }
    if modifiers & WSNConst.modOption != 0 { flags.insert(.maskAlternate) }
    if modifiers & WSNConst.modCommand != 0 { flags.insert(.maskCommand) }
    return flags
  }

  private func inject(
    kind: Int32, code: Int32, modifiers: Int32, x: Double, y: Double, dx: Double, dy: Double,
    phase: Int32, text: String?
  ) {
    switch kind {
    case WSNConst.inputPointerDown, WSNConst.inputPointerMove, WSNConst.inputPointerUp,
      WSNConst.inputPointerCancel:
      pointer(kind: kind, button: code == 1 ? .right : .left, x: x, y: y, modifiers: modifiers)
    case WSNConst.inputScroll:
      scroll(x: x, y: y, dx: dx, dy: dy, precise: phase & (1 << 16) != 0)
    case WSNConst.inputKeyDown, WSNConst.inputKeyUp:
      guard let event = CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: kind == WSNConst.inputKeyDown)
      else { return }
      event.flags = flags(modifiers)
      event.post(tap: .cghidEventTap)
    case WSNConst.inputText:
      if let text = text {
        typeText(text)
      }
    default:
      break
    }
  }

  /// The last button press, to count double and triple clicks.
  private var lastClick: (time: TimeInterval, location: CGPoint, button: CGMouseButton)?
  private var clickCount = 1

  private func pointer(kind: Int32, button: CGMouseButton, x: Double, y: Double, modifiers: Int32) {
    guard let location = point(x, y) else { return }
    let type: CGEventType
    switch kind {
    case WSNConst.inputPointerDown:
      buttonDown = button
      type = button == .right ? .rightMouseDown : .leftMouseDown
      touchSerial += 1
      // Two taps in quick succession at about the same spot are a double
      // click (three a triple), as the Mac would count real clicks.
      let now = ProcessInfo.processInfo.systemUptime
      if let last = lastClick, last.button == button,
        now - last.time <= NSEvent.doubleClickInterval,
        hypot(location.x - last.location.x, location.y - last.location.y) <= 6
      {
        clickCount = min(clickCount + 1, 3)
      } else {
        clickCount = 1
      }
      lastClick = (time: now, location: location, button: button)
      if captureDisplay != nil, cursorHome == nil, let here = CGEvent(source: nil)?.location,
        let rect = bounds(), !rect.contains(here)
      {
        cursorHome = here
      }
      onTouch?()
    case WSNConst.inputPointerMove:
      if let pressed = buttonDown {
        type = pressed == .right ? .rightMouseDragged : .leftMouseDragged
      } else {
        type = .mouseMoved
      }
    default:
      let pressed = buttonDown ?? button
      buttonDown = nil
      type = pressed == .right ? .rightMouseUp : .leftMouseUp
    }
    guard let event = CGEvent(
      mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
      mouseButton: buttonDown ?? button)
    else { return }
    event.flags = flags(modifiers)
    if type == .leftMouseDown || type == .leftMouseUp || type == .rightMouseDown || type == .rightMouseUp {
      event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
    }
    event.post(tap: .cghidEventTap)
    if (type == .leftMouseUp || type == .rightMouseUp), let home = cursorHome {
      // A touch is not the Mac's mouse: give the pointer back to whoever
      // uses the Mac, unless another touch follows right away.
      let serial = touchSerial
      queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
        guard let self = self, self.touchSerial == serial, self.buttonDown == nil else { return }
        self.cursorHome = nil
        CGWarpMouseCursorPosition(home)
      }
    }
  }

  private func scroll(x: Double, y: Double, dx: Double, dy: Double, precise: Bool) {
    guard let location = point(x, y), let rect = bounds() else { return }
    let pixelsY = precise ? dy * Double(rect.height) : dy * 40
    let pixelsX = precise ? dx * Double(rect.width) : dx * 40
    guard let event = CGEvent(
      scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
      wheel1: Int32(pixelsY.rounded()), wheel2: Int32(pixelsX.rounded()), wheel3: 0)
    else { return }
    event.location = location
    event.post(tap: .cghidEventTap)
  }

  private func typeText(_ text: String) {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    var units: [UniChar] = []
    func flush() {
      guard !units.isEmpty,
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
      else { return }
      for event in [down, up] {
        event.flags = []
        units.withUnsafeBufferPointer { buffer in
          event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
        }
        event.post(tap: .cghidEventTap)
      }
      units.removeAll(keepingCapacity: true)
    }
    for scalar in normalized.unicodeScalars {
      if scalar.value == 10 {
        flush()
        for down in [true, false] {
          CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap)
        }
      } else {
        let next = Array(String(scalar).utf16)
        if units.count + next.count > 20 {
          flush()
        }
        units.append(contentsOf: next)
      }
    }
    flush()
  }
}
