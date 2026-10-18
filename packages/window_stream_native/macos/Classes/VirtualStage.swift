// Based on Sill's VirtualStage.swift and WindowSizer.swift
// (https://github.com/Saffsanity/sill, Copyright the Sill authors, Apache
// License 2.0): the staging sequence, window matching, settle loop and the way
// home follow theirs. Changes: one display per streamed window, a private
// CGWindowID → AX lookup tried before matching by title and frame, a window in
// a full-screen Space falls back instead of being captured whole.
import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Puts a streamed window on a virtual display of its own, the way sill does:
/// the window leaves the Mac's screen (the viewer has it now), is never
/// covered, so it keeps repainting, and takes the size the viewer's screen
/// wants. When the stream ends it goes back exactly where it was.
///
/// The display has the viewer's shape and is placed to the right of the
/// Mac's own screens: it is the phone's screen as an extra display, so the
/// Mac's mouse goes over by leaving the right edge and comes back the same
/// way. Only the window's app is captured from it (WindowCapture), never
/// the display as a whole.
///
/// Any failure undoes what was done and throws: the caller then streams the
/// real window where it is, as before.
@available(macOS 12.3, *)
@MainActor
final class VirtualStage {
  /// The display the window is on now. The capture builds its own filter
  /// from it, limited to the window's app (WindowCapture.CaptureTarget):
  /// a filter of the whole display would also show whatever else lands
  /// there.
  struct Prepared {
    let display: SCDisplay
    /// The window's rectangle in the display's own points.
    let sourceRect: CGRect
    /// The shareable content fetched while waiting for the display, if any.
    let content: SCShareableContent?
    /// Where the time went, for the log.
    let timings: String
  }

  enum Failure: Error {
    case disabled
    case accessibilityOff
    case screenRecordingOff
    case axWindowNotFound
    case fullScreen
    case displayCreate
    case neverOnline
    case notListedBySCK
    case moveRefused
    case notOnDisplay
    case windowMissing
  }

  struct Placement {
    let windowID: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    /// Where the window was before it was staged (global points).
    let originalFrame: CGRect
    /// It was in a full-screen Space and goes back to one.
    var wasFullScreen = false
  }

  // MARK: One display per viewer

  /// Each viewer (a phone) is one extra screen, as in sill: the windows it
  /// opens take turns on that one display instead of each adding another.
  private static var byScreen: [Int64: VirtualStage] = [:]
  private var users = 0

  /// The capture whose window is on the display now; another taking the
  /// display asks it to step aside.
  weak var owner: AnyObject?
  var onYield: (() -> Void)?

  static func forScreen(_ key: Int64) -> VirtualStage {
    let stage = byScreen[key] ?? VirtualStage()
    byScreen[key] = stage
    stage.users += 1
    stage.screenKey = key
    return stage
  }

  private var screenKey: Int64?

  /// A capture is done with this display; the last one removes it.
  func leave(_ capture: AnyObject) {
    if owner === capture {
      releaseWindow()
      owner = nil
      onYield = nil
    }
    users -= 1
    if users <= 0 {
      release()
      if let key = screenKey {
        Self.byScreen[key] = nil
      }
    }
  }

  /// [capture] puts its window on the display: the one there steps aside.
  func take(for capture: AnyObject, onYield: @escaping () -> Void) {
    if let current = owner, current !== capture {
      let yield = self.onYield
      releaseWindow()
      yield?()
    }
    owner = capture
    self.onYield = onYield
  }

  /// 320 is the display's floor; 4096 keeps a 2× backing store within 8192 px.
  static let minSide: CGFloat = 320
  static let maxSide: CGFloat = 4096
  /// Fixed identity ("WH"), so System Settings › Displays remembers where
  /// each of Whisper's displays sits instead of collecting new entries.
  static let vendorID: UInt32 = 0x5748
  static let productID: UInt32 = 0x0001

