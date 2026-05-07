import Cocoa
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import CoreMedia
import FlutterMacOS
import OSLog
import ScreenCaptureKit
import window_manager

private let remoteInputLog = OSLog(
  subsystem: Bundle.main.bundleIdentifier ?? "com.vireen.whisper",
  category: "RemoteInput")

private func remoteInputEventMask(for type: CGEventType) -> CGEventMask {
  return CGEventMask(1) << CGEventMask(type.rawValue)
}

private let remoteInputCaptureEventMask: CGEventMask = [
  CGEventType.mouseMoved,
  CGEventType.leftMouseDragged,
  CGEventType.rightMouseDragged,
  CGEventType.otherMouseDragged,
  CGEventType.leftMouseDown,
  CGEventType.leftMouseUp,
  CGEventType.rightMouseDown,
  CGEventType.rightMouseUp,
  CGEventType.otherMouseDown,
  CGEventType.otherMouseUp,
  CGEventType.scrollWheel,
  CGEventType.keyDown,
  CGEventType.keyUp,
  CGEventType.flagsChanged,
].reduce(CGEventMask(0)) { mask, type in
  mask | remoteInputEventMask(for: type)
}

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    AudioSharePlugin.register(
      with: flutterViewController.registrar(forPlugin: "AudioSharePlugin"))
    RemoteInputPlugin.register(
      with: flutterViewController.registrar(forPlugin: "RemoteInputPlugin"))

    super.awakeFromNib()
  }

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
      super.order(place, relativeTo: otherWin)
      hiddenWindowAtLaunch()
  }
}

final class RemoteInputPlugin: NSObject, FlutterPlugin {
  private struct CaptureRoute {
    let routeId: String
    let sourceDisplayId: String
    let sourceEdge: String
    let sourceSegmentStart: CGFloat
    let sourceSegmentEnd: CGFloat
  }

  private struct InjectionRoute {
    let routeId: String
    let sourceDisplayId: String
    let sourceEdge: String
    let sinkDisplayId: String
    let sinkEdge: String
    let sinkSegmentStart: CGFloat
    let sinkSegmentEnd: CGFloat
    let sourceSegmentStart: CGFloat
    let sourceSegmentEnd: CGFloat
  }

  private struct InjectionReleaseRoute {
    let routeId: String
    let sourceDisplayId: String
    let sourceEdge: String
    let sourceSegmentStart: CGFloat
    let sourceSegmentEnd: CGFloat
    let edgeUnit: CGFloat
  }

  private struct CaptureCrossing {
    let route: CaptureRoute
    let edgeUnit: CGFloat
    let strictSegmentHit: Bool
    let normalMotion: CGFloat
    let travelToIntersection: CGFloat
  }

  private struct InjectionReleaseCrossing {
    let route: InjectionRoute
    let edgeUnit: CGFloat
    let strictSegmentHit: Bool
    let normalMotion: CGFloat
    let travelToIntersection: CGFloat
  }

