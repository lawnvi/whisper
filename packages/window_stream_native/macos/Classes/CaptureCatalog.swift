import AppKit
import ScreenCaptureKit

/// Lists windows that can be streamed, plus app icons and window thumbnails.
/// Results are delivered through the capture callback because
/// ScreenCaptureKit only answers asynchronously.
enum CaptureCatalog {
  static func requestCatalog(requestId: Int64) {
    guard #available(macOS 12.3, *) else {
      CaptureRegistry.shared.emit(id: requestId, kind: WSNCapture.kindFailed, flags: WSNCapture.errorUnsupported)
      return
    }
    // Every window that is really open, in any Space (a full-screen app is a
    // Space of its own) or minimized; apps' hidden helper windows (one
    // WeChat keeps half a dozen) belong to no Space and are left out.
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
      guard let content = content else {
        CaptureRegistry.shared.emit(
          id: requestId, kind: WSNCapture.kindFailed,
          flags: error == nil ? WSNCapture.errorUnknown : WSNCapture.errorPermission)
        return
      }
      let ownPid = ProcessInfo.processInfo.processIdentifier
      // Some apps keep fully transparent windows "on screen"; nobody sees them.
      let invisible = CaptureCatalog.transparentWindows()
      var windows: [[String: Any]] = []
      var axByPid: [pid_t: (all: Set<CGWindowID>, minimized: Set<CGWindowID>)] = [:]
      for window in content.windows {
        guard let app = window.owningApplication, app.processID != ownPid,
          !app.applicationName.isEmpty,
          window.windowLayer == 0, window.frame.width > 100, window.frame.height > 100,
          !invisible.contains(window.windowID)
        else { continue }
        let ax = axByPid[app.processID] ?? WindowSpaces.axWindows(pid: app.processID)
        axByPid[app.processID] = ax
        let running = NSRunningApplication(processIdentifier: app.processID)
        guard running?.activationPolicy == .regular else { continue }
        // The windows people see: shown on any desktop or in full screen,
        // minimized, or belonging to a hidden app. Windows closed to the menu
        // bar stay in the list, ordered out.
        let shown = window.isOnScreen || WindowSpaces.isOrderedIn(window.windowID)
        guard
          shown || ax.minimized.contains(window.windowID)
            || (running?.isHidden == true && ax.all.contains(window.windowID))
        else { continue }
        windows.append([
          "id": Int(window.windowID),
          "title": window.title ?? "",
          "appName": app.applicationName,
          "bundleId": app.bundleIdentifier,
          "pid": Int(app.processID),
          "width": Int(window.frame.width),
          "height": Int(window.frame.height),
          "onScreen": window.isOnScreen,
          "active": running?.isActive ?? false,
        ])
      }
      // A locked session gets no frames at all; say so instead of timing out.
      let session = CGSessionCopyCurrentDictionary() as? [String: Any]
      let locked = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
      emitJson(
        ["windows": windows, "apps": InstalledApps.shared.list(), "locked": locked],
        id: requestId, kind: WSNCapture.kindCatalog)
    }
  }

  static func transparentWindows() -> Set<CGWindowID> {
    guard
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return [] }
    var ids = Set<CGWindowID>()
    for info in list {
      if let id = info[kCGWindowNumber as String] as? CGWindowID,
        let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01
      {
        ids.insert(id)
      }
    }
    return ids
  }

  /// Opens [bundleId] without bringing it forward, or sends a running app
  /// the reopen event a Dock click would (most apps then show a window).
  static func launchApp(requestId: Int64, bundleId: String) {
    DispatchQueue.main.async {
      guard !bundleId.isEmpty,
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
      else {
        CaptureRegistry.shared.emit(id: requestId, kind: WSNCapture.kindFailed, flags: WSNCapture.errorNotFound)
        return
      }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      configuration.addsToRecentItems = false
      NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
        if app == nil || error != nil {
          CaptureRegistry.shared.emit(id: requestId, kind: WSNCapture.kindFailed, flags: WSNCapture.errorUnknown)
        } else {
          CaptureRegistry.shared.emit(id: requestId, kind: WSNCapture.kindLaunched)
        }
      }
    }
  }

  static func requestIcon(requestId: Int64, bundleId: String, size: Int) {
    DispatchQueue.global(qos: .userInitiated).async {
      guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
        CaptureRegistry.shared.emit(id: requestId, kind: WSNCapture.kindFailed, flags: WSNCapture.errorNotFound)
        return
      }
      let icon = NSWorkspace.shared.icon(forFile: url.path)
      let pixels = max(16, min(size, 512))
      guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
      else { return }
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
      icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
      NSGraphicsContext.restoreGraphicsState()
      guard let png = rep.representation(using: .png, properties: [:]) else { return }
      emitData(png, id: requestId, kind: WSNCapture.kindIcon)
    }
  }

  static func requestThumbnail(requestId: Int64, windowId: UInt32, maxEdge: Int) {
    guard #available(macOS 12.3, *) else {
      CaptureRegistry.shared.emit(id: requestId, kind: WSNCapture.kindFailed, flags: WSNCapture.errorUnsupported)
      return
    }
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, _ in
      guard let window = content?.windows.first(where: { $0.windowID == windowId }) else {
        CaptureRegistry.shared.emit(id: requestId, kind: WSNCapture.kindFailed, flags: WSNCapture.errorNotFound)
        return
      }
      OneShotCapture.capture(window: window, maxEdge: maxEdge) { image in
        guard let image = image,
          let data = jpegData(image, quality: 0.75)
        else {
          CaptureRegistry.shared.emit(id: requestId, kind: WSNCapture.kindFailed, flags: WSNCapture.errorUnknown)
          return
        }
        emitData(data, id: requestId, kind: WSNCapture.kindThumbnail)
      }
    }
  }

  static func jpegData(_ image: CGImage, quality: Double) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }

  static func emitJson(_ object: Any, id: Int64, kind: Int32) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    emitData(data, id: id, kind: kind)
  }

  static func emitData(_ data: Data, id: Int64, kind: Int32) {
    let length = data.count
    guard let buffer = malloc(max(length, 1))?.assumingMemoryBound(to: UInt8.self) else { return }
    data.copyBytes(to: buffer, count: length)
    CaptureRegistry.shared.emit(id: id, kind: kind, data: buffer, length: Int32(length))
  }
}