  private static var disabled = false
  private static var creationFailures = 0
  private static var serialsInUse = Set<UInt32>()
  private static var menuInset: CGFloat = 24
  private static var insetMeasured = false

  private var serial: UInt32 = 0
  private var display: VirtualDisplay?
  private var scDisplay: SCDisplay?
  private(set) var placement: Placement?
  private var askedSize: CGSize?
  private var cursorBefore: CGPoint?
  private var generation = 0
  private(set) var captureRect: CGRect = .zero

  /// The display, for mapping the viewer's touches onto it.
  var displayID: CGDirectDisplayID? { display?.isAlive == true ? display?.displayID : nil }

  /// The window server took the display away (sleep, a display change).
  var onLost: (() -> Void)?

  var isStaged: Bool { display != nil && placement != nil }

  // MARK: Geometry

  /// The display's size in Mac points: the viewer's screen divided by its
  /// text scale (Aa).
  static func displaySize(viewport: CGSize, scale: CGFloat) -> CGSize {
    let s = scale > 0 ? scale : 1
    return CGSize(width: (viewport.width / s).rounded(), height: (viewport.height / s).rounded())
  }

  static func clamp(_ s: CGSize) -> CGSize {
    CGSize(width: min(max(s.width, minSide), maxSide), height: min(max(s.height, minSide), maxSide))
  }

  /// Already staged at this size (±2 pt): nothing to move.
  /// How much of the display's bottom the viewer's keyboard covers (0 to
  /// 0.8): the window stops above it, the way an app on a phone does, so
  /// the field being typed in sits just over the keys.
  private(set) var bottomInset: CGFloat = 0

  func setBottomInset(_ value: CGFloat) {
    let inset = min(max(value, 0), 0.8)
    guard abs(inset - bottomInset) > 0.01 else { return }
    bottomInset = inset
    guard let p = placement, let d = display, d.isAlive,
      let usable = Self.usableArea(of: d.displayID)
    else { return }
    Self.move(p.element, to: Self.shortened(usable, by: inset))
  }

  static func shortened(_ area: CGRect, by inset: CGFloat) -> CGRect {
    CGRect(
      x: area.minX, y: area.minY, width: area.width,
      height: (area.height * (1 - inset)).rounded())
  }

  func matches(windowID: CGWindowID, size: CGSize) -> Bool {
    guard let p = placement, p.windowID == windowID, let asked = askedSize, display?.isAlive == true
    else { return false }
    return abs(asked.width - size.width) <= 2 && abs(asked.height - size.height) <= 2
  }

  /// Someone moved the window off the display (Mission Control, a drag).
  var windowLeftDisplay: Bool {
    guard let p = placement, let d = display, d.isAlive, let live = Self.liveBounds(of: p.windowID)
    else { return false }
    return Self.fraction(of: live, inside: CGDisplayBounds(d.displayID)) < 0.9
  }

  var windowGone: Bool {
    guard let p = placement else { return true }
    return Self.liveBounds(of: p.windowID) == nil
  }

