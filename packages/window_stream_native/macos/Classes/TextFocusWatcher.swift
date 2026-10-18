import AppKit
import ApplicationServices

/// Watches where a streamed app's keyboard focus is, and says whenever it
/// moves into or out of somewhere to type (a text field, a text view, an
/// editable spot on a web page), so a phone can bring its keyboard up or
/// put it away by itself. Main thread; needs Accessibility.
final class TextFocusWatcher {
  private let pid: pid_t
  private let app: AXUIElement
  private let onChange: (Bool) -> Void
  private var observer: AXObserver?
  private var last: Bool?
  private var stopped = false

  init(pid: pid_t, onChange: @escaping (Bool) -> Void) {
    self.pid = pid
    self.onChange = onChange
    app = AXUIElementCreateApplication(pid)
    DispatchQueue.main.async { [weak self] in self?.start() }
  }

  private func start() {
    guard !stopped, AXIsProcessTrusted() else { return }
    AXUIElementSetMessagingTimeout(app, 0.3)
    // Not switching on web content's tree in Chrome or Electron apps
    // (AXManualAccessibility): it slows their drawing, and typing with it.
    // Their native fields still count; web fields need the keyboard button.
    var created: AXObserver?
    let callback: AXObserverCallback = { _, _, _, refcon in
      guard let refcon = refcon else { return }
      Unmanaged<TextFocusWatcher>.fromOpaque(refcon).takeUnretainedValue().check()
    }
    guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else {
      return
    }
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for name in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
      AXObserverAddNotification(observer, app, name as CFString, refcon)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    self.observer = observer
    check()
  }

  /// Ends the watch. The block keeps the watcher alive until the observer,
  /// which only holds it unretained, is gone.
  func stop() {
    DispatchQueue.main.async { [self] in
      stopped = true
      guard let observer = observer else { return }
      for name in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
        AXObserverRemoveNotification(observer, app, name as CFString)
      }
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
      self.observer = nil
    }
  }

  private func check() {
    guard !stopped else { return }
    var value: CFTypeRef?
    var typing = false
    if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
      == .success, let value = value, CFGetTypeID(value) == AXUIElementGetTypeID()
    {
      typing = Self.isForTyping(value as! AXUIElement)
    }
    guard typing != last else { return }
    last = typing
    onChange(typing)
  }

  static func isForTyping(_ element: AXUIElement) -> Bool {
    AXUIElementSetMessagingTimeout(element, 0.3)
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    let typed: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    if let role = role as? String, typed.contains(role) {
      return true
    }
    // Web pages mark the places that take text.
    var editable: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success,
      (editable as? Bool) == true
    {
      return true
    }
    return false
  }
}