  private let channel: FlutterMethodChannel
  private var captureSessionId = ""
  private var injectionSessionId = ""
  private var captureEdge = "right"
  private var captureRouteId = ""
  private var captureDisplayId = ""
  private var captureSegmentStart: CGFloat = 0
  private var captureSegmentEnd: CGFloat = 0
  private var captureSegments: [(start: CGFloat, end: CGFloat)] = []
  private var captureRoutes: [CaptureRoute] = []
  private var releaseHotkey = "ctrl+alt+esc"
  private var captureActive = false
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var sequence = 0
  private var captureActivationSequence = 0
  private var captureCursorHidden = false
  private var captureMouseButtons = 0
  private var injectedMouseButtons = 0
  private var injectedMousePoint: CGPoint?
  private var injectedMouseEnteredInterior = false
  private var injectedLastClickButton = -1
  private var injectedLastClickTimeMicros: Int64 = 0
  private var injectedLastClickPoint = CGPoint.zero
  private var injectedCurrentClickCount = 1
  private var injectionDisplayId = ""
  private var injectionEdge = ""
  private var injectionRouteId = ""
  private var injectionSegmentStart: CGFloat = 0
  private var injectionSegmentEnd: CGFloat = 0
  private var injectionRoutes: [InjectionRoute] = []
  private var captureActivationEdgeUnit: CGFloat?
  private var injectedKeyCodes: [Int] = []
  private var injectedModifierFlags = CGEventFlags()
  private let keyboardEventSource = CGEventSource(stateID: .hidSystemState)
  private var injectionKeyDiagnosticCount = 0
  private var injectionMouseDiagnosticCount = 0

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.vireen.whisper/remote_input",
      binaryMessenger: registrar.messenger)
    let instance = RemoteInputPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startCapture":
      guard let args = call.arguments as? [String: Any],
            let sessionId = args["sessionId"] as? String else {
        result(FlutterError(
          code: "bad-arguments",
          message: "startCapture requires sessionId",
          details: nil))
        return
      }
      let edge = args["edge"] as? String ?? "right"
      let releaseHotkey = args["releaseHotkey"] as? String ?? "ctrl+alt+esc"
      let displayId = args["displayId"] as? String ?? ""
      let segmentStart = doubleValue(args["segmentStart"])
      let segmentEnd = doubleValue(args["segmentEnd"])
      let segments = captureSegments(from: args["segments"])
      let routes = captureRoutes(from: args["segments"])
      startCapture(
        sessionId: sessionId,
        edge: edge,
        displayId: displayId,
        segmentStart: segmentStart,
        segmentEnd: segmentEnd,
        segments: segments,
        routes: routes,
        releaseHotkey: releaseHotkey,
        result: result)

    case "stopCapture":
      stopCapture()
      result(nil)

    case "pauseCapture":
      guard let args = call.arguments as? [String: Any],
            let sessionId = args["sessionId"] as? String else {
        result(FlutterError(
          code: "bad-arguments",
          message: "pauseCapture requires sessionId",
          details: nil))
        return
      }
      let releaseSequence = args["releaseSequence"] as? Int ?? 0
      let releaseActivationSequence =
        args["releaseActivationSequence"] as? Int ?? 0
      let releaseEdgeUnit = doubleValue(args["releaseEdgeUnit"])
      let displayId = args["displayId"] as? String ?? ""
      let edge = args["edge"] as? String ?? ""
      let routeId = args["routeId"] as? String ?? ""
      let segmentStart = doubleValue(args["segmentStart"])
      let segmentEnd = doubleValue(args["segmentEnd"])
      pauseCapture(
        sessionId: sessionId,
        releaseSequence: releaseSequence,
        releaseActivationSequence: releaseActivationSequence,
        releaseEdgeUnit: releaseEdgeUnit,
        displayId: displayId,
        edge: edge,
        routeId: routeId,
        segmentStart: segmentStart,
        segmentEnd: segmentEnd)
      result(nil)

    case "startInjection":
      guard let args = call.arguments as? [String: Any],
            let sessionId = args["sessionId"] as? String else {
        result(FlutterError(
          code: "bad-arguments",
          message: "startInjection requires sessionId",
          details: nil))
        return
      }
      guard ensureAccessibilityPermission() else {
        openAccessibilitySettings()
        result(FlutterError(
          code: "remote-input-permission-denied",
          message: "需要在系统设置 > 隐私与安全性 > 辅助功能中允许 Whisper Dev，然后重启应用",
          details: nil))
        return
      }
      releaseInjectedMouseButtons()
      releaseInjectedKeys()
      releaseCommonModifierKeys()
      injectedMousePoint = nil
      injectedMouseEnteredInterior = false
      resetInjectedClickState()
      injectedModifierFlags = []
      injectionKeyDiagnosticCount = 0
      injectionMouseDiagnosticCount = 0
      injectionSessionId = sessionId
      injectionDisplayId = args["displayId"] as? String ?? ""
      injectionEdge = args["edge"] as? String ?? ""
      injectionRouteId = ""
      injectionSegmentStart = doubleValue(args["segmentStart"])
      injectionSegmentEnd = doubleValue(args["segmentEnd"])
      injectionRoutes = injectionRoutes(from: args["mappings"])
      showCursorForRemoteInjection(at: nil)
      os_log(
        "remote input injection started session=%{public}@",
        log: remoteInputLog,
        type: .info,
        sessionId)
      emitDiagnostic(message: "mac remote input injection started")
      result(nil)

    case "injectEvent":
      guard let args = call.arguments as? [String: Any],
            let sessionId = args["sessionId"] as? String,
            let eventType = args["eventType"] as? String,
            let payload = payloadData(from: args["payload"]) else {
        result(FlutterError(
          code: "bad-arguments",
          message: "injectEvent requires sessionId, eventType, and payload",
          details: nil))
        return
      }
      injectEvent(
        sessionId: sessionId,
        eventType: eventType,
        payload: payload,
        timestampMicros: int64Value(args["timestampMicros"]))
      result(nil)

    case "stopInjection":
      stopInjection()
      result(nil)

    case "getDisplayTopology":
      result(displayTopology())

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startCapture(
    sessionId: String,
    edge: String,
    displayId: String,
    segmentStart: CGFloat,
    segmentEnd: CGFloat,
    segments: [(start: CGFloat, end: CGFloat)],
    routes: [CaptureRoute],
    releaseHotkey: String,
    result: @escaping FlutterResult
  ) {
    guard ensureAccessibilityPermission() else {
      openAccessibilitySettings()
      result(FlutterError(
        code: "remote-input-permission-denied",
        message: "需要在系统设置 > 隐私与安全性 > 辅助功能中允许 Whisper Dev，然后重启应用",
        details: nil))
      return
    }

    stopCapture()
    captureSessionId = sessionId
    captureEdge = edge
    captureRouteId = ""
    captureDisplayId = displayId
    captureSegmentStart = segmentStart
    captureSegmentEnd = segmentEnd
    captureSegments = segments
    captureRoutes = routes
    self.releaseHotkey = releaseHotkey
    captureActive = false
    captureMouseButtons = 0
    sequence = 0
    captureActivationSequence = 0
    captureActivationEdgeUnit = nil

    let userInfo = Unmanaged.passUnretained(self).toOpaque()
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: remoteInputCaptureEventMask,
      callback: remoteInputEventCallback,
      userInfo: userInfo) else {
      stopCapture()
      result(FlutterError(
        code: "remote-input-capture-unavailable",
        message: "系统仍拒绝键鼠监听；如果辅助功能里已经显示允许，请关闭再打开 Whisper Dev 的辅助功能权限后重启应用，必要时同时检查输入监控权限",
        details: nil))
      return
    }

    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    result(nil)
  }

  private func stopCapture() {
    if let source = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    if let tap = eventTap {
      CGEvent.tapEnable(tap: tap, enable: false)
    }
    runLoopSource = nil
    eventTap = nil
    captureSessionId = ""
    captureDisplayId = ""
    captureRouteId = ""
    captureSegmentStart = 0
    captureSegmentEnd = 0
    captureSegments = []
    captureRoutes = []
    captureActive = false
    captureActivationSequence = 0
    captureMouseButtons = 0
    captureActivationEdgeUnit = nil
    showCaptureCursorIfNeeded()
  }

  private func stopInjection() {
    if !injectionSessionId.isEmpty {
      os_log(
        "remote input injection stopped session=%{public}@",
        log: remoteInputLog,
        type: .info,
        injectionSessionId)
    }
    releaseInjectedMouseButtons()
    releaseInjectedKeys()
    releaseCommonModifierKeys()
    injectedMousePoint = nil
    injectedMouseEnteredInterior = false
    resetInjectedClickState()
    injectedModifierFlags = []
    injectionKeyDiagnosticCount = 0
    injectionMouseDiagnosticCount = 0
    injectionSessionId = ""
    injectionDisplayId = ""
    injectionEdge = ""
    injectionRouteId = ""
    injectionSegmentStart = 0
    injectionSegmentEnd = 0
    injectionRoutes = []
  }

  private func pauseCapture(
    sessionId: String,
    releaseSequence: Int,
    releaseActivationSequence: Int,
    releaseEdgeUnit: CGFloat,
    displayId: String,
    edge: String,
    routeId: String,
    segmentStart: CGFloat,
    segmentEnd: CGFloat
  ) {
    guard sessionId == captureSessionId else {
      return
    }
    guard releaseActivationSequence <= 0 ||
          captureActivationSequence <= releaseActivationSequence else {
      os_log(
        "remote input ignored stale pause releaseSequence=%{public}d releaseActivationSequence=%{public}d nativeSequence=%{public}d activationSequence=%{public}d",
        log: remoteInputLog,
        type: .info,
        releaseSequence,
        releaseActivationSequence,
        sequence,
        captureActivationSequence)
      return
    }
    captureActive = false
    captureActivationSequence = 0
    captureMouseButtons = 0
    if !edge.isEmpty {
      applyCaptureRoute(CaptureRoute(
        routeId: routeId,
        sourceDisplayId: displayId,
        sourceEdge: edge,
        sourceSegmentStart: segmentStart,
        sourceSegmentEnd: segmentEnd))
    }
    moveCaptureCursorToLocalEdge(edgeUnit: releaseEdgeUnit)
    showCaptureCursorIfNeeded()
  }

  fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard !captureSessionId.isEmpty else {
      return false
    }
    if isReleaseHotkey(type: type, event: event) {
      emitCaptureRelease(reason: "hotkey")
      return true
    }
    var activeStart = false
    if !captureActive {
      guard let crossing = captureActivationCrossing(type: type, event: event) else {
        return false
      }
      applyCaptureRoute(crossing.route)
      captureActivationEdgeUnit = crossing.edgeUnit
      captureActive = true
      activeStart = true
      captureActivationSequence = sequence + 1
      hideCaptureCursorIfNeeded()
    }
    prepareCaptureButtonState(type: type)
    guard let encoded = encodePayload(
      type: type,
      event: event,
      activeStart: activeStart
    ) else {
      return true
    }
    if activeStart {
      captureActivationEdgeUnit = nil
    }
    finishCaptureButtonState(type: type)
    sequence += 1
    let eventType = remoteInputEventType(type)
    let arguments: [String: Any] = [
      "sessionId": captureSessionId,
      "sequence": sequence,
      "timestampMicros": Int(Date().timeIntervalSince1970 * 1_000_000),
      "eventType": eventType,
      "payload": FlutterStandardTypedData(bytes: encoded)
    ]
    DispatchQueue.main.async { [channel] in
      channel.invokeMethod("onInputEvent", arguments: arguments)
    }
    pinCaptureCursorIfNeeded(type: type)
    return true
  }

  private func encodePayload(
    type: CGEventType,
    event: CGEvent,
    activeStart: Bool
  ) -> Data? {
    let point = event.location
    var payload: [String: Any] = [:]
    switch remoteInputEventType(type) {
    case "mouseMove":
      let bounds = captureBounds()
      payload = [
        "x": point.x,
        "y": point.y,
        "deltaX": event.getIntegerValueField(.mouseEventDeltaX),
        "deltaY": event.getIntegerValueField(.mouseEventDeltaY),
        "activeStart": activeStart,
        "edge": captureEdge,
        "buttons": captureMouseButtons,
        "unitX": normalized(point.x, start: bounds.minX, length: bounds.width),
        "unitY": normalized(point.y, start: bounds.minY, length: bounds.height)
      ]
      if hasCaptureSegment() {
        let edgeUnit = activeStart
          ? captureActivationEdgeUnit ?? edgeUnitForPoint(
            point,
            edge: captureEdge,
            segmentStart: captureSegmentStart,
            segmentEnd: captureSegmentEnd)
          : edgeUnitForPoint(
            point,
            edge: captureEdge,
            segmentStart: captureSegmentStart,
            segmentEnd: captureSegmentEnd)
        payload["edgeUnit"] = Double(edgeUnit)
      }
      if !captureRouteId.isEmpty {
        payload["routeId"] = captureRouteId
      }
    case "mouseButton":
      payload = [
        "button": buttonNumber(type: type, event: event),
        "down": isButtonDown(type: type),
        "x": point.x,
        "y": point.y,
        "clickCount": max(
          1,
          event.getIntegerValueField(.mouseEventClickState))
      ]
    case "mouseWheel":
      payload = [
        "sourcePlatform": "macos",
        "deltaX": event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
        "deltaY": event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
        "pointDeltaX": event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
        "pointDeltaY": event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
        "fixedDeltaX": event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
        "fixedDeltaY": event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
        "isContinuous": event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
      ]
    case "key":
      let rawMacKeyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
      let macKeyCode = normalizedCapturedMacKeyCode(
        type: type,
        rawKeyCode: rawMacKeyCode)
      let isCapturedCapsLockEvent = type == .flagsChanged && macKeyCode == 57
      payload = [
        "sourcePlatform": "macos",
        "keyCode": macKeyCode,
        "macKeyCode": macKeyCode,
        "windowsKeyCode": windowsVirtualKey(forMacKeyCode: macKeyCode),
        "down": isCapturedCapsLockEvent
          ? true
          : type == .flagsChanged
          ? modifierKeyDown(macKeyCode, flags: event.flags)
          : type == .keyDown
      ]
      if isCapturedCapsLockEvent {
        payload["modifierSemantic"] = "capsLock"
      }
    default:
      payload = [:]
    }
    return try? JSONSerialization.data(withJSONObject: payload, options: [])
  }

  private func remoteInputEventType(_ type: CGEventType) -> String {
    switch type {
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
      return "mouseMove"
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
         .otherMouseDown, .otherMouseUp:
      return "mouseButton"
    case .scrollWheel:
      return "mouseWheel"
    case .keyDown, .keyUp, .flagsChanged:
      return "key"
    default:
      return "release"
    }
  }

  private func buttonNumber(type: CGEventType, event: CGEvent) -> Int64 {
    switch type {
    case .leftMouseDown, .leftMouseUp:
      return 0
    case .rightMouseDown, .rightMouseUp:
      return 1
    default:
      return event.getIntegerValueField(.mouseEventButtonNumber)
    }
  }

  private func isButtonDown(type: CGEventType) -> Bool {
    return type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
  }

  private func injectEvent(
    sessionId: String,
    eventType: String,
    payload: Data,
    timestampMicros: Int64 = 0
  ) {
    guard sessionId == injectionSessionId else {
      os_log(
        "drop remote input event session mismatch event=%{public}@ incoming=%{public}@ active=%{public}@",
        log: remoteInputLog,
        type: .info,
        eventType,
        sessionId,
        injectionSessionId)
      return
    }
    guard let object = try? JSONSerialization.jsonObject(with: payload),
          let data = object as? [String: Any] else {
      os_log(
        "drop remote input event invalid payload event=%{public}@ session=%{public}@",
        log: remoteInputLog,
        type: .info,
        eventType,
        sessionId)
      return
    }

    switch eventType {
    case "mouseMove":
      let deltaX = doubleValue(data["deltaX"])
      let deltaY = doubleValue(data["deltaY"])
      let fallbackPoint = CGPoint(
        x: doubleValue(data["x"]),
        y: doubleValue(data["y"]))
      let entryPoint = entryPointIfNeeded(data)
      if entryPoint != nil {
        injectedMouseEnteredInterior = false
      }
      let currentPoint =
        entryPoint ??
        injectedMousePoint ??
        CGEvent(source: nil)?.location ??
        fallbackPoint
      if entryPoint == nil && injectedMouseEnteredInterior {
        if let releaseRoute = reverseInjectionSourceEdgeUnit(
          currentPoint: currentPoint,
          deltaX: deltaX,
          deltaY: deltaY) {
          emitInjectionRelease(
            reason: "edge",
            edgeUnit: releaseRoute.edgeUnit,
            sourceEdgeUnit: true,
            routeId: releaseRoute.routeId,
            sourceDisplayId: releaseRoute.sourceDisplayId,
            sourceEdge: releaseRoute.sourceEdge,
            sourceSegmentStart: releaseRoute.sourceSegmentStart,
            sourceSegmentEnd: releaseRoute.sourceSegmentEnd)
          return
        }
        if isReverseInjectionRelease(
          data,
          currentPoint: currentPoint,
          deltaX: deltaX,
          deltaY: deltaY
        ) {
          emitInjectionRelease(reason: "edge")
          return
        }
      }
      let shouldMove = entryPoint != nil || deltaX != 0 || deltaY != 0
      let requestedPoint = shouldMove
        ? CGPoint(x: currentPoint.x + deltaX, y: currentPoint.y + deltaY)
        : currentPoint
      let point = clampedInjectedMousePoint(requestedPoint)
      if entryPoint != nil {
        showCursorForRemoteInjection(at: point)
      }
      if data["buttons"] != nil {
        syncInjectedMouseButtons(intValue(data["buttons"]), at: point)
      }
      updateInjectedMouseInteriorState(data, point: point)
      let drag = injectedMouseDragEvent()
      emitMouseDiagnostic(
        eventType: drag.type,
        point: point,
        requestedPoint: requestedPoint,
        currentPoint: currentPoint,
        deltaX: deltaX,
        deltaY: deltaY,
        activeStart: entryPoint != nil,
        edge: data["edge"] as? String ?? "right")
      guard shouldMove else {
        injectedMousePoint = point
        return
      }
      CGEvent(mouseEventSource: nil, mouseType: drag.type, mouseCursorPosition: point, mouseButton: drag.button)?.post(tap: .cghidEventTap)
      injectedMousePoint = point
    case "mouseButton":
      let point = injectedMousePoint ?? CGEvent(source: nil)?.location ?? CGPoint(
        x: doubleValue(data["x"]),
        y: doubleValue(data["y"]))
      let buttonValue = intValue(data["button"])
      let down = boolValue(data["down"])
      let button = cgMouseButton(buttonValue)
      let mouseType: CGEventType
      if button == .right {
        mouseType = down ? .rightMouseDown : .rightMouseUp
      } else if button == .center {
        mouseType = down ? .otherMouseDown : .otherMouseUp
      } else {
        mouseType = down ? .leftMouseDown : .leftMouseUp
      }
      let clickState = injectedClickState(
        button: buttonValue,
        down: down,
        point: point,
        payloadClickCount: intValue(data["clickCount"]),
        timestampMicros: timestampMicros)
      if let event = CGEvent(
        mouseEventSource: nil,
        mouseType: mouseType,
        mouseCursorPosition: point,
        mouseButton: button) {
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.post(tap: .cghidEventTap)
      }
      setInjectedMouseButton(buttonValue, down: down)
      injectedMousePoint = point
    case "mouseWheel":
      let deltaX = Int32(intValue(data["deltaX"]))
      let deltaY = Int32(intValue(data["deltaY"]))
      CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0)?.post(tap: .cghidEventTap)
    case "key":
      let nativeKeyCode = nativeMacKeyCode(data)
      let keyCode = CGKeyCode(nativeKeyCode)
      let down = boolValue(data["down"])
      let semantic =
        data["modifierSemantic"] as? String ?? data["keySemantic"] as? String ?? ""
      os_log(
        "remote key inject session=%{public}@ down=%{public}d nativeMac=%{public}d keyCode=%{public}d mac=%{public}d win=%{public}d linux=%{public}d semantic=%{public}@ injectedFlags=%{public}llu",
        log: remoteInputLog,
        type: .info,
        sessionId,
        down ? 1 : 0,
        nativeKeyCode,
        intValue(data["keyCode"]),
        intValue(data["macKeyCode"]),
        intValue(data["windowsKeyCode"]),
        intValue(data["linuxKeyCode"]),
        semantic,
        injectedModifierFlags.rawValue)
      emitKeyDiagnostic(
        message: "mac remote key inject down=\(down ? 1 : 0) nativeMac=\(nativeKeyCode) keyCode=\(intValue(data["keyCode"])) mac=\(intValue(data["macKeyCode"])) win=\(intValue(data["windowsKeyCode"])) linux=\(intValue(data["linuxKeyCode"])) semantic=\(semantic) flags=\(injectedModifierFlags.rawValue)")
      if isCapsLockInputSourceSwitch(nativeKeyCode: nativeKeyCode, semantic: semantic) {
        if down {
          toggleKeyboardInputSource()
        }
        return
      }
      updateInjectedModifierFlags(macKeyCode: nativeKeyCode, down: down)
      postKeyboardEvent(keyCode: keyCode, down: down)
      setInjectedKey(nativeKeyCode, down: down)
    default:
      break
    }
  }

  private func payloadData(from value: Any?) -> Data? {
    if let typedData = value as? FlutterStandardTypedData {
      return typedData.data
    }
    if let data = value as? Data {
      return data
    }
    return nil
  }

  private func doubleValue(_ value: Any?) -> CGFloat {
    if let number = value as? NSNumber {
      return CGFloat(number.doubleValue)
    }
    if let value = value as? Double {
      return CGFloat(value)
    }
    if let value = value as? Int {
      return CGFloat(value)
    }
    return 0
  }

  private func captureSegments(from value: Any?) -> [(start: CGFloat, end: CGFloat)] {
    guard let items = value as? [Any] else {
      return []
    }
    return items.compactMap { item in
      guard let item = item as? [String: Any] else {
        return nil
      }
      let start = doubleValue(item["start"])
      let end = doubleValue(item["end"])
      return end > start ? (start: start, end: end) : nil
    }
  }

  private func captureRoutes(from value: Any?) -> [CaptureRoute] {
    guard let items = value as? [Any] else {
      return []
    }
    return items.compactMap { item in
      guard let item = item as? [String: Any] else {
        return nil
      }
      let displayId = item["displayId"] as? String ?? ""
      let edge = item["edge"] as? String ?? ""
      let routeId = item["routeId"] as? String ?? ""
      let start = doubleValue(item["start"])
      let end = doubleValue(item["end"])
      guard !edge.isEmpty, end > start else {
        return nil
      }
      return CaptureRoute(
        routeId: routeId,
        sourceDisplayId: displayId,
        sourceEdge: edge,
        sourceSegmentStart: start,
        sourceSegmentEnd: end)
    }
  }

  private func injectionRoutes(from value: Any?) -> [InjectionRoute] {
    guard let items = value as? [Any] else {
      return []
    }
    return items.compactMap { item in
      guard let item = item as? [String: Any] else {
        return nil
      }
      let sourceDisplayId = item["sourceDisplayId"] as? String ?? ""
      let sourceEdge = item["sourceEdge"] as? String ?? ""
      let routeId = item["routeId"] as? String ?? ""
      let sinkDisplayId = item["sinkDisplayId"] as? String ?? ""
      let sinkEdge = item["sinkEdge"] as? String ?? ""
      let sinkSegmentStart = doubleValue(item["sinkSegmentStart"])
      let sinkSegmentEnd = doubleValue(item["sinkSegmentEnd"])
      let sourceSegmentStart = doubleValue(item["sourceSegmentStart"])
      let sourceSegmentEnd = doubleValue(item["sourceSegmentEnd"])
      guard !sourceEdge.isEmpty,
            !sinkDisplayId.isEmpty,
            !sinkEdge.isEmpty,
            sinkSegmentEnd > sinkSegmentStart,
            sourceSegmentEnd > sourceSegmentStart else {
        return nil
      }
      return InjectionRoute(
        routeId: routeId,
        sourceDisplayId: sourceDisplayId,
        sourceEdge: sourceEdge,
        sinkDisplayId: sinkDisplayId,
        sinkEdge: sinkEdge,
        sinkSegmentStart: sinkSegmentStart,
        sinkSegmentEnd: sinkSegmentEnd,
        sourceSegmentStart: sourceSegmentStart,
        sourceSegmentEnd: sourceSegmentEnd)
    }
  }

  private func intValue(_ value: Any?) -> Int {
    if let number = value as? NSNumber {
      return number.intValue
    }
    if let value = value as? Int {
      return value
    }
    return 0
  }

  private func int64Value(_ value: Any?) -> Int64 {
    if let number = value as? NSNumber {
      return number.int64Value
    }
    if let value = value as? Int64 {
      return value
    }
    if let value = value as? Int {
      return Int64(value)
    }
    return 0
  }

  private func boolValue(_ value: Any?) -> Bool {
    if let number = value as? NSNumber {
      return number.boolValue
    }
    if let value = value as? Bool {
      return value
    }
    return false
  }

  private func nativeMacKeyCode(_ data: [String: Any]) -> Int {
    let nativeKeyCode = intValue(data["macKeyCode"])
    if nativeKeyCode > 0 || data["macKeyCode"] != nil {
      return nativeKeyCode
    }
    let windowsKeyCode = intValue(data["windowsKeyCode"])
    if windowsKeyCode > 0 {
      return macKeyCode(forWindowsVirtualKey: windowsKeyCode)
    }
    return intValue(data["keyCode"])
  }

  private func entryPointIfNeeded(_ data: [String: Any]) -> CGPoint? {
    guard boolValue(data["activeStart"]) else {
      return nil
    }
    updateInjectionRoute(from: data)
    if hasInjectionSegment(),
       !injectionEdge.isEmpty,
       data["edgeUnit"] != nil {
      let edgeUnit = clampedUnit(doubleValue(data["edgeUnit"]))
      return edgePoint(
        bounds: injectionBounds(),
        edge: injectionEdge,
        edgeUnit: edgeUnit,
        segmentStart: injectionSegmentStart,
        segmentEnd: injectionSegmentEnd)
    }
    let bounds = virtualDisplayBounds()
    let edge = data["edge"] as? String ?? "right"
    let unitX = clampedUnit(doubleValue(data["unitX"]))
    let unitY = clampedUnit(doubleValue(data["unitY"]))
    let inset: CGFloat = 2
    let mappedX = min(bounds.maxX - inset, max(bounds.minX + inset, bounds.minX + bounds.width * unitX))
    let mappedY = min(bounds.maxY - inset, max(bounds.minY + inset, bounds.minY + bounds.height * unitY))
    switch edge {
    case "left":
      return CGPoint(x: bounds.maxX - inset, y: mappedY)
    case "top":
      return CGPoint(x: mappedX, y: bounds.maxY - inset)
    case "bottom":
      return CGPoint(x: mappedX, y: bounds.minY + inset)
    case "right":
      fallthrough
    default:
      return CGPoint(x: bounds.minX + inset, y: mappedY)
    }
  }

  private func updateInjectionRoute(from data: [String: Any]) {
    guard let sinkEdge = data["sinkEdge"] as? String,
          !sinkEdge.isEmpty else {
      return
    }
    injectionDisplayId = data["sinkDisplayId"] as? String ?? injectionDisplayId
    injectionEdge = sinkEdge
    injectionRouteId = data["routeId"] as? String ?? injectionRouteId
    injectionSegmentStart = doubleValue(data["sinkSegmentStart"])
    injectionSegmentEnd = doubleValue(data["sinkSegmentEnd"])
  }

  private func virtualDisplayBounds() -> CGRect {
    var bounds = CGRect.null
    for screen in NSScreen.screens {
      let frame = cgDisplayBounds(displayId: screenDisplayId(screen)) ?? screen.frame
      bounds = bounds.union(frame)
    }
    if bounds.isNull || bounds.isEmpty {
      return CGDisplayBounds(CGMainDisplayID())
    }
    return bounds
  }

  private func displayTopology() -> [String: Any] {
    let displays = NSScreen.screens.map { screen -> [String: Any] in
      let displayId = screenDisplayId(screen)
      let frame = cgDisplayBounds(displayId: displayId) ?? screen.frame
      return [
        "displayId": displayId,
        "name": screenName(screen),
        "x": Int(frame.origin.x.rounded()),
        "y": Int(frame.origin.y.rounded()),
        "width": max(1, Int(frame.width.rounded())),
        "height": max(1, Int(frame.height.rounded())),
        "scale": Double(screen.backingScaleFactor),
        "isPrimary": isMainDisplay(displayId: displayId, screen: screen)
      ]
    }
    return [
      "platform": "macos",
      "updatedAt": Int(Date().timeIntervalSince1970 * 1000),
      "displays": displays
    ]
  }

  private func screenDisplayId(_ screen: NSScreen) -> String {
    if let number = screen.deviceDescription[
      NSDeviceDescriptionKey("NSScreenNumber")
    ] as? NSNumber {
      return "\(number.uint32Value)"
    }
    return "\(Int(screen.frame.origin.x)):\(Int(screen.frame.origin.y)):\(Int(screen.frame.width))x\(Int(screen.frame.height))"
  }

  private func screenName(_ screen: NSScreen) -> String {
    if #available(macOS 10.15, *) {
      return screen.localizedName
    }
    return screenDisplayId(screen)
  }

  private func cgDisplayBounds(displayId: String) -> CGRect? {
    guard let id = UInt32(displayId) else {
      return nil
    }
    let bounds = CGDisplayBounds(id)
    if bounds.isNull || bounds.isEmpty {
      return nil
    }
    return bounds
  }

  private func isMainDisplay(displayId: String, screen: NSScreen) -> Bool {
    if let id = UInt32(displayId) {
      return CGDisplayIsMain(id) != 0
    }
    return screen.isEqual(NSScreen.main)
  }

  private func screenBounds(displayId: String) -> CGRect? {
    guard !displayId.isEmpty else {
      return nil
    }
    if let bounds = cgDisplayBounds(displayId: displayId) {
      return bounds
    }
    for screen in NSScreen.screens where screenDisplayId(screen) == displayId {
      return screen.frame
    }
    return nil
  }

  private func captureBounds() -> CGRect {
    return screenBounds(displayId: captureDisplayId) ?? virtualDisplayBounds()
  }

  private func injectionBounds() -> CGRect {
    return screenBounds(displayId: injectionDisplayId) ?? virtualDisplayBounds()
  }

  private func hasCaptureSegment() -> Bool {
    return captureSegmentEnd > captureSegmentStart
  }

  private func pointWithinCaptureSegments(
    _ point: CGPoint,
    tolerance: CGFloat = 0
  ) -> Bool {
    if captureSegments.isEmpty {
      return !hasCaptureSegment() || pointWithinSegment(
        point,
        edge: captureEdge,
        segmentStart: captureSegmentStart,
        segmentEnd: captureSegmentEnd,
        tolerance: tolerance)
    }
    let value = axisValue(point, edge: captureEdge)
    return captureSegments.contains { segment in
      value >= segment.start - tolerance && value <= segment.end + tolerance
    }
  }

  private func hasInjectionSegment() -> Bool {
    return injectionSegmentEnd > injectionSegmentStart
  }

  private func clampedInjectedMousePoint(_ point: CGPoint) -> CGPoint {
    let bounds = virtualDisplayBounds()
    let inset: CGFloat = 2
    return CGPoint(
      x: min(bounds.maxX - inset, max(bounds.minX + inset, point.x)),
      y: min(bounds.maxY - inset, max(bounds.minY + inset, point.y)))
  }

  private func normalized(_ value: CGFloat, start: CGFloat, length: CGFloat) -> CGFloat {
    if length <= 0 {
      return 0
    }
    return clampedUnit((value - start) / length)
  }

  private func clampedUnit(_ value: CGFloat) -> CGFloat {
    return min(1, max(0, value))
  }

  private func axisValue(_ point: CGPoint, edge: String) -> CGFloat {
    if edge == "left" || edge == "right" {
      return point.y
    }
    return point.x
  }

  private func segmentCoordinate(
    edgeUnit: CGFloat,
    segmentStart: CGFloat,
    segmentEnd: CGFloat
  ) -> CGFloat {
    return segmentStart + (segmentEnd - segmentStart) * clampedUnit(edgeUnit)
  }

  private func pointWithinSegment(
    _ point: CGPoint,
    edge: String,
    segmentStart: CGFloat,
    segmentEnd: CGFloat,
    tolerance: CGFloat = 0
  ) -> Bool {
    guard segmentEnd > segmentStart else {
      return true
    }
    let value = axisValue(point, edge: edge)
    return value >= segmentStart - tolerance && value <= segmentEnd + tolerance
  }

  private func edgeUnitForPoint(
    _ point: CGPoint,
    edge: String,
    segmentStart: CGFloat,
    segmentEnd: CGFloat
  ) -> CGFloat {
    guard segmentEnd > segmentStart else {
      return 0
    }
    return clampedUnit(
      (axisValue(point, edge: edge) - segmentStart) /
      (segmentEnd - segmentStart))
  }

  private func edgePoint(
    bounds: CGRect,
    edge: String,
    edgeUnit: CGFloat,
    segmentStart: CGFloat,
    segmentEnd: CGFloat
  ) -> CGPoint {
    let inset: CGFloat = 2
    let coordinate = segmentCoordinate(
      edgeUnit: edgeUnit,
      segmentStart: segmentStart,
      segmentEnd: segmentEnd)
    switch edge {
    case "left":
      return CGPoint(
        x: bounds.minX + inset,
        y: min(bounds.maxY - inset, max(bounds.minY + inset, coordinate)))
    case "right":
      return CGPoint(
        x: bounds.maxX - inset,
        y: min(bounds.maxY - inset, max(bounds.minY + inset, coordinate)))
    case "top":
      return CGPoint(
        x: min(bounds.maxX - inset, max(bounds.minX + inset, coordinate)),
        y: bounds.minY + inset)
    case "bottom":
      return CGPoint(
        x: min(bounds.maxX - inset, max(bounds.minX + inset, coordinate)),
        y: bounds.maxY - inset)
    default:
      return CGPoint(
        x: bounds.minX + inset,
        y: min(bounds.maxY - inset, max(bounds.minY + inset, coordinate)))
    }
  }

  private func cgMouseButton(_ button: Int) -> CGMouseButton {
    switch button {
    case 1:
      return .right
    case 2:
      return .center
    default:
      return .left
    }
  }

  private func mouseButtonBit(_ button: Int) -> Int {
    switch button {
    case 1:
      return 2
    case 2:
      return 4
    default:
      return 1
    }
  }

  private func prepareCaptureButtonState(type: CGEventType) {
    switch type {
    case .leftMouseDown, .leftMouseDragged:
      captureMouseButtons |= mouseButtonBit(0)
    case .rightMouseDown, .rightMouseDragged:
      captureMouseButtons |= mouseButtonBit(1)
    case .otherMouseDown, .otherMouseDragged:
      captureMouseButtons |= mouseButtonBit(2)
    default:
      break
    }
  }

  private func finishCaptureButtonState(type: CGEventType) {
    switch type {
    case .leftMouseUp:
      captureMouseButtons &= ~mouseButtonBit(0)
    case .rightMouseUp:
      captureMouseButtons &= ~mouseButtonBit(1)
    case .otherMouseUp:
      captureMouseButtons &= ~mouseButtonBit(2)
    default:
      break
    }
  }

  private func modifierKeyDown(_ keyCode: Int, flags: CGEventFlags) -> Bool {
    switch keyCode {
    case 54, 55:
      return flags.contains(.maskCommand)
    case 56, 60:
      return flags.contains(.maskShift)
    case 58, 61:
      return flags.contains(.maskAlternate)
    case 59, 62:
      return flags.contains(.maskControl)
    case 57:
      return flags.contains(.maskAlphaShift)
    default:
      return false
    }
  }

  private func normalizedCapturedMacKeyCode(type: CGEventType, rawKeyCode: Int) -> Int {
    if type == .flagsChanged && rawKeyCode == 255 {
      return 57
    }
    return rawKeyCode
  }

  private func modifierFlag(forMacKeyCode keyCode: Int) -> CGEventFlags? {
    switch keyCode {
    case 54, 55:
      return .maskCommand
    case 56, 60:
      return .maskShift
    case 58, 61:
      return .maskAlternate
    case 59, 62:
      return .maskControl
    case 57:
      return .maskAlphaShift
    default:
      return nil
    }
  }

  private func updateInjectedModifierFlags(macKeyCode: Int, down: Bool) {
    guard macKeyCode != 57,
          let flag = modifierFlag(forMacKeyCode: macKeyCode) else {
      return
    }
    if down {
      injectedModifierFlags.insert(flag)
    } else {
      injectedModifierFlags.remove(flag)
    }
  }

  private func isInjectedModifierKey(_ keyCode: Int) -> Bool {
    return keyCode != 57 && modifierFlag(forMacKeyCode: keyCode) != nil
  }

  private func isCapsLockInputSourceSwitch(nativeKeyCode: Int, semantic: String) -> Bool {
    return nativeKeyCode == 57 || semantic == "capsLock"
  }

  private func toggleKeyboardInputSource() {
    guard let sources = selectableKeyboardInputSources(), !sources.isEmpty else {
      emitDiagnostic(message: "mac caps input source switch skipped no candidates")
      os_log(
        "remote caps input source switch skipped no candidates",
        log: remoteInputLog,
        type: .info)
      return
    }

    let currentId = currentKeyboardInputSourceId()
    let currentIndex: Int
    if let currentId = currentId,
       let index = sources.firstIndex(where: {
         inputSourceStringProperty($0, kTISPropertyInputSourceID) == currentId
       }) {
      currentIndex = index
    } else {
      currentIndex = -1
    }

    let nextSource = sources[(currentIndex + 1) % sources.count]
    let nextId = inputSourceStringProperty(nextSource, kTISPropertyInputSourceID)
    let status = TISSelectInputSource(nextSource)
    emitDiagnostic(
      message: "mac caps input source switched current=\(currentId ?? "") next=\(nextId) status=\(status) candidates=\(sources.count)")
    os_log(
      "remote caps input source switched current=%{public}@ next=%{public}@ status=%{public}d",
      log: remoteInputLog,
      type: .info,
      currentId ?? "",
      nextId,
      status)
  }

  private func selectableKeyboardInputSources() -> [TISInputSource]? {
    guard let rawSources = TISCreateInputSourceList(nil, false)?
      .takeRetainedValue() as? [TISInputSource] else {
      return nil
    }
    return rawSources.filter {
      inputSourceBoolProperty($0, kTISPropertyInputSourceIsSelectCapable) &&
        inputSourceBoolProperty($0, kTISPropertyInputSourceIsEnabled) &&
        inputSourceStringProperty($0, kTISPropertyInputSourceCategory) ==
          kTISCategoryKeyboardInputSource as String
    }
  }

  private func currentKeyboardInputSourceId() -> String? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
      return nil
    }
    let sourceId = inputSourceStringProperty(source, kTISPropertyInputSourceID)
    return sourceId.isEmpty ? nil : sourceId
  }

  private func inputSourceBoolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let value = TISGetInputSourceProperty(source, key) else {
      return false
    }
    return Unmanaged<CFBoolean>
      .fromOpaque(value)
      .takeUnretainedValue() == kCFBooleanTrue
  }

  private func inputSourceStringProperty(_ source: TISInputSource, _ key: CFString) -> String {
    guard let value = TISGetInputSourceProperty(source, key) else {
      return ""
    }
    return Unmanaged<CFString>
      .fromOpaque(value)
      .takeUnretainedValue() as String
  }

  private func emitKeyDiagnostic(message: String) {
    guard injectionKeyDiagnosticCount < 40 else {
      return
    }
    injectionKeyDiagnosticCount += 1
    emitDiagnostic(message: message)
  }

  private func emitMouseDiagnostic(
    eventType: CGEventType,
    point: CGPoint,
    requestedPoint: CGPoint,
    currentPoint: CGPoint,
    deltaX: CGFloat,
    deltaY: CGFloat,
    activeStart: Bool,
    edge: String
  ) {
    guard injectionMouseDiagnosticCount < 40 else {
      return
    }
    injectionMouseDiagnosticCount += 1
    let bounds = virtualDisplayBounds()
    let livePoint = CGEvent(source: nil)?.location ?? CGPoint.zero
    os_log(
      "mac remote mouse inject type=%{public}d activeStart=%{public}d edge=%{public}@ current=%{public}d,%{public}d point=%{public}d,%{public}d requested=%{public}d,%{public}d live=%{public}d,%{public}d delta=%{public}d,%{public}d bounds=%{public}d,%{public}d,%{public}d,%{public}d",
      log: remoteInputLog,
      type: .info,
      eventType.rawValue,
      activeStart ? 1 : 0,
      edge,
      Int(currentPoint.x),
      Int(currentPoint.y),
      Int(point.x),
      Int(point.y),
      Int(requestedPoint.x),
      Int(requestedPoint.y),
      Int(livePoint.x),
      Int(livePoint.y),
      Int(deltaX),
      Int(deltaY),
      Int(bounds.minX),
      Int(bounds.minY),
      Int(bounds.width),
      Int(bounds.height))
    emitDiagnostic(
      message:
        "mac remote mouse inject type=\(eventType.rawValue) activeStart=\(activeStart ? 1 : 0) edge=\(edge) current=\(Int(currentPoint.x)),\(Int(currentPoint.y)) point=\(Int(point.x)),\(Int(point.y)) requested=\(Int(requestedPoint.x)),\(Int(requestedPoint.y)) live=\(Int(livePoint.x)),\(Int(livePoint.y)) delta=\(Int(deltaX)),\(Int(deltaY)) bounds=\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))")
  }

  private func emitDiagnostic(message: String) {
    guard !injectionSessionId.isEmpty else {
      return
    }
    NSLog("remote input diagnostic: %@", message)
    let arguments: [String: Any] = [
      "sessionId": injectionSessionId,
      "message": message
    ]
    DispatchQueue.main.async { [channel] in
      channel.invokeMethod("onDiagnostic", arguments: arguments)
    }
  }

  private func postKeyboardEvent(keyCode: CGKeyCode, down: Bool) {
    if let keyEvent = CGEvent(keyboardEventSource: keyboardEventSource, virtualKey: keyCode, keyDown: down) {
      let isModifier = isInjectedModifierKey(Int(keyCode))
      if isModifier {
        keyEvent.type = .flagsChanged
        keyEvent.flags = keyEvent.flags.union(injectedModifierFlags)
      } else {
        keyEvent.flags = keyEvent.flags.union(injectedModifierFlags)
      }
      let eventType = isModifier ? "flagsChanged" : (down ? "keyDown" : "keyUp")
      os_log(
        "post remote key mac=%{public}d down=%{public}d type=%{public}@ flags=%{public}llu tap=%{public}@",
        log: remoteInputLog,
        type: .info,
        Int(keyCode),
        down ? 1 : 0,
        eventType,
        keyEvent.flags.rawValue,
        "hid")
      emitKeyDiagnostic(
        message: "mac post remote key mac=\(Int(keyCode)) down=\(down ? 1 : 0) type=\(eventType) flags=\(keyEvent.flags.rawValue) tap=hid")
      keyEvent.post(tap: .cghidEventTap)
    }
  }

  private func setInjectedKey(_ keyCode: Int, down: Bool) {
    if down {
      if !injectedKeyCodes.contains(keyCode) {
        injectedKeyCodes.append(keyCode)
      }
    } else {
      injectedKeyCodes.removeAll { $0 == keyCode }
    }
  }

  private func releaseInjectedKeys() {
    guard !injectedKeyCodes.isEmpty else {
      return
    }
    let keyCodes = injectedKeyCodes.reversed()
    injectedKeyCodes.removeAll()
    for keyCode in keyCodes {
      updateInjectedModifierFlags(macKeyCode: keyCode, down: false)
      postKeyboardEvent(keyCode: CGKeyCode(keyCode), down: false)
    }
    injectedModifierFlags = []
  }

  private func releaseCommonModifierKeys() {
    for keyCode in [54, 55, 56, 60, 58, 61, 59, 62] {
      updateInjectedModifierFlags(macKeyCode: keyCode, down: false)
      postKeyboardEvent(keyCode: CGKeyCode(keyCode), down: false)
    }
    injectedModifierFlags = []
  }

  private func setInjectedMouseButton(_ button: Int, down: Bool) {
    let bit = mouseButtonBit(button)
    if down {
      injectedMouseButtons |= bit
    } else {
      injectedMouseButtons &= ~bit
    }
  }

  private func resetInjectedClickState() {
    injectedLastClickButton = -1
    injectedLastClickTimeMicros = 0
    injectedLastClickPoint = CGPoint.zero
    injectedCurrentClickCount = 1
  }

  private func currentTimeMicros() -> Int64 {
    return Int64(Date().timeIntervalSince1970 * 1_000_000)
  }

  private func injectedClickState(
    button: Int,
    down: Bool,
    point: CGPoint,
    payloadClickCount: Int,
    timestampMicros: Int64
  ) -> Int64 {
    if !down {
      if button == injectedLastClickButton {
        return Int64(max(1, injectedCurrentClickCount))
      }
      return 1
    }

    let eventTimeMicros =
      timestampMicros > 0 ? timestampMicros : currentTimeMicros()
    let payloadState = max(0, payloadClickCount)
    let clickCount: Int
    if payloadState > 0 {
      clickCount = min(payloadState, 2)
    } else if isInjectedDoubleClickCandidate(
      button: button,
      point: point,
      timestampMicros: eventTimeMicros) {
      clickCount = min(injectedCurrentClickCount + 1, 2)
    } else {
      clickCount = 1
    }

    injectedLastClickButton = button
    injectedLastClickTimeMicros = eventTimeMicros
    injectedLastClickPoint = point
    injectedCurrentClickCount = clickCount
    return Int64(clickCount)
  }

  private func isInjectedDoubleClickCandidate(
    button: Int,
    point: CGPoint,
    timestampMicros: Int64
  ) -> Bool {
    guard button == injectedLastClickButton,
          injectedLastClickTimeMicros > 0 else {
      return false
    }
    let elapsedSeconds =
      Double(timestampMicros - injectedLastClickTimeMicros) / 1_000_000.0
    guard elapsedSeconds >= 0 &&
          elapsedSeconds <= NSEvent.doubleClickInterval else {
      return false
    }
    let distanceX = point.x - injectedLastClickPoint.x
    let distanceY = point.y - injectedLastClickPoint.y
    return distanceX * distanceX + distanceY * distanceY <= 64
  }

  private func syncInjectedMouseButtons(_ desired: Int, at point: CGPoint) {
    syncInjectedMouseButton(button: 0, desired: desired, at: point)
    syncInjectedMouseButton(button: 1, desired: desired, at: point)
    syncInjectedMouseButton(button: 2, desired: desired, at: point)
  }

  private func syncInjectedMouseButton(button: Int, desired: Int, at point: CGPoint) {
    let bit = mouseButtonBit(button)
    let shouldBeDown = (desired & bit) != 0
    let isDown = (injectedMouseButtons & bit) != 0
    guard shouldBeDown != isDown else {
      return
    }
    let cgButton = cgMouseButton(button)
    let eventType: CGEventType
    if cgButton == .right {
      eventType = shouldBeDown ? .rightMouseDown : .rightMouseUp
    } else if cgButton == .center {
      eventType = shouldBeDown ? .otherMouseDown : .otherMouseUp
    } else {
      eventType = shouldBeDown ? .leftMouseDown : .leftMouseUp
    }
    CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: point, mouseButton: cgButton)?.post(tap: .cghidEventTap)
    setInjectedMouseButton(button, down: shouldBeDown)
  }

  private func injectedMouseDragEvent() -> (type: CGEventType, button: CGMouseButton) {
    if (injectedMouseButtons & 1) != 0 {
      return (.leftMouseDragged, .left)
    }
    if (injectedMouseButtons & 2) != 0 {
      return (.rightMouseDragged, .right)
    }
    if (injectedMouseButtons & 4) != 0 {
      return (.otherMouseDragged, .center)
    }
    return (.mouseMoved, .left)
  }

  private func releaseInjectedMouseButtons() {
    guard injectedMouseButtons != 0 else {
      return
    }
    let point = injectedMousePoint ?? CGEvent(source: nil)?.location ?? CGPoint.zero
    syncInjectedMouseButtons(0, at: point)
  }

  private func windowsVirtualKey(forMacKeyCode keyCode: Int) -> Int {
    switch keyCode {
    case 0: return 0x41
    case 1: return 0x53
    case 2: return 0x44
    case 3: return 0x46
    case 4: return 0x48
    case 5: return 0x47
    case 6: return 0x5A
    case 7: return 0x58
    case 8: return 0x43
    case 9: return 0x56
    case 11: return 0x42
    case 12: return 0x51
    case 13: return 0x57
    case 14: return 0x45
    case 15: return 0x52
    case 16: return 0x59
    case 17: return 0x54
    case 18: return 0x31
    case 19: return 0x32
    case 20: return 0x33
    case 21: return 0x34
    case 22: return 0x36
    case 23: return 0x35
    case 24: return 0xBB
    case 25: return 0x39
    case 26: return 0x37
    case 27: return 0xBD
    case 28: return 0x38
    case 29: return 0x30
    case 30: return 0xDD
    case 31: return 0x4F
    case 32: return 0x55
    case 33: return 0xDB
    case 34: return 0x49
    case 35: return 0x50
    case 36: return 0x0D
    case 37: return 0x4C
    case 38: return 0x4A
    case 39: return 0xDE
    case 40: return 0x4B
    case 41: return 0xBA
    case 42: return 0xDC
    case 43: return 0xBC
    case 44: return 0xBF
    case 45: return 0x4E
    case 46: return 0x4D
    case 47: return 0xBE
    case 48: return 0x09
    case 49: return 0x20
    case 50: return 0xC0
    case 51: return 0x08
    case 53: return 0x1B
    case 57: return 0x14
    case 54: return 0x5C
    case 55: return 0x5B
    case 59: return 0xA2
    case 62: return 0xA3
    case 56, 60: return 0x10
    case 58, 61: return 0x12
    case 117: return 0x2E
    case 123: return 0x25
    case 124: return 0x27
    case 125: return 0x28
    case 126: return 0x26
    default: return keyCode
    }
  }

  private func macKeyCode(forWindowsVirtualKey virtualKey: Int) -> Int {
    switch virtualKey {
    case 0x41: return 0
    case 0x53: return 1
    case 0x44: return 2
    case 0x46: return 3
    case 0x48: return 4
    case 0x47: return 5
    case 0x5A: return 6
    case 0x58: return 7
    case 0x43: return 8
    case 0x56: return 9
    case 0x42: return 11
    case 0x51: return 12
    case 0x57: return 13
    case 0x45: return 14
    case 0x52: return 15
    case 0x59: return 16
    case 0x54: return 17
    case 0x31: return 18
    case 0x32: return 19
    case 0x33: return 20
    case 0x34: return 21
    case 0x36: return 22
    case 0x35: return 23
    case 0xBB: return 24
    case 0x39: return 25
    case 0x37: return 26
    case 0xBD: return 27
    case 0x38: return 28
    case 0x30: return 29
    case 0xDD: return 30
    case 0x4F: return 31
    case 0x55: return 32
    case 0xDB: return 33
    case 0x49: return 34
    case 0x50: return 35
    case 0x0D: return 36
    case 0x4C: return 37
    case 0x4A: return 38
    case 0xDE: return 39
    case 0x4B: return 40
    case 0xBA: return 41
    case 0xDC: return 42
    case 0xBC: return 43
    case 0xBF: return 44
    case 0x4E: return 45
    case 0x4D: return 46
    case 0xBE: return 47
    case 0x09: return 48
    case 0x20: return 49
    case 0xC0: return 50
    case 0x08: return 51
    case 0x1B: return 53
    case 0x14: return 57
    case 0x11, 0xA2: return 59
    case 0xA3: return 62
    case 0x5B: return 55
    case 0x5C: return 54
    case 0x10: return 56
    case 0x12: return 58
    case 0x2E: return 117
    case 0x25: return 123
    case 0x27: return 124
    case 0x28: return 125
    case 0x26: return 126
    default: return virtualKey
    }
  }

  private func ensureAccessibilityPermission() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  private func openAccessibilitySettings() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  private func isReleaseHotkey(type: CGEventType, event: CGEvent) -> Bool {
    guard releaseHotkey.lowercased() == "ctrl+alt+esc",
          type == .keyDown else {
      return false
    }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    return keyCode == 53 &&
      flags.contains(.maskControl) &&
      flags.contains(.maskAlternate)
  }

  private func captureActivationCrossing(
    type: CGEventType,
    event: CGEvent
  ) -> CaptureCrossing? {
    switch type {
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
      let point = event.location
      let deltaX = event.getIntegerValueField(.mouseEventDeltaX)
      let deltaY = event.getIntegerValueField(.mouseEventDeltaY)
      let previousPoint = CGPoint(
        x: point.x - CGFloat(deltaX),
        y: point.y - CGFloat(deltaY))
      let routes = captureRoutes.isEmpty ? [CaptureRoute(
        routeId: captureRouteId,
        sourceDisplayId: captureDisplayId,
        sourceEdge: captureEdge,
        sourceSegmentStart: captureSegmentStart,
        sourceSegmentEnd: captureSegmentEnd)] : captureRoutes
      return resolveCaptureCrossing(
        previousPoint: previousPoint,
        currentPoint: point,
        routes: routes)
    default:
      return nil
    }
  }

  private func isEdgeActivationEvent(type: CGEventType, event: CGEvent) -> Bool {
    return captureActivationCrossing(type: type, event: event) != nil
  }

  private func applyCaptureRoute(_ route: CaptureRoute) {
    captureRouteId = route.routeId
    captureDisplayId = route.sourceDisplayId
    captureEdge = route.sourceEdge
    captureSegmentStart = route.sourceSegmentStart
    captureSegmentEnd = route.sourceSegmentEnd
  }

  private func resolveCaptureCrossing(
    previousPoint: CGPoint,
    currentPoint: CGPoint,
    routes: [CaptureRoute]
  ) -> CaptureCrossing? {
    let candidates = routes.compactMap { route in
      captureCrossing(
        route: route,
        previousPoint: previousPoint,
        currentPoint: currentPoint,
        routes: routes)
    }
    return rankedCaptureCrossing(candidates)
  }

  private func captureCrossing(
    route: CaptureRoute,
    previousPoint: CGPoint,
    currentPoint: CGPoint,
    routes: [CaptureRoute]
  ) -> CaptureCrossing? {
    let bounds = screenBounds(displayId: route.sourceDisplayId) ??
      virtualDisplayBounds()
    let line = edgeLine(bounds: bounds, edge: route.sourceEdge)
    let deltaX = currentPoint.x - previousPoint.x
    let deltaY = currentPoint.y - previousPoint.y
    guard deltaX != 0 || deltaY != 0,
          let t = intersectionParameter(
            edge: route.sourceEdge,
            line: line,
            previousPoint: previousPoint,
            deltaX: deltaX,
            deltaY: deltaY),
          t >= 0,
          t <= 1 else {
      return nil
    }
    let normalMotion = edgeNormalMotion(
      edge: route.sourceEdge,
      deltaX: deltaX,
      deltaY: deltaY)
    guard normalMotion > 0 else {
      return nil
    }
    let intersection = CGPoint(
      x: previousPoint.x + deltaX * t,
      y: previousPoint.y + deltaY * t)
    let coordinate = axisCoordinate(point: intersection, edge: route.sourceEdge)
    guard segmentContains(
      coordinate: coordinate,
      start: route.sourceSegmentStart,
      end: route.sourceSegmentEnd,
      displayId: route.sourceDisplayId,
      edge: route.sourceEdge,
      captureRoutes: routes) else {
      return nil
    }
    let length = route.sourceSegmentEnd - route.sourceSegmentStart
    guard length > 0 else {
      return nil
    }
    let edgeUnit = min(1, max(0, (coordinate - route.sourceSegmentStart) / length))
    return CaptureCrossing(
      route: route,
      edgeUnit: edgeUnit,
      strictSegmentHit: coordinate > route.sourceSegmentStart &&
        coordinate < route.sourceSegmentEnd,
      normalMotion: normalMotion,
      travelToIntersection: hypot(
        intersection.x - previousPoint.x,
        intersection.y - previousPoint.y))
  }

  private func rankedCaptureCrossing(_ candidates: [CaptureCrossing]) -> CaptureCrossing? {
    return candidates.sorted { lhs, rhs in
      if lhs.strictSegmentHit != rhs.strictSegmentHit {
        return lhs.strictSegmentHit
      }
      if abs(lhs.normalMotion) != abs(rhs.normalMotion) {
        return abs(lhs.normalMotion) > abs(rhs.normalMotion)
      }
      if lhs.travelToIntersection != rhs.travelToIntersection {
        return lhs.travelToIntersection < rhs.travelToIntersection
      }
      return lhs.route.routeId < rhs.route.routeId
    }.first
  }

  private func edgeLine(bounds: CGRect, edge: String) -> CGFloat {
    switch edge {
    case "left":
      return bounds.minX
    case "top":
      return bounds.minY
    case "bottom":
      return max(bounds.minY, bounds.maxY - 1)
    default:
      return max(bounds.minX, bounds.maxX - 1)
    }
  }

  private func intersectionParameter(
    edge: String,
    line: CGFloat,
    previousPoint: CGPoint,
    deltaX: CGFloat,
    deltaY: CGFloat
  ) -> CGFloat? {
    if edge == "left" || edge == "right" {
      return deltaX == 0 ? nil : (line - previousPoint.x) / deltaX
    }
    return deltaY == 0 ? nil : (line - previousPoint.y) / deltaY
  }

  private func edgeNormalMotion(
    edge: String,
    deltaX: CGFloat,
    deltaY: CGFloat
  ) -> CGFloat {
    switch edge {
    case "left":
      return -deltaX
    case "top":
      return -deltaY
    case "bottom":
      return deltaY
    default:
      return deltaX
    }
  }

  private func axisCoordinate(point: CGPoint, edge: String) -> CGFloat {
    return edge == "left" || edge == "right" ? point.y : point.x
  }

  private func segmentContains(
    coordinate: CGFloat,
    start: CGFloat,
    end: CGFloat,
    displayId: String,
    edge: String,
    captureRoutes routes: [CaptureRoute]
  ) -> Bool {
    if coordinate < start {
      return false
    }
    if coordinate < end {
      return true
    }
    if coordinate != end {
      return false
    }
    return !routes.contains { other in
      other.sourceDisplayId == displayId &&
        other.sourceEdge == edge &&
        other.sourceSegmentStart <= end &&
        other.sourceSegmentEnd > end
    }
  }

  private func hideCaptureCursorIfNeeded() {
    guard !captureCursorHidden else {
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self = self,
            !self.captureCursorHidden,
            self.captureActive,
            !self.captureSessionId.isEmpty else {
        return
      }
      NSCursor.hide()
      self.captureCursorHidden = true
    }
  }

  private func showCaptureCursorIfNeeded() {
    guard captureCursorHidden else {
      return
    }
    NSCursor.unhide()
    captureCursorHidden = false
  }

  private func showCursorForRemoteInjection(at point: CGPoint?) {
    let showCursor = { [weak self] in
      guard let self = self else {
        return
      }
      if self.captureCursorHidden {
        self.captureCursorHidden = false
      }
      for _ in 0..<8 {
        NSCursor.unhide()
      }
      NSCursor.setHiddenUntilMouseMoves(false)
      CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
      if let point = point {
        CGWarpMouseCursorPosition(point)
      }
      let showResult = CGDisplayShowCursor(CGMainDisplayID())
      os_log(
        "remote input cursor show requested result=%{public}d point=%{public}d,%{public}d",
        log: remoteInputLog,
        type: .info,
        showResult.rawValue,
        point.map { Int($0.x) } ?? -1,
        point.map { Int($0.y) } ?? -1)
    }
    if Thread.isMainThread {
      showCursor()
    } else {
      DispatchQueue.main.async(execute: showCursor)
    }
  }

  private func pinCaptureCursorIfNeeded(type: CGEventType) {
    switch type {
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
      moveCaptureCursorToLocalEdge()
    default:
      break
    }
  }

  private func moveCaptureCursorToLocalEdge(edgeUnit: CGFloat? = nil) {
    let bounds = captureBounds()
    let currentPoint = CGEvent(source: nil)?.location ?? CGPoint(
      x: bounds.midX,
      y: bounds.midY)
    let inset: CGFloat = 2
    var x = min(bounds.maxX - inset, max(bounds.minX + inset, currentPoint.x))
    var y = min(bounds.maxY - inset, max(bounds.minY + inset, currentPoint.y))
    if hasCaptureSegment() {
      let unit: CGFloat
      if let edgeUnit = edgeUnit {
        unit = clampedUnit(edgeUnit)
      } else {
        unit = edgeUnitForPoint(
          currentPoint,
          edge: captureEdge,
          segmentStart: captureSegmentStart,
          segmentEnd: captureSegmentEnd)
      }
      let coordinate = segmentCoordinate(
        edgeUnit: unit,
        segmentStart: captureSegmentStart,
        segmentEnd: captureSegmentEnd)
      if captureEdge == "left" || captureEdge == "right" {
        y = min(bounds.maxY - inset, max(bounds.minY + inset, coordinate))
      } else {
        x = min(bounds.maxX - inset, max(bounds.minX + inset, coordinate))
      }
    }
    let point: CGPoint
    switch captureEdge {
    case "left":
      point = CGPoint(x: bounds.minX + inset, y: y)
    case "top":
      point = CGPoint(x: x, y: bounds.minY + inset)
    case "bottom":
      point = CGPoint(x: x, y: bounds.maxY - inset)
    case "right":
      fallthrough
    default:
      point = CGPoint(x: bounds.maxX - inset, y: y)
    }
    CGWarpMouseCursorPosition(point)
  }

  private func updateInjectedMouseInteriorState(_ data: [String: Any], point: CGPoint) {
    if boolValue(data["activeStart"]) {
      injectedMouseEnteredInterior = false
    }
    guard !injectedMouseEnteredInterior else {
      return
    }
    let usingConfiguredEdge = hasInjectionSegment() && !injectionEdge.isEmpty
    let bounds = usingConfiguredEdge ? injectionBounds() : virtualDisplayBounds()
    let distance: CGFloat = 32
    let edge = usingConfiguredEdge
      ? injectionEdge
      : (data["edge"] as? String ?? "right")
    let isInterior: Bool
    if usingConfiguredEdge {
      switch edge {
      case "left":
        isInterior = point.x >= bounds.minX + distance
      case "right":
        isInterior = point.x <= bounds.maxX - distance
      case "top":
        isInterior = point.y >= bounds.minY + distance
      case "bottom":
        isInterior = point.y <= bounds.maxY - distance
      default:
        isInterior = point.x >= bounds.minX + distance
      }
    } else {
      switch edge {
      case "left":
        isInterior = point.x <= bounds.maxX - distance
      case "top":
        isInterior = point.y <= bounds.maxY - distance
      case "bottom":
        isInterior = point.y >= bounds.minY + distance
      case "right":
        fallthrough
      default:
        isInterior = point.x >= bounds.minX + distance
      }
    }
    if isInterior {
      injectedMouseEnteredInterior = true
    }
  }

  private func isReverseInjectionRelease(
    _ data: [String: Any],
    currentPoint: CGPoint,
    deltaX: CGFloat,
    deltaY: CGFloat
  ) -> Bool {
    guard !boolValue(data["activeStart"]) else {
      return false
    }
    let threshold: CGFloat = 6
    if hasInjectionSegment() && !injectionEdge.isEmpty {
      let bounds = injectionBounds()
      guard pointWithinSegment(
        currentPoint,
        edge: injectionEdge,
        segmentStart: injectionSegmentStart,
        segmentEnd: injectionSegmentEnd,
        tolerance: threshold) else {
        return false
      }
      switch injectionEdge {
      case "left":
        return currentPoint.x <= bounds.minX + threshold && deltaX < 0
      case "right":
        return currentPoint.x >= bounds.maxX - threshold && deltaX > 0
      case "top":
        return currentPoint.y <= bounds.minY + threshold && deltaY < 0
      case "bottom":
        return currentPoint.y >= bounds.maxY - threshold && deltaY > 0
      default:
        return currentPoint.x <= bounds.minX + threshold && deltaX < 0
      }
    }
    let bounds = virtualDisplayBounds()
    let edge = data["edge"] as? String ?? "right"
    switch edge {
    case "left":
      return currentPoint.x >= bounds.maxX - threshold && deltaX > 0
    case "top":
      return currentPoint.y >= bounds.maxY - threshold && deltaY > 0
    case "bottom":
      return currentPoint.y <= bounds.minY + threshold && deltaY < 0
    case "right":
      fallthrough
    default:
      return currentPoint.x <= bounds.minX + threshold && deltaX < 0
    }
  }

  private func reverseInjectionSourceEdgeUnit(
    currentPoint: CGPoint,
    deltaX: CGFloat,
    deltaY: CGFloat
  ) -> InjectionReleaseRoute? {
    guard !injectionRoutes.isEmpty else {
      return nil
    }
    let nextPoint = CGPoint(
      x: currentPoint.x + deltaX,
      y: currentPoint.y + deltaY)
    guard let crossing = resolveInjectionReleaseCrossing(
      previousPoint: currentPoint,
      currentPoint: nextPoint) else {
      return nil
    }
    return InjectionReleaseRoute(
      routeId: crossing.route.routeId,
      sourceDisplayId: crossing.route.sourceDisplayId,
      sourceEdge: crossing.route.sourceEdge,
      sourceSegmentStart: crossing.route.sourceSegmentStart,
      sourceSegmentEnd: crossing.route.sourceSegmentEnd,
      edgeUnit: crossing.edgeUnit)
  }

  private func resolveInjectionReleaseCrossing(
    previousPoint: CGPoint,
    currentPoint: CGPoint
  ) -> InjectionReleaseCrossing? {
    let candidates = injectionRoutes.compactMap { route in
      injectionReleaseCrossing(
        route: route,
        previousPoint: previousPoint,
        currentPoint: currentPoint)
    }
    return rankedInjectionReleaseCrossing(candidates)
  }

  private func injectionReleaseCrossing(
    route: InjectionRoute,
    previousPoint: CGPoint,
    currentPoint: CGPoint
  ) -> InjectionReleaseCrossing? {
    let bounds = screenBounds(displayId: route.sinkDisplayId) ??
      virtualDisplayBounds()
    let line = edgeLine(bounds: bounds, edge: route.sinkEdge)
    let deltaX = currentPoint.x - previousPoint.x
    let deltaY = currentPoint.y - previousPoint.y
    guard deltaX != 0 || deltaY != 0,
          let t = intersectionParameter(
            edge: route.sinkEdge,
            line: line,
            previousPoint: previousPoint,
            deltaX: deltaX,
            deltaY: deltaY),
          t >= 0,
          t <= 1 else {
      return nil
    }
    let normalMotion = edgeNormalMotion(
      edge: route.sinkEdge,
      deltaX: deltaX,
      deltaY: deltaY)
    guard normalMotion > 0 else {
      return nil
    }
    let intersection = CGPoint(
      x: previousPoint.x + deltaX * t,
      y: previousPoint.y + deltaY * t)
    let coordinate = axisCoordinate(point: intersection, edge: route.sinkEdge)
    guard segmentContains(
      coordinate: coordinate,
      start: route.sinkSegmentStart,
      end: route.sinkSegmentEnd,
      displayId: route.sinkDisplayId,
      edge: route.sinkEdge,
      injectionRoutes: injectionRoutes) else {
      return nil
    }
    let length = route.sinkSegmentEnd - route.sinkSegmentStart
    guard length > 0 else {
      return nil
    }
    let edgeUnit = min(1, max(0, (coordinate - route.sinkSegmentStart) / length))
    return InjectionReleaseCrossing(
      route: route,
      edgeUnit: edgeUnit,
      strictSegmentHit: coordinate > route.sinkSegmentStart &&
        coordinate < route.sinkSegmentEnd,
      normalMotion: normalMotion,
      travelToIntersection: hypot(
        intersection.x - previousPoint.x,
        intersection.y - previousPoint.y))
  }

  private func rankedInjectionReleaseCrossing(
    _ candidates: [InjectionReleaseCrossing]
  ) -> InjectionReleaseCrossing? {
    return candidates.sorted { lhs, rhs in
      if lhs.strictSegmentHit != rhs.strictSegmentHit {
        return lhs.strictSegmentHit
      }
      if abs(lhs.normalMotion) != abs(rhs.normalMotion) {
        return abs(lhs.normalMotion) > abs(rhs.normalMotion)
      }
      if lhs.travelToIntersection != rhs.travelToIntersection {
        return lhs.travelToIntersection < rhs.travelToIntersection
      }
      if !injectionRouteId.isEmpty &&
          (lhs.route.routeId == injectionRouteId) !=
          (rhs.route.routeId == injectionRouteId) {
        return lhs.route.routeId == injectionRouteId
      }
      return lhs.route.routeId < rhs.route.routeId
    }.first
  }

  private func segmentContains(
    coordinate: CGFloat,
    start: CGFloat,
    end: CGFloat,
    displayId: String,
    edge: String,
    injectionRoutes routes: [InjectionRoute]
  ) -> Bool {
    if coordinate < start {
      return false
    }
    if coordinate < end {
      return true
    }
    if coordinate != end {
      return false
    }
    return !routes.contains { other in
      other.sinkDisplayId == displayId &&
        other.sinkEdge == edge &&
        other.sinkSegmentStart <= end &&
        other.sinkSegmentEnd > end
    }
  }

  private func emitCaptureRelease(reason: String) {
    let sessionId = captureSessionId
    let edgeUnit = captureEdgeUnitForCurrentPoint()
    guard !sessionId.isEmpty else {
      return
    }
    stopCapture()
    emitRelease(sessionId: sessionId, reason: reason, edgeUnit: edgeUnit)
  }

  private func emitInjectionRelease(
    reason: String,
    edgeUnit: CGFloat? = nil,
    sourceEdgeUnit: Bool = false,
    routeId: String = "",
    sourceDisplayId: String = "",
    sourceEdge: String = "",
    sourceSegmentStart: CGFloat = 0,
    sourceSegmentEnd: CGFloat = 0
  ) {
    let sessionId = injectionSessionId
    let resolvedEdgeUnit = edgeUnit ?? injectionEdgeUnitForCurrentPoint()
    guard !sessionId.isEmpty else {
      return
    }
    emitDiagnostic(message: "mac remote input injection release reason=\(reason)")
    releaseInjectedMouseButtons()
    releaseInjectedKeys()
    releaseCommonModifierKeys()
    injectedMousePoint = nil
    injectedMouseEnteredInterior = false
    resetInjectedClickState()
    emitRelease(
      sessionId: sessionId,
      reason: reason,
      edgeUnit: resolvedEdgeUnit,
      sourceEdgeUnit: sourceEdgeUnit,
      routeId: routeId,
      sourceDisplayId: sourceDisplayId,
      sourceEdge: sourceEdge,
      sourceSegmentStart: sourceSegmentStart,
      sourceSegmentEnd: sourceSegmentEnd)
  }

  private func captureEdgeUnitForCurrentPoint() -> CGFloat {
    guard hasCaptureSegment() else {
      return 0
    }
    let point = CGEvent(source: nil)?.location ?? CGPoint.zero
    return edgeUnitForPoint(
      point,
      edge: captureEdge,
      segmentStart: captureSegmentStart,
      segmentEnd: captureSegmentEnd)
  }

  private func injectionEdgeUnitForCurrentPoint() -> CGFloat {
    guard hasInjectionSegment(), !injectionEdge.isEmpty else {
      return 0
    }
    let point = injectedMousePoint ?? CGEvent(source: nil)?.location ?? CGPoint.zero
    return edgeUnitForPoint(
      point,
      edge: injectionEdge,
      segmentStart: injectionSegmentStart,
      segmentEnd: injectionSegmentEnd)
  }

  private func emitRelease(
    sessionId: String,
    reason: String,
    edgeUnit: CGFloat,
    sourceEdgeUnit: Bool = false,
    routeId: String = "",
    sourceDisplayId: String = "",
    sourceEdge: String = "",
    sourceSegmentStart: CGFloat = 0,
    sourceSegmentEnd: CGFloat = 0
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        return
      }
      var arguments: [String: Any] = [
        "sessionId": sessionId,
        "reason": reason,
        "edgeUnit": Double(edgeUnit)
      ]
      if sourceEdgeUnit {
        arguments["sourceEdgeUnit"] = true
      }
      if !routeId.isEmpty {
        arguments["routeId"] = routeId
      }
      if !sourceDisplayId.isEmpty {
        arguments["sourceDisplayId"] = sourceDisplayId
      }
      if !sourceEdge.isEmpty {
        arguments["sourceEdge"] = sourceEdge
      }
      if sourceSegmentEnd > sourceSegmentStart {
        arguments["sourceSegmentStart"] = Int(sourceSegmentStart)
        arguments["sourceSegmentEnd"] = Int(sourceSegmentEnd)
      }
      self.channel.invokeMethod("onRelease", arguments: arguments)
    }
  }
}