  /// macOS remembers which display a window was on and puts it back when
  /// that display returns; this one returns with the same identity each
  /// time, so another app's window can land here, out of everyone's sight.
  /// Those go to the main display. The staged app's own new windows (a
  /// dialog, say) stay: the viewer sees and uses them.
  func evictStrangers() {
    guard let p = placement, let d = display, d.isAlive,
      let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
      let area = Self.visibleArea(of: CGMainDisplayID())
    else { return }
    let bounds = CGDisplayBounds(d.displayID)
    let ownPid = ProcessInfo.processInfo.processIdentifier
    for info in list {
      guard (info[kCGWindowLayer as String] as? Int) == 0,
        let id = info[kCGWindowNumber as String] as? CGWindowID, id != p.windowID,
        let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != p.pid, pid != ownPid,
        let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
        let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
        bounds.contains(CGPoint(x: frame.midX, y: frame.midY)),
        let element = Self.axWindow(id: id, pid: pid, title: nil)
      else { continue }
      let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
      Self.move(
        element,
        to: CGRect(
          origin: CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2),
          size: size))
    }
  }

  // MARK: Staging

  func prepare(window: SCWindow, screen wanted: CGSize) async throws -> Prepared {
    marks = [("start", CACurrentMediaTime())]
    lastContent = nil
    if Self.disabled { throw Failure.disabled }
    guard AXIsProcessTrusted() else { throw Failure.accessibilityOff }
    // Without Screen Recording, SCShareableContent never answers once a
    // virtual display exists: never create one then.
    guard CGPreflightScreenCaptureAccess() else { throw Failure.screenRecordingOff }
    guard let app = window.owningApplication else { throw Failure.windowMissing }

    var p: Placement
    if let current = placement, current.windowID == window.windowID {
      p = current
    } else {
      var found = Self.axWindow(id: window.windowID, pid: app.processID, title: window.title)
      // On another Space (in full screen, say): the app's window list leaves
      // it out, but picking it in the app's Window menu makes it the main
      // window, which Accessibility does reach.
      if found == nil, Self.pickInWindowMenu(pid: app.processID, title: window.title) {
        let deadline = Date().addingTimeInterval(1.5)
        while found == nil, Date() < deadline {
          try? await Task.sleep(nanoseconds: 100_000_000)
          found = Self.axWindow(id: window.windowID, pid: app.processID, title: window.title)
        }
      }
      guard let element = found else { throw Failure.axWindowNotFound }
      AXUIElementSetMessagingTimeout(element, 1.0)
      // A window in a full-screen Space cannot be moved: bring it out first
      // (it goes back to full screen when it comes home).
      var wasFullScreen = false
      if Self.isFullScreen(element) {
        wasFullScreen = true
        AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, kCFBooleanFalse)
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline, Self.isFullScreen(element) {
          try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // The Space animation ends a moment after the attribute changes.
        try? await Task.sleep(nanoseconds: 700_000_000)
        if Self.isFullScreen(element) { throw Failure.fullScreen }
      }
      // A minimized window cannot be moved; bring it back first.
      if Self.isMinimized(element) {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, Self.isMinimized(element) {
          try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
      }
      let original = Self.frame(of: element) ?? Self.liveBounds(of: window.windowID) ?? window.frame
      p = Placement(
        windowID: window.windowID, pid: app.processID, element: element, originalFrame: original,
        wasFullScreen: wasFullScreen)
    }
    // Another window on this display goes home first.
    if let other = placement, other.windowID != window.windowID {
      releaseWindow()
    }
    mark("window found")

    try await ensureDisplay(size: wanted)
    guard let d = display else { throw Failure.neverOnline }

    // A window left on a virtual display by an earlier run has no real home;
    // give it one in the middle of the main display.
    if p.originalFrame.intersects(CGDisplayBounds(d.displayID)) {
      p = Placement(
        windowID: p.windowID, pid: p.pid, element: p.element,
        originalFrame: Self.homeFrame(size: p.originalFrame.size), wasFullScreen: p.wasFullScreen)
    }
    // From here on the window is ours: record the way home before moving it.
    placement = p
    Self.setSnapshot(serial, (p.element, p.originalFrame))

    var live = CGRect.zero
    var displayBounds = CGRect.zero
    for attempt in 0..<2 {
      guard let d = display else {
        releaseWindow()
        throw Failure.neverOnline
      }
      displayBounds = CGDisplayBounds(d.displayID)
      let usable =
        Self.usableArea(of: d.displayID)
        ?? displayBounds.divided(atDistance: Self.menuInset, from: .minYEdge).remainder
      // The window fills the display below its menu bar, and stops above
      // the viewer's keyboard while it is up.
      let dest = Self.shortened(usable, by: bottomInset)
      let before = Self.liveBounds(of: p.windowID)
      if let before, Self.close(before, dest), Self.fraction(of: before, inside: displayBounds) >= 0.9 {
        live = before
      } else {
        if cursorBefore == nil {
          cursorBefore = CGEvent(source: nil)?.location
        }
        guard Self.move(p.element, to: dest) == .success else {
          releaseWindow()
          throw Failure.moveRefused
        }
        // Wait for the window server to show the move: until the frame is
        // where it was asked to be, or has stopped changing (an app that
        // enforces a minimum settles elsewhere).
        var taken: CGRect?
        if let before, let f = Self.frame(of: p.element), !Self.sameSize(f.size, before.size) {
          taken = f
        }
        var stillnessCounts = taken == nil
        var same = 0
        var last = before
        let deadline = Date().addingTimeInterval(taken == nil ? 0.5 : 1.0)
        while Date() < deadline {
          let now = Self.liveBounds(of: p.windowID)
          if let now, Self.close(now, dest) {
            last = now
            break
          }
          if let now, let taken, Self.close(now, taken) {
            last = now
            break
          }
          if let before, now.map({ Self.sameSize($0.size, before.size) }) != true {
            stillnessCounts = true
          }
          same = (now == last) ? same + 1 : 0
          last = now
          if stillnessCounts, same >= 3 { break }
          try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let moved = last ?? Self.liveBounds(of: p.windowID) else {
          releaseWindow()
          throw Failure.windowMissing
        }
        live = moved
      }
      let oversized = live.width > usable.width + 2 || live.height > usable.height + 2
      if oversized, attempt == 0 {
        // The app insists on a bigger minimum: grow the display once.
        do {
          try await ensureDisplay(
            size: CGSize(width: live.width, height: live.height + Self.menuInset))
        } catch {
          releaseWindow()
          throw error
        }
        placement = p
        Self.setSnapshot(serial, (p.element, p.originalFrame))
        continue
      }
      guard Self.fraction(of: live, inside: displayBounds) >= (oversized ? 0.5 : 0.9) else {
        releaseWindow()
        throw Failure.notOnDisplay
      }
      break
    }

    askedSize = wanted
    captureRect = Self.even(CGRect(origin: .zero, size: displayBounds.size))
    guard let scDisplay, display?.isAlive == true else {
      releaseWindow()
      throw Failure.notListedBySCK
    }
    mark("moved")
    return Prepared(
      display: scDisplay, sourceRect: captureRect, content: lastContent, timings: timings())
  }

  // MARK: Timing

  private var marks: [(String, Double)] = []
  private var lastContent: SCShareableContent?

  private func mark(_ name: String) {
    marks.append((name, CACurrentMediaTime()))
  }

  /// "window found 12, display 1830 (created 40, online 900, …), moved 310" in ms.
  private func timings() -> String {
    var parts: [String] = []
    for index in 1..<marks.count {
      let ms = Int(((marks[index].1 - marks[index - 1].1) * 1000).rounded())
      parts.append("\(marks[index].0) \(ms)")
    }
    let total = Int((((marks.last?.1 ?? 0) - (marks.first?.1 ?? 0)) * 1000).rounded())
    return "\(total) ms: " + parts.joined(separator: ", ")
  }

  /// A display of exactly [wanted] points (the viewer's shape); reused when
  /// it already is that size, recreated otherwise.
  private func ensureDisplay(size wanted: CGSize) async throws {
    let size = Self.clamp(CGSize(width: wanted.width.rounded(), height: wanted.height.rounded()))
    if let d = display, d.isAlive, scDisplay != nil,
      abs(CGFloat(d.widthPt) - size.width) <= 1, abs(CGFloat(d.heightPt) - size.height) <= 1
    {
      mark("display reused")
      return
    }
    // Replacing the display under the window would let the window server
    // drop it anywhere: send it home first; prepare places it again.
    let leaving = placement != nil ? releaseWindow() : nil
    let old = display
    display = nil
    scDisplay = nil
    await Self.retire(old, after: leaving)

    if serial == 0 {
      serial = (1...16).map(UInt32.init).first { !Self.serialsInUse.contains($0) } ?? 16
      Self.serialsInUse.insert(serial)
    }
    let d: VirtualDisplay
    do {
      d = try VirtualDisplay(
        name: "Whisper", widthPt: Int(size.width), heightPt: Int(size.height),
        scale: 2, refreshHz: 60, vendorID: Self.vendorID, productID: Self.productID,
        serialNum: serial)
    } catch {
      Self.creationFailures += 1
      if Self.creationFailures >= 2 {
        Self.disabled = true
      }
      throw Failure.displayCreate
    }
    Self.creationFailures = 0
    mark("display created")
    generation += 1
    let current = generation
    display = d
    d.onTerminated = { [weak self] in
      Task { @MainActor [weak self] in self?.lost(generation: current) }
    }
    if !(await d.waitUntilOnline(timeout: 3)), d.bounds.width == 0 {
      destroyDisplay()
      throw Failure.neverOnline
    }
    mark("online")
    await Self.arrange(d.displayID)
    mark("arranged")
    if !Self.insetMeasured {
      let deadline = Date().addingTimeInterval(1)
      while Self.screen(for: d.displayID) == nil, Date() < deadline {
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      if let screen = Self.screen(for: d.displayID) {
        Self.insetMeasured = true
        Self.menuInset = screen.frame.maxY - screen.visibleFrame.maxY
      }
    }
    // ScreenCaptureKit lists a new display a little after CoreGraphics.
    let start = Date()
    var listed: SCDisplay?
    while Date().timeIntervalSince(start) < 3 {
      if let content = await Self.shareableContent(timeout: 1),
        let found = content.displays.first(where: { $0.displayID == d.displayID })
      {
        listed = found
        lastContent = content
        break
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    guard let listed, display === d else {
      destroyDisplay()
      throw Failure.notListedBySCK
    }
    scDisplay = listed
    mark("listed by SCK")
  }

  // MARK: Teardown

  /// Puts the window back where it was. The display stays; the window
  /// sent home is returned, for removing the display only once it is off.
  @discardableResult
  func releaseWindow() -> CGWindowID? {
    let leaving = placement?.windowID
    if let p = placement {
      // Its old display may have gone meanwhile (a screen unplugged): then
      // the middle of the main one.
      let home =
        Self.onRealScreen(p.originalFrame)
        ? p.originalFrame : Self.homeFrame(size: p.originalFrame.size)
      var error = Self.move(p.element, to: home)
      if error == .cannotComplete, Self.liveBounds(of: p.windowID) != nil {
        error = Self.move(p.element, to: home)
      }
      if p.wasFullScreen {
        // Back to full screen once the move has settled: starting the
        // full-screen animation while the window is still on its way can
        // leave the system's transition layer stuck over the screen.
        let element = p.element
        let id = p.windowID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
          guard let live = Self.liveBounds(of: id), Self.onRealScreen(live) else { return }
          AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, kCFBooleanTrue)
        }
      }
    }
    // The Mac's pointer followed the viewer's taps onto the display; bring it
    // back before the display goes away.
    if let d = display, d.isAlive, let here = CGEvent(source: nil)?.location,
      CGDisplayBounds(d.displayID).contains(here)
    {
      let main = CGDisplayBounds(CGMainDisplayID())
      CGWarpMouseCursorPosition(cursorBefore ?? CGPoint(x: main.midX, y: main.midY))
    }
    cursorBefore = nil
    placement = nil
    askedSize = nil
    captureRect = .zero
    Self.setSnapshot(serial, nil)
    return leaving
  }

  func destroyDisplay() {
    display?.destroy()
    display = nil
    scDisplay = nil
  }

  /// Removes [display] once window [leaving] is off it. Removed under a
  /// window still on its way off, the window server can leave that window
  /// on no Space at all, where nobody sees it and its app cannot bring it
  /// back.
  private static func retire(_ display: VirtualDisplay?, after leaving: CGWindowID?) async {
    guard let display else { return }
    if let id = leaving, display.isAlive {
      let bounds = CGDisplayBounds(display.displayID)
      let deadline = Date().addingTimeInterval(1.5)
      while Date() < deadline, let live = liveBounds(of: id), live.intersects(bounds) {
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      // And a moment for the window server to settle it on a Space.
      try? await Task.sleep(nanoseconds: 200_000_000)
    }
    display.destroy()
  }

  /// To the right of the Mac's own screens (and of Whisper's other ones),
  /// top edges with the main display: leaving the right edge takes the
  /// pointer over, the left edge brings it back.
  private static func arrange(_ id: CGDirectDisplayID) async {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return }
    let others = ids.prefix(Int(count)).filter { $0 != id }
    let x = others.map { CGDisplayBounds($0).maxX }.max() ?? CGDisplayBounds(CGMainDisplayID()).maxX
    let y = CGDisplayBounds(CGMainDisplayID()).minY
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return }
    CGConfigureDisplayOrigin(config, id, Int32(x), Int32(y))
    guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { return }
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline, CGDisplayBounds(id).minX != x {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  /// Window home, then display gone. (Its identity stays taken until then,
  /// so a new display does not pick it up meanwhile.)
  func release() {
    let leaving = releaseWindow()
    let old = display
    display = nil
    scDisplay = nil
    let freed = serial
    serial = 0
    Task { @MainActor in
      await Self.retire(old, after: leaving)
      if freed != 0 {
        Self.serialsInUse.remove(freed)
      }
      // Should a window still have been dropped, put it back.
      StrandedWindows.rescueSoon(after: 1)
    }
  }

  private func lost(generation current: Int) {
    guard current == generation, display != nil else { return }
    display = nil
    scDisplay = nil
    releaseWindow()
    onLost?()
  }

  // MARK: Way home at exit

  private static let snapshotLock = NSLock()
  nonisolated(unsafe) private static var snapshots: [UInt32: (AXUIElement, CGRect)] = [:]
  nonisolated(unsafe) private static var exitHookInstalled = false

  private static func setSnapshot(_ serial: UInt32, _ value: (AXUIElement, CGRect)?) {
    snapshotLock.lock()
    snapshots[serial] = value
    if !exitHookInstalled {
      exitHookInstalled = true
      atexit { VirtualStage.restoreAllAtExit() }
    }
    snapshotLock.unlock()
  }

  /// Last resort when the app quits with windows still staged: the display
  /// dies with the process, the windows go back where they were.
  nonisolated static func restoreAllAtExit() {
    snapshotLock.lock()
    let all = Array(snapshots.values)
    snapshots.removeAll()
    snapshotLock.unlock()
    for (element, frame) in all {
      var origin = frame.origin
      var size = frame.size
      guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size)
      else { continue }
      AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
      AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, extent)
      AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
    }
    // The displays go with the process: not before the windows are off them
    // (see retire).
    let ids = all.compactMap { windowID(of: $0.0) }
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline,
      ids.contains(where: { id in liveBounds(of: id).map(onOurDisplay) ?? false })
    {
      usleep(50_000)
    }
    if !ids.isEmpty {
      usleep(200_000)
    }
  }

  // MARK: Window server and Accessibility

  private typealias GetWindowFn =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

  /// `_AXUIElementGetWindow`: private, but the only exact CGWindowID → AX
  /// mapping; looked up at run time so its absence is just a fallback.
  nonisolated(unsafe) private static let axGetWindow: GetWindowFn? = {
    guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "_AXUIElementGetWindow")
    else { return nil }
    return unsafeBitCast(symbol, to: GetWindowFn.self)
  }()

  /// The CGWindowID of an AX window, where the private lookup exists.
  nonisolated static func windowID(of element: AXUIElement) -> CGWindowID? {
    guard let getWindow = axGetWindow else { return nil }
    var id: CGWindowID = 0
    return getWindow(element, &id) == .success && id != 0 ? id : nil
  }

  /// Presses the item titled [title] in the app's Window menu (the menu
  /// that lists its windows). False when there is no such single item.
  nonisolated static func pickInWindowMenu(pid: pid_t, title: String?) -> Bool {
    guard let title, !title.isEmpty else { return false }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.0)
    guard let bar = element(of: app, kAXMenuBarAttribute) else { return false }
    var matches: [AXUIElement] = []
    for menuTitle in children(of: bar) {
      for menu in children(of: menuTitle) {
        let items = children(of: menu)
        // The Window menu is the one whose items include the window list;
        // skip the long menus that cannot be it quickly.
        guard items.count < 80 else { continue }
        matches += items.filter { string(of: $0, kAXTitleAttribute) == title }
      }
    }
    guard matches.count == 1 else { return false }
    return AXUIElementPerformAction(matches[0], kAXPressAction as CFString) == .success
  }

  nonisolated private static func element(of parent: AXUIElement, _ name: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(parent, name as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
  }

  nonisolated private static func children(of parent: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &value) == .success
    else { return [] }
    return value as? [AXUIElement] ?? []
  }

  /// The app's AX window for [id]: by id when possible, else the one window
  /// with that title, else the one at the window's frame (±4 pt). Nil for a
  /// window on another Space unless it is the app's main window.
  nonisolated static func axWindow(id: CGWindowID, pid: pid_t, title: String?) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.0)
    // The main and focused windows are there whatever Space they are in.
    for name in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
      if let window = element(of: app, name), windowID(of: window) == id {
        AXUIElementSetMessagingTimeout(window, 0.5)
        return window
      }
    }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
      let candidates = value as? [AXUIElement], !candidates.isEmpty
    else { return nil }
    for candidate in candidates {
      AXUIElementSetMessagingTimeout(candidate, 0.5)
    }
    if let getWindow = axGetWindow {
      for candidate in candidates {
        var found: CGWindowID = 0
        if getWindow(candidate, &found) == .success, found == id {
          return candidate
        }
      }
      // Not in the list: on another Space. Guessing by title or frame
      // would pick the wrong window.
      return nil
    }
    let name = title ?? ""
    let titled = name.isEmpty ? [] : candidates.filter { string(of: $0, kAXTitleAttribute) == name }
    if titled.count == 1 {
      return titled[0]
    }
    guard let bounds = liveBounds(of: id) else { return nil }
    return (titled.isEmpty ? candidates : titled).first { candidate in
      guard let f = frame(of: candidate) else { return false }
      return close(f, bounds, within: 4)
    }
  }

  nonisolated static func liveBounds(of id: CGWindowID) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
      let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary
    else { return nil }
    return CGRect(dictionaryRepresentation: bounds as CFDictionary)
  }

  /// Position, size, position: an app that clamps the size may shift the
  /// origin. Returns the first error.
  @discardableResult
  static func move(_ element: AXUIElement, to frame: CGRect) -> AXError {
    var first = AXError.success
    for error in [
      set(element, position: frame.origin), set(element, size: frame.size),
      set(element, position: frame.origin),
    ] where first == .success && error != .success {
      first = error
    }
    return first
  }

  private static func set(_ element: AXUIElement, position: CGPoint) -> AXError {
    var point = position
    guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
    return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
  }

  private static func set(_ element: AXUIElement, size: CGSize) -> AXError {
    var extent = size
    guard let value = AXValueCreate(.cgSize, &extent) else { return .failure }
    return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
  }

  nonisolated static func frame(of element: AXUIElement) -> CGRect? {
    var point = CGPoint.zero
    var size = CGSize.zero
    guard let position = axValue(element, kAXPositionAttribute),
      AXValueGetValue(position, .cgPoint, &point),
      let extent = axValue(element, kAXSizeAttribute), AXValueGetValue(extent, .cgSize, &size)
    else { return nil }
    return CGRect(origin: point, size: size)
  }

  nonisolated private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    return (value as! AXValue)
  }

  nonisolated private static func string(of element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return nil
    }
    return value as? String
  }

  private static func bool(of element: AXUIElement, _ attribute: String) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return false
    }
    return (value as? Bool) ?? false
  }

  static func isFullScreen(_ element: AXUIElement) -> Bool { bool(of: element, "AXFullScreen") }

  static func isMinimized(_ element: AXUIElement) -> Bool {
    bool(of: element, kAXMinimizedAttribute)
  }

  static func screen(for id: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
    }
  }

  /// The display's area below its menu bar, in global (top-left) points.
  static func usableArea(of id: CGDirectDisplayID) -> CGRect? {
    guard let screen = screen(for: id), let primary = NSScreen.screens.first?.frame.height else {
      return nil
    }
    let visible = screen.visibleFrame
    return CGRect(
      x: visible.minX, y: primary - visible.maxY, width: visible.width, height: visible.height)
  }

  private static func visibleArea(of id: CGDirectDisplayID) -> CGRect? { usableArea(of: id) }

  /// A frame of [size] centred below the main display's menu bar.
  static func homeFrame(size: CGSize) -> CGRect {
    let main = CGDisplayBounds(CGMainDisplayID())
    let menuBar: CGFloat = 33
    let width = min(size.width, main.width)
    let height = min(size.height, main.height - menuBar)
    return CGRect(
      x: (main.midX - width / 2).rounded(),
      y: (main.minY + menuBar + (main.height - menuBar - height) / 2).rounded(),
      width: width, height: height)
  }

  /// On a display that is not one of ours.
  nonisolated static func onRealScreen(_ rect: CGRect) -> Bool {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return true }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return true }
    return ids.prefix(Int(count)).contains { id in
      CGDisplayVendorNumber(id) != vendorID && CGDisplayBounds(id).intersects(rect)
    }
  }

  /// On one of Whisper's displays.
  nonisolated static func onOurDisplay(_ rect: CGRect) -> Bool {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
    return ids.prefix(Int(count)).contains { id in
      CGDisplayVendorNumber(id) == vendorID && CGDisplayBounds(id).intersects(rect)
    }
  }

  private static func shareableContent(timeout: TimeInterval) async -> SCShareableContent? {
    await withCheckedContinuation { continuation in
      let lock = NSLock()
      var done = false
      func finish(_ content: SCShareableContent?) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume(returning: content)
      }
      SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, _ in
        finish(content)
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }
  }

  static func fraction(of rect: CGRect, inside area: CGRect) -> CGFloat {
    let inside = rect.intersection(area)
    guard !inside.isNull, rect.width > 0, rect.height > 0 else { return 0 }
    return (inside.width * inside.height) / (rect.width * rect.height)
  }

  nonisolated static func close(_ a: CGRect, _ b: CGRect, within t: CGFloat = 2) -> Bool {
    abs(a.minX - b.minX) <= t && abs(a.minY - b.minY) <= t && abs(a.width - b.width) <= t
      && abs(a.height - b.height) <= t
  }

  private static func sameSize(_ a: CGSize, _ b: CGSize) -> Bool {
    abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
  }

  /// Whole, even pixels at 2×, so ScreenCaptureKit never resamples.
  static func even(_ rect: CGRect) -> CGRect {
    let width = CGFloat(max(16, Int(rect.width * 2) & ~1)) / 2
    let height = CGFloat(max(16, Int(rect.height * 2) & ~1)) / 2
    return CGRect(x: rect.minX, y: rect.minY, width: width, height: height)
  }
}

/// Closes a window the way its own close button would (the app may still
/// ask to save). Main thread; needs Accessibility.
@available(macOS 12.3, *)
enum WindowCloser {
  static func close(windowId: CGWindowID, pid: pid_t) {
    guard AXIsProcessTrusted(),
      let element = VirtualStage.axWindow(id: windowId, pid: pid, title: nil)
    else { return }
    var button: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button)
        == .success, let button
    else { return }
    AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
  }
}