/// Grabs a single frame of a window through a short-lived SCStream (works
/// on every macOS that has ScreenCaptureKit, unlike SCScreenshotManager).
@available(macOS 12.3, *)
final class OneShotCapture: NSObject, SCStreamOutput {
  private static var active = Set<OneShotCapture>()
  private static let lock = NSLock()

  private var stream: SCStream?
  private var completion: ((CGImage?) -> Void)?
  private let queue = DispatchQueue(label: "whisper.window_stream.thumbnail")

  static func capture(window: SCWindow, maxEdge: Int, completion: @escaping (CGImage?) -> Void) {
    let capture = OneShotCapture()
    capture.completion = completion
    lock.lock()
    active.insert(capture)
    lock.unlock()
    capture.start(window: window, maxEdge: maxEdge)
  }

  private func start(window: SCWindow, maxEdge: Int) {
    let configuration = SCStreamConfiguration()
    let scale = min(1, CGFloat(maxEdge) / max(window.frame.width, window.frame.height))
    configuration.width = max(16, Int(window.frame.width * scale * 2))
    configuration.height = max(16, Int(window.frame.height * scale * 2))
    configuration.showsCursor = false
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                          configuration: configuration, delegate: nil)
    self.stream = stream
    do {
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    } catch {
      finish(nil)
      return
    }
    stream.startCapture { [weak self] error in
      if error != nil {
        self?.finish(nil)
      }
    }
    queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finish(nil) }
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
              of type: SCStreamOutputType) {
    guard type == .screen, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()
    finish(context.createCGImage(image, from: image.extent))
  }

  private func finish(_ image: CGImage?) {
    guard let completion = completion else { return }
    self.completion = nil
    stream?.stopCapture(completionHandler: nil)
    stream = nil
    completion(image)
    OneShotCapture.lock.lock()
    OneShotCapture.active.remove(self)
    OneShotCapture.lock.unlock()
  }
}

/// Apps a viewer can start: the regular apps in the usual Applications
/// folders, read once a minute (a few hundred bundles take ~20 ms).
final class InstalledApps {
  static let shared = InstalledApps()

  private let lock = NSLock()
  private var cached: [(id: String, name: String)] = []
  private var readAt = Date.distantPast

  func list() -> [[String: Any]] {
    let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
    return bundles().map { ["bundleId": $0.id, "name": $0.name, "running": running.contains($0.id)] }
  }

