import Cocoa
import FlutterMacOS
import ScreenCaptureKit

// Step 1 of docs/design/migration.md: lets lib/new_ui/probe click through AppKit
// and see what is on screen, in debug builds only. Goes away with the probe.
extension MainFlutterWindow {
  func handleProbeCall(
    _ call: FlutterMethodCall, result: @escaping FlutterResult
  ) -> Bool {
    #if DEBUG
    switch call.method {
    case "debugHitTest":
      let args = call.arguments as? [String: Double] ?? [:]
      result(debugHitTest(x: args["x"] ?? 0, y: args["y"] ?? 0))
      return true
    case "debugClick":
      let args = call.arguments as? [String: Double] ?? [:]
      debugClick(x: args["x"] ?? 0, y: args["y"] ?? 0)
      result(nil)
      return true
    case "debugWindowInfo":
      result(debugWindowInfo())
      return true
    case "debugActivate":
      NSApp.activate(ignoringOtherApps: true)
      makeKeyAndOrderFront(nil)
      result(nil)
      return true
    case "debugCapture":
      debugCapture(path: call.arguments as? String ?? "", result: result)
      return true
    default:
      return false
    }
    #else
    return false
    #endif
  }

  #if DEBUG
  private func debugHitTest(x: Double, y: Double) -> String {
    guard let root = contentView?.superview else { return "none" }
    let point = NSPoint(x: x, y: frame.height - y)
    guard let hit = root.hitTest(point) else { return "none" }
    return String(describing: type(of: hit))
  }

  /// A click through the window's own event path, as far as AppKit can tell
  /// a real one. Needs no Accessibility permission, being this app's own.
  private func debugClick(x: Double, y: Double) {
    let point = NSPoint(x: x, y: frame.height - y)
    func send(_ type: NSEvent.EventType) {
      if let event = NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1)
      {
        NSApp.sendEvent(event)
      }
    }
    send(.leftMouseDown)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { send(.leftMouseUp) }
  }

  private func debugWindowInfo() -> [String: Any] {
    var info: [String: Any] = [
      "windowWidth": frame.width,
      "windowHeight": frame.height,
      "isOpaque": isOpaque,
      "hasShadow": hasShadow,
      "backing": backingScaleFactor,
      "material": windowMaterial?.isHidden == false,
      "isKey": isKeyWindow,
      "isMain": isMainWindow,
      "appActive": NSApp.isActive,
      "isMovable": isMovable,
      "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
    ]
    // Back to front: the material has to be behind what Flutter draws.
    if let flutter = contentViewController as? FlutterViewController {
      info["flutterView"] = String(describing: type(of: flutter.view))
      info["layersBackToFront"] =
        (flutter.view.layer?.sublayers ?? []).map { layer -> String in
          let isMaterial = layer === windowMaterial?.layer
          return isMaterial ? "material" : String(describing: type(of: layer))
        }
      info["layerClearColor"] =
        flutter.view.layer?.backgroundColor?.alpha ?? -1
    }
    if let close = standardWindowButton(.closeButton),
       let root = contentView?.superview {
      let rect = close.convert(close.bounds, to: root)
      info["closeX"] = rect.minX
      info["closeFromTop"] = root.bounds.height - rect.maxY
      info["closeWidth"] = rect.width
      info["closeHeight"] = rect.height
    }
    if let mini = standardWindowButton(.miniaturizeButton),
       let close = standardWindowButton(.closeButton) {
      info["lightPitch"] = mini.frame.minX - close.frame.minX
    }
    return info
  }

  /// What is on screen where this window is, so the desktop shows through.
  /// Asks for Screen Recording, and only ever covers this window's rectangle.
  private func debugCapture(path: String, result: @escaping FlutterResult) {
    guard #available(macOS 14.0, *) else {
      result("needs macOS 14")
      return
    }
    let area = frame
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) {
      content, error in
      guard let content = content,
            let display = content.displays.first(where: { display in
              NSRect(
                x: CGFloat(display.frame.minX), y: 0,
                width: display.frame.width, height: display.frame.height
              ).intersects(NSRect(x: area.minX, y: 0, width: area.width, height: 1))
            }) else {
        DispatchQueue.main.async {
          let displays = content?.displays.map { "\($0.frame)" } ?? []
          result(
            "no access: \(error?.localizedDescription ?? "no error")"
              + " displays=\(displays) window=\(area)"
              + " preflight=\(CGPreflightScreenCaptureAccess())")
        }
        return
      }
      let primaryHeight = NSScreen.screens.first?.frame.height ?? area.maxY
      let config = SCStreamConfiguration()
      config.sourceRect = CGRect(
        x: area.minX - display.frame.minX,
        y: primaryHeight - area.maxY - display.frame.minY,
        width: area.width, height: area.height)
      let scale = NSScreen.main?.backingScaleFactor ?? 2
      config.width = Int(area.width * scale)
      config.height = Int(area.height * scale)
      config.showsCursor = false
      let filter = SCContentFilter(display: display, excludingWindows: [])
      SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
        image, error in
        DispatchQueue.main.async {
          guard let image = image else {
            result("no image: \(error?.localizedDescription ?? "unknown")")
            return
          }
          let rep = NSBitmapImageRep(cgImage: image)
          if let data = rep.representation(using: .png, properties: [:]),
             (try? data.write(to: URL(fileURLWithPath: path))) != nil {
            result("ok")
          } else {
            result("could not write")
          }
        }
      }
    }
  }
  #endif
}
