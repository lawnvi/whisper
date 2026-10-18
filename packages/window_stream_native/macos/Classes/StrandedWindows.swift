import AppKit
import ApplicationServices

/// Windows shown on no Space. A display removed while a window is still on
/// its way off it can leave the window there: nobody sees it, and its app,
/// which thinks it open, does nothing when asked to show it (clicking its
/// Dock icon, say). Only Whisper's virtual displays come and go like that,
/// so Whisper puts such windows back: out to the Dock and back again, which
/// lands them on the desktop in front.
@available(macOS 12.3, *)
@MainActor
enum StrandedWindows {
  private static var running = false
  private static var waitingForDesktop: NSObjectProtocol?

  /// Looks after [delay]; while an app is in full screen, once a desktop is
  /// in front instead (a window coming back there would pull the user out).
  static func rescueSoon(after delay: TimeInterval = 0) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      guard AXIsProcessTrusted(), !find().isEmpty else { return }
      guard WindowSpaces.desktopInFront else {
        waitForDesktop()
        return
      }
      Task { @MainActor in await rescue() }
    }
  }

  private static func waitForDesktop() {
    guard waitingForDesktop == nil else { return }
    waitingForDesktop = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        guard WindowSpaces.desktopInFront, let observer = waitingForDesktop else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        waitingForDesktop = nil
        // The Space animation ends a moment after the switch.
        rescueSoon(after: 0.6)
      }
    }
  }

  struct Stranded {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let owner: String
  }

  /// Other apps' ordinary windows that are shown yet on no Space.
  static func find() -> [Stranded] {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    let ownPid = ProcessInfo.processInfo.processIdentifier
    var found: [Stranded] = []
    for info in list {
      guard (info[kCGWindowLayer as String] as? Int) == 0,
        let id = info[kCGWindowNumber as String] as? CGWindowID,
        let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPid,
        (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
        let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
        let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
        frame.width >= 60, frame.height >= 60,
        WindowSpaces.isOrderedIn(id),
        let spaces = WindowSpaces.spaces(of: id), spaces.isEmpty
      else { continue }
      found.append(
        Stranded(
          id: id, pid: pid, frame: frame,
          owner: info[kCGWindowOwnerName as String] as? String ?? "?"))
    }
    return found
  }

  private static func rescue() async {
    guard !running else { return }
    running = true
    defer { running = false }
    for window in find() {
      let result = await bringBack(window)
      CaptureRegistry.shared.note(
        id: 0, "window of \(window.owner) was on no Space: \(result)")
    }
  }

  private static func bringBack(_ window: Stranded) async -> String {
    guard let element = VirtualStage.axWindow(id: window.id, pid: window.pid, title: nil) else {
      return "not reachable"
    }
    // Somewhere on the Mac's own screens first.
    if !VirtualStage.onRealScreen(window.frame) {
      VirtualStage.move(element, to: VirtualStage.homeFrame(size: window.frame.size))
    }
    AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    guard await settle({ VirtualStage.isMinimized(element) }) else {
      return "would not go to the Dock"
    }
    AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    guard await settle({ !VirtualStage.isMinimized(element) }) else {
      return "stuck in the Dock"
    }
    let back = await settle { WindowSpaces.spaces(of: window.id)?.isEmpty == false }
    return back ? "back on the desktop" : "still on no Space"
  }

  /// Waits up to [seconds] for [done].
  private static func settle(_ done: () -> Bool, seconds: TimeInterval = 1.5) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if done() { return true }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return done()
  }
}
