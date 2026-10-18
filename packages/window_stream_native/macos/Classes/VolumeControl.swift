import AppKit

/// Words the native windows show (wsn_set_strings), English until Dart
/// sends the user's language. Any thread.
final class WindowStreamStrings {
  static let shared = WindowStreamStrings()

  private let lock = NSLock()
  private var words: [String: String] = [
    "volume": "Volume", "mute": "Mute", "unmute": "Unmute",
  ]

  /// UTF-8 JSON object of strings; missing keys keep their word.
  func update(json: String) {
    guard let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }
    lock.lock()
    for key in ["volume", "mute", "unmute"] {
      if let value = object[key] as? String, !value.isEmpty {
        words[key] = value
      }
    }
    lock.unlock()
  }

  func word(_ key: String) -> String {
    lock.lock()
    defer { lock.unlock() }
    return words[key] ?? key
  }
}

/// The window's own volume control: a speaker button at the trailing end
/// of the title bar that opens a popover with a slider and a mute toggle.
/// It lives in the title bar and its popover, never in the video view, so
/// no pointer or key meant for it reaches the streamed app. Main thread only.
final class WindowVolumeControl: NSObject, NSPopoverDelegate {
  /// The user moved the slider or toggled mute: applied to the sound at once.
  var onChange: ((Double) -> Void)?

  private let surfaceId: Int64
  private let accessory = NSTitlebarAccessoryViewController()
  private let button = NSButton()
  private let slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
  private let muteButton = NSButton()
  private var popover: NSPopover?
  private var shown = false

  private(set) var volume: Double
  /// What unmuting goes back to.
  private var audible: Double
  // Reports to Dart: at most every `emitInterval` while dragging, and the
  // last value once the drag ends.
  private var emitted: Double?
  private var lastEmit: CFTimeInterval = 0
  private var pendingEmit: DispatchWorkItem?
  private static let emitInterval: CFTimeInterval = 0.1

  init(surfaceId: Int64, volume: Double) {
    self.surfaceId = surfaceId
    self.volume = volume
    audible = volume > 0.001 ? volume : 1
    emitted = volume
    super.init()
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 34, height: 28))
    button.frame = NSRect(x: 4, y: 3, width: 26, height: 22)
    button.autoresizingMask = [.minYMargin, .maxYMargin]
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.refusesFirstResponder = true
    button.target = self
    button.action = #selector(togglePopover(_:))
    container.addSubview(button)
    accessory.view = container
    accessory.layoutAttribute = .trailing
    refresh()
  }

  /// The window has sound now: the control shows (side accessories cannot
  /// be hidden, so it is added only then).
  func show(in window: NSWindow) {
    guard !shown else { return }
    shown = true
    window.addTitlebarAccessoryViewController(accessory)
  }

  /// From Dart: shows `value` without reporting it back.
  func setVolume(_ value: Double) {
    volume = value
    if value > 0.001 {
      audible = value
    }
    pendingEmit?.cancel()
    pendingEmit = nil
    emitted = value
    refresh()
  }

  /// The words changed (wsn_set_strings).
  func refreshStrings() {
    refresh()
  }

  func close() {
    pendingEmit?.cancel()
    pendingEmit = nil
    popover?.close()
  }

  // MARK: Popover

  @objc private func togglePopover(_ sender: NSButton) {
    if let open = popover, open.isShown {
      open.performClose(nil)
      return
    }
    let popover = self.popover ?? makePopover()
    self.popover = popover
    slider.doubleValue = volume
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    // Keys go to the slider (arrows step it), never to the streamed app.
    slider.window?.makeFirstResponder(slider)
  }

  private func makePopover() -> NSPopover {
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 232, height: 40))
    muteButton.frame = NSRect(x: 10, y: 8, width: 26, height: 24)
    muteButton.isBordered = false
    muteButton.bezelStyle = .regularSquare
    muteButton.imagePosition = .imageOnly
    muteButton.imageScaling = .scaleProportionallyDown
    muteButton.target = self
    muteButton.action = #selector(toggleMute(_:))
    content.addSubview(muteButton)
    slider.frame = NSRect(x: 44, y: 10, width: 176, height: 20)
    slider.isContinuous = true
    slider.target = self
    slider.action = #selector(sliderMoved(_:))
    content.addSubview(slider)
    let controller = NSViewController()
    controller.view = content
    let popover = NSPopover()
    popover.contentViewController = controller
    popover.contentSize = content.frame.size
    popover.behavior = .transient
    popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    popover.delegate = self
    refresh()
    return popover
  }

  func popoverDidClose(_ notification: Notification) {
    flushEmit()
  }

  @objc private func sliderMoved(_ sender: NSSlider) {
    // Dragging (or scrolling) sends a stream of these; the one for the
    // mouse going up, or an arrow key, ends a change.
    let type = NSApp.currentEvent?.type
    let final = type == nil || type == .leftMouseUp || type == .keyDown
    userChanged(min(max(sender.doubleValue, 0), 1), final: final)
  }

  @objc private func toggleMute(_ sender: NSButton) {
    userChanged(volume > 0.001 ? 0 : audible, final: true)
  }

  // MARK: Changes

  private func userChanged(_ value: Double, final: Bool) {
    volume = value
    if value > 0.001 {
      audible = value
    }
    refresh()
    onChange?(value)
    let now = CACurrentMediaTime()
    if final || now - lastEmit >= WindowVolumeControl.emitInterval {
      flushEmit()
    } else if pendingEmit == nil {
      let work = DispatchWorkItem { [weak self] in
        self?.pendingEmit = nil
        self?.flushEmit()
      }
      pendingEmit = work
      DispatchQueue.main.asyncAfter(
        deadline: .now() + max(0, lastEmit + WindowVolumeControl.emitInterval - now),
        execute: work)
    }
  }

  private func flushEmit() {
    pendingEmit?.cancel()
    pendingEmit = nil
    guard emitted != volume else { return }
    emitted = volume
    lastEmit = CACurrentMediaTime()
    SurfaceRegistry.shared.emitWindow(
      surface: surfaceId, kind: WSNConst.windowVolume, a: volume)
  }

  private func refresh() {
    let strings = WindowStreamStrings.shared
    let muted = volume <= 0.001
    let title = strings.word("volume")
    button.image = WindowVolumeControl.speaker(muted: muted, label: title)
    button.toolTip = title
    button.setAccessibilityLabel(title)
    let toggle = strings.word(muted ? "unmute" : "mute")
    muteButton.image = WindowVolumeControl.speaker(muted: muted, label: toggle)
    muteButton.toolTip = toggle
    muteButton.setAccessibilityLabel(toggle)
    slider.setAccessibilityLabel(title)
    if slider.doubleValue != volume {
      slider.doubleValue = volume
    }
  }

  private static func speaker(muted: Bool, label: String) -> NSImage? {
    if #available(macOS 11, *) {
      let image = NSImage(
        systemSymbolName: muted ? "speaker.slash" : "speaker.wave.2",
        accessibilityDescription: label)
      return image?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }
    return NSImage(
      named: muted
        ? NSImage.touchBarAudioOutputMuteTemplateName
        : NSImage.touchBarAudioOutputVolumeHighTemplateName)
  }
}