private let remoteInputEventCallback: CGEventTapCallBack = {
  _, type, event, userInfo in
  guard let userInfo = userInfo else {
    return Unmanaged.passUnretained(event)
  }
  let plugin = Unmanaged<RemoteInputPlugin>
    .fromOpaque(userInfo)
    .takeUnretainedValue()
  return plugin.handleEvent(type: type, event: event)
    ? nil
    : Unmanaged.passUnretained(event)
}

final class AudioSharePlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var playbackFormat: AVAudioFormat?
  private var playbackChannels = 0
  private var playbackSessionId = ""
  private var capture: Any?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.vireen.whisper/audio_share",
      binaryMessenger: registrar.messenger)
    let instance = AudioSharePlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startPlayback":
      guard let args = call.arguments as? [String: Any],
            let sessionId = args["sessionId"] as? String,
            let format = args["format"] as? [String: Any] else {
        result(FlutterError(
          code: "bad-arguments",
          message: "startPlayback requires sessionId and format",
          details: nil))
        return
      }
      do {
        try startPlayback(sessionId: sessionId, format: format)
        result(nil)
      } catch {
        result(FlutterError(
          code: "audio-playback",
          message: error.localizedDescription,
          details: nil))
      }

    case "writePcm":
      guard let args = call.arguments as? [String: Any],
            let sessionId = args["sessionId"] as? String,
            let pcm = pcmData(from: args["pcm"]) else {
        result(FlutterError(
          code: "bad-arguments",
          message: "writePcm requires sessionId and pcm",
          details: nil))
        return
      }
      writePcm(sessionId: sessionId, pcm: pcm)
      result(nil)

    case "stopPlayback":
      let args = call.arguments as? [String: Any]
      stopPlayback(sessionId: args?["sessionId"] as? String ?? "")
      result(nil)

    case "startCapture":
      guard let args = call.arguments as? [String: Any],
            let sessionId = args["sessionId"] as? String,
            let format = args["format"] as? [String: Any] else {
        result(FlutterError(
          code: "bad-arguments",
          message: "startCapture requires sessionId and format",
          details: nil))
        return
      }
      startCapture(sessionId: sessionId, format: format, result: result)

    case "stopCapture":
      stopCapture()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startPlayback(sessionId: String, format: [String: Any]) throws {
    stopPlayback()
    playbackSessionId = sessionId

    let sampleRate = Double(format["sampleRate"] as? Int ?? 48000)
    let channels = AVAudioChannelCount(format["channels"] as? Int ?? 2)
    guard let audioFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: max(1, min(channels, 2)),
      interleaved: false) else {
      throw NSError(
        domain: "AudioSharePlugin",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Invalid playback format"])
    }

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: audioFormat)
    try engine.start()
    player.play()

    self.engine = engine
    self.player = player
    playbackFormat = audioFormat
    playbackChannels = Int(audioFormat.channelCount)
  }

  private func writePcm(sessionId: String, pcm: Data) {
    guard sessionId == playbackSessionId,
          let player = player,
          let format = playbackFormat,
          pcm.count > 0 else {
      return
    }

    guard playbackChannels > 0 else {
      return
    }
    let sourceBytesPerFrame = playbackChannels * MemoryLayout<Int16>.size
    let frameCount = AVAudioFrameCount(pcm.count / sourceBytesPerFrame)
    guard frameCount > 0,
          let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount) else {
      return
    }
    buffer.frameLength = frameCount
    guard let channelData = buffer.floatChannelData else {
      return
    }
    pcm.withUnsafeBytes { rawBuffer in
      let bytes = rawBuffer.bindMemory(to: UInt8.self)
      for frame in 0..<Int(frameCount) {
        for channel in 0..<playbackChannels {
          let byteIndex = (frame * playbackChannels + channel) * 2
          let lo = UInt16(bytes[byteIndex])
          let hi = UInt16(bytes[byteIndex + 1]) << 8
          let sample = Int16(littleEndian: Int16(bitPattern: hi | lo))
          channelData[channel][frame] = Float(sample) / 32768.0
        }
      }
    }
    player.scheduleBuffer(buffer, completionHandler: nil)
    if !player.isPlaying {
      player.play()
    }
  }

  private func stopPlayback(sessionId: String = "") {
    if !sessionId.isEmpty && sessionId != playbackSessionId {
      return
    }
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    playbackFormat = nil
    playbackChannels = 0
    playbackSessionId = ""
  }

  private func startCapture(
    sessionId: String,
    format: [String: Any],
    result: @escaping FlutterResult
  ) {
    guard #available(macOS 13.0, *) else {
      result(FlutterError(
        code: "audio-capture-unavailable",
        message: "System audio capture requires macOS 13 or newer",
        details: nil))
      return
    }

    guard ensureScreenCapturePermission(result: result) else {
      return
    }

    stopCapture()
    let capture = MacSystemAudioCapture(channel: channel)
    self.capture = capture
    Task {
      do {
        try await capture.start(sessionId: sessionId, format: format)
        DispatchQueue.main.async {
          result(nil)
        }
      } catch {
        capture.sendError(sessionId: sessionId, message: error.localizedDescription)
        DispatchQueue.main.async {
          result(FlutterError(
            code: "audio-capture",
            message: error.localizedDescription,
            details: nil))
        }
      }
    }
  }

  private func stopCapture() {
    if #available(macOS 13.0, *),
       let capture = capture as? MacSystemAudioCapture {
      capture.stop()
    }
    capture = nil
  }

  private func ensureScreenCapturePermission(result: @escaping FlutterResult) -> Bool {
    if CGPreflightScreenCaptureAccess() {
      return true
    }

    if CGRequestScreenCaptureAccess() {
      return true
    }

    openScreenRecordingSettings()
    result(FlutterError(
      code: "audio-capture-permission-denied",
      message: "需要在系统设置 > 隐私与安全性 > 屏幕录制中允许 Whisper Dev，然后重启应用",
      details: nil))
    return false
  }

  private func openScreenRecordingSettings() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    ) else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  private func pcmData(from value: Any?) -> Data? {
    if let data = value as? FlutterStandardTypedData {
      return data.data
    }
    return value as? Data
  }
}