  private func bundles() -> [(id: String, name: String)] {
    lock.lock()
    defer { lock.unlock() }
    if Date().timeIntervalSince(readAt) < 60 {
      return cached
    }
    let fileManager = FileManager.default
    let folders = [
      URL(fileURLWithPath: "/Applications"),
      URL(fileURLWithPath: "/Applications/Utilities"),
      URL(fileURLWithPath: "/System/Applications"),
      URL(fileURLWithPath: "/System/Applications/Utilities"),
      fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]
    let ownBundle = Bundle.main.bundleIdentifier
    var seen = Set<String>()
    var apps: [(id: String, name: String)] = []
    for folder in folders {
      guard let entries = try? fileManager.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      else { continue }
      for url in entries where url.pathExtension == "app" {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
          id != ownBundle, !seen.contains(id),
          (bundle.infoDictionary?["LSUIElement"] as? Bool) != true,
          (bundle.infoDictionary?["LSBackgroundOnly"] as? Bool) != true
        else { continue }
        seen.insert(id)
        let name = fileManager.displayName(atPath: url.path)
        apps.append((id: id, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name))
      }
    }
    cached = apps
    readAt = Date()
    return apps
  }
}

/// Whether the window server has a window ordered in (shown, on whichever
/// Space: SkyLight's private call, looked up at run time; if it is missing
/// every window counts as shown), and which of an app's windows are
/// minimized or listed by the app itself (Accessibility).
enum WindowSpaces {
  private typealias MainConnection = @convention(c) () -> Int32
  private typealias OrderedIn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Bool>) -> Int32

  private static let functions: (MainConnection, OrderedIn)? = {
    guard let handle = dlopen(nil, RTLD_NOW),
      let main = dlsym(handle, "SLSMainConnectionID") ?? dlsym(handle, "CGSMainConnectionID"),
      let ordered = dlsym(handle, "SLSWindowIsOrderedIn") ?? dlsym(handle, "CGSWindowIsOrderedIn")
    else { return nil }
    return (unsafeBitCast(main, to: MainConnection.self), unsafeBitCast(ordered, to: OrderedIn.self))
  }()

  /// Shown on some Space: this desktop, another one, or an app in full
  /// screen. Windows an app closed but keeps around (closed to the menu
  /// bar, say) are ordered out.
  static func isOrderedIn(_ id: CGWindowID) -> Bool {
    guard let (main, ordered) = functions else { return true }
    var shown = false
    guard ordered(main(), id, &shown) == 0 else { return true }
    return shown
  }

  private typealias SpacesForWindows =
    @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
  private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
  private typealias SpaceType = @convention(c) (Int32, UInt64) -> Int32

  private static let spaceFunctions: (SpacesForWindows, ActiveSpace, SpaceType)? = {
    guard let handle = dlopen(nil, RTLD_NOW),
      let spaces = dlsym(handle, "SLSCopySpacesForWindows"),
      let active = dlsym(handle, "SLSGetActiveSpace"),
      let type = dlsym(handle, "SLSSpaceGetType")
    else { return nil }
    return (
      unsafeBitCast(spaces, to: SpacesForWindows.self),
      unsafeBitCast(active, to: ActiveSpace.self),
      unsafeBitCast(type, to: SpaceType.self)
    )
  }()

  /// The Spaces window [id] is on (nil: unknown). A shown window on none is
  /// lost: nobody sees it, and its app, thinking it open, never brings it
  /// back.
  static func spaces(of id: CGWindowID) -> [UInt64]? {
    guard let (main, _) = functions, let (spacesFor, _, _) = spaceFunctions,
      let list = spacesFor(main(), 0x7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue()
        as? [NSNumber]
    else { return nil }
    return list.map(\.uint64Value)
  }

  /// A desktop is in front, not an app in full screen.
  static var desktopInFront: Bool {
    guard let (main, _) = functions, let (_, active, type) = spaceFunctions else { return true }
    let connection = main()
    return type(connection, active(connection)) == 0
  }

  /// The app's own list of its windows (Accessibility), and which of those
  /// are minimized.
  static func axWindows(pid: pid_t) -> (all: Set<CGWindowID>, minimized: Set<CGWindowID>) {
    guard AXIsProcessTrusted() else { return ([], []) }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
      let windows = value as? [AXUIElement]
    else { return ([], []) }
    var all = Set<CGWindowID>()
    var minimized = Set<CGWindowID>()
    for window in windows {
      guard #available(macOS 12.3, *), let id = VirtualStage.windowID(of: window) else { continue }
      all.insert(id)
      var flag: CFTypeRef?
      if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &flag) == .success,
        (flag as? Bool) == true
      {
        minimized.insert(id)
      }
    }
    return (all, minimized)
  }


}