@available(macOS 13.0, *)
private final class MacSystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
  private let channel: FlutterMethodChannel
  private let sampleQueue = DispatchQueue(label: "com.vireen.whisper.audio.capture")
  private var stream: SCStream?
  private var sessionId = ""
  private var sequence: Int64 = 0

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  func start(sessionId: String, format: [String: Any]) async throws {
    self.sessionId = sessionId
    sequence = 0

    let sampleRate = format["sampleRate"] as? Int ?? 48000
    let channels = max(1, min(format["channels"] as? Int ?? 2, 2))
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: true)
    guard let display = content.displays.first else {
      throw NSError(
        domain: "AudioSharePlugin",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "No display available for audio capture"])
    }

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.width = 2
    configuration.height = 2
    configuration.capturesAudio = true
    configuration.excludesCurrentProcessAudio = false
    configuration.sampleRate = sampleRate
    configuration.channelCount = channels

    let stream = SCStream(
      filter: filter,
      configuration: configuration,
      delegate: self)
    try stream.addStreamOutput(
      self,
      type: .audio,
      sampleHandlerQueue: sampleQueue)
    try await stream.startCapture()
    self.stream = stream
  }

  func stop() {
    let stream = self.stream
    self.stream = nil
    Task {
      try? await stream?.stopCapture()
    }
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .audio,
          sampleBuffer.isValid,
          let pcm = pcm16Data(from: sampleBuffer) else {
      return
    }
    let currentSequence = sequence
    sequence += 1
    let captureTimeMicros = Int64(Date().timeIntervalSince1970 * 1_000_000)
    DispatchQueue.main.async { [channel, sessionId] in
      channel.invokeMethod("onCapturePcm", arguments: [
        "sessionId": sessionId,
        "sequence": currentSequence,
        "captureTimeMicros": captureTimeMicros,
        "pcm": FlutterStandardTypedData(bytes: pcm),
      ])
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    sendError(sessionId: sessionId, message: error.localizedDescription)
  }

  func sendError(sessionId: String, message: String) {
    DispatchQueue.main.async { [channel] in
      channel.invokeMethod("onCaptureError", arguments: [
        "sessionId": sessionId,
        "message": message,
      ])
    }
  }

  private func pcm16Data(from sampleBuffer: CMSampleBuffer) -> Data? {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
          let streamDescription =
            CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
      return nil
    }
    let asbd = streamDescription.pointee
    let channels = Int(asbd.mChannelsPerFrame)
    let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
    guard channels > 0, frameCount > 0 else {
      return nil
    }

    var listSize = 0
    var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &listSize,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: 0,
      blockBufferOut: nil)
    guard status == noErr else {
      return nil
    }

    let isNonInterleaved =
      (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    let audioBufferListStorage = UnsafeMutableRawPointer.allocate(
      byteCount: listSize,
      alignment: MemoryLayout<AudioBufferList>.alignment)
    defer {
      audioBufferListStorage.deallocate()
    }
    let audioBufferListPointer = audioBufferListStorage.bindMemory(
      to: AudioBufferList.self,
      capacity: 1)
    let audioBufferList = UnsafeMutableAudioBufferListPointer(
      audioBufferListPointer)

    var blockBuffer: CMBlockBuffer?
    status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: audioBufferListPointer,
      bufferListSize: listSize,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
      blockBufferOut: &blockBuffer)
    guard status == noErr else {
      return nil
    }
    _ = blockBuffer

    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let isSignedInteger =
      (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
    var output = [Int16](repeating: 0, count: frameCount * channels)

    if isFloat && asbd.mBitsPerChannel == 32 {
      copyFloat32(
        from: audioBufferList,
        frameCount: frameCount,
        channels: channels,
        nonInterleaved: isNonInterleaved,
        to: &output)
    } else if isSignedInteger && asbd.mBitsPerChannel == 16 {
      copyInt16(
        from: audioBufferList,
        frameCount: frameCount,
        channels: channels,
        nonInterleaved: isNonInterleaved,
        to: &output)
    } else {
      return nil
    }

    return output.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  private func copyFloat32(
    from buffers: UnsafeMutableAudioBufferListPointer,
    frameCount: Int,
    channels: Int,
    nonInterleaved: Bool,
    to output: inout [Int16]
  ) {
    if nonInterleaved {
      for channel in 0..<channels {
        guard channel < buffers.count,
              let data = buffers[channel].mData else {
          continue
        }
        let source = data.assumingMemoryBound(to: Float.self)
        for frame in 0..<frameCount {
          output[frame * channels + channel] = floatToInt16(source[frame])
        }
      }
      return
    }

    guard let data = buffers.first?.mData else {
      return
    }
    let source = data.assumingMemoryBound(to: Float.self)
    for index in 0..<(frameCount * channels) {
      output[index] = floatToInt16(source[index])
    }
  }

  private func copyInt16(
    from buffers: UnsafeMutableAudioBufferListPointer,
    frameCount: Int,
    channels: Int,
    nonInterleaved: Bool,
    to output: inout [Int16]
  ) {
    if nonInterleaved {
      for channel in 0..<channels {
        guard channel < buffers.count,
              let data = buffers[channel].mData else {
          continue
        }
        let source = data.assumingMemoryBound(to: Int16.self)
        for frame in 0..<frameCount {
          output[frame * channels + channel] = source[frame]
        }
      }
      return
    }

    guard let data = buffers.first?.mData else {
      return
    }
    let source = data.assumingMemoryBound(to: Int16.self)
    for index in 0..<(frameCount * channels) {
      output[index] = source[index]
    }
  }

  private func floatToInt16(_ value: Float) -> Int16 {
    let clamped = max(-1.0, min(1.0, value))
    return Int16(clamped * Float(Int16.max))
  }
}
