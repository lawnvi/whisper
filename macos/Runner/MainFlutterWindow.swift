import Cocoa
import AVFoundation
import ApplicationServices
import CoreGraphics
import CoreMedia
import FlutterMacOS
import ScreenCaptureKit
import window_manager

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
  private let channel: FlutterMethodChannel
  private var captureSessionId = ""
  private var injectionSessionId = ""
  private var captureEdge = "right"
  private var releaseHotkey = "ctrl+alt+esc"
  private var captureActive = false
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var sequence = 0

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
      startCapture(
        sessionId: sessionId,
        edge: edge,
        releaseHotkey: releaseHotkey,
        result: result)

    case "stopCapture":
      stopCapture()
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
      injectionSessionId = sessionId
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
      injectEvent(sessionId: sessionId, eventType: eventType, payload: payload)
      result(nil)

    case "stopInjection":
      injectionSessionId = ""
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startCapture(
    sessionId: String,
    edge: String,
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
    self.releaseHotkey = releaseHotkey
    captureActive = false
    sequence = 0

    let mask =
      (1 << CGEventType.mouseMoved.rawValue) |
      (1 << CGEventType.leftMouseDragged.rawValue) |
      (1 << CGEventType.rightMouseDragged.rawValue) |
      (1 << CGEventType.otherMouseDragged.rawValue) |
      (1 << CGEventType.leftMouseDown.rawValue) |
      (1 << CGEventType.leftMouseUp.rawValue) |
      (1 << CGEventType.rightMouseDown.rawValue) |
      (1 << CGEventType.rightMouseUp.rawValue) |
      (1 << CGEventType.otherMouseDown.rawValue) |
      (1 << CGEventType.otherMouseUp.rawValue) |
      (1 << CGEventType.scrollWheel.rawValue) |
      (1 << CGEventType.keyDown.rawValue) |
      (1 << CGEventType.keyUp.rawValue)

    let userInfo = Unmanaged.passUnretained(self).toOpaque()
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .listenOnly,
      eventsOfInterest: CGEventMask(mask),
      callback: remoteInputEventCallback,
      userInfo: userInfo) else {
      result(FlutterError(
        code: "remote-input-capture-unavailable",
        message: "无法创建键鼠监听，请确认辅助功能权限已开启",
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
    captureActive = false
  }

  fileprivate func handleEvent(type: CGEventType, event: CGEvent) {
    guard !captureSessionId.isEmpty else {
      return
    }
    if isReleaseHotkey(type: type, event: event) {
      emitRelease(reason: "hotkey")
      return
    }
    if !captureActive {
      if isEdgeActivationEvent(type: type, event: event) {
        captureActive = true
      } else {
        return
      }
    }
    guard let encoded = encodePayload(type: type, event: event) else {
      return
    }
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
  }

  private func encodePayload(type: CGEventType, event: CGEvent) -> Data? {
    let point = event.location
    var payload: [String: Any] = [:]
    switch remoteInputEventType(type) {
    case "mouseMove":
      payload = ["x": point.x, "y": point.y]
    case "mouseButton":
      payload = [
        "button": buttonNumber(type: type, event: event),
        "down": isButtonDown(type: type),
        "x": point.x,
        "y": point.y
      ]
    case "mouseWheel":
      payload = [
        "deltaX": event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
        "deltaY": event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
      ]
    case "key":
      payload = [
        "keyCode": event.getIntegerValueField(.keyboardEventKeycode),
        "down": type == .keyDown
      ]
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
    case .keyDown, .keyUp:
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

  private func injectEvent(sessionId: String, eventType: String, payload: Data) {
    guard sessionId == injectionSessionId,
          let object = try? JSONSerialization.jsonObject(with: payload),
          let data = object as? [String: Any] else {
      return
    }

    switch eventType {
    case "mouseMove":
      let point = CGPoint(
        x: data["x"] as? CGFloat ?? 0,
        y: data["y"] as? CGFloat ?? 0)
      CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    case "mouseButton":
      let point = CGPoint(
        x: data["x"] as? CGFloat ?? 0,
        y: data["y"] as? CGFloat ?? 0)
      let buttonValue = data["button"] as? Int ?? 0
      let down = data["down"] as? Bool ?? false
      let button: CGMouseButton = buttonValue == 1 ? .right : .left
      let mouseType: CGEventType
      if button == .right {
        mouseType = down ? .rightMouseDown : .rightMouseUp
      } else {
        mouseType = down ? .leftMouseDown : .leftMouseUp
      }
      CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    case "mouseWheel":
      let deltaX = Int32(data["deltaX"] as? Int ?? 0)
      let deltaY = Int32(data["deltaY"] as? Int ?? 0)
      CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0)?.post(tap: .cghidEventTap)
    case "key":
      let keyCode = CGKeyCode(data["keyCode"] as? Int ?? 0)
      let down = data["down"] as? Bool ?? false
      CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)?.post(tap: .cghidEventTap)
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

  private func isEdgeActivationEvent(type: CGEventType, event: CGEvent) -> Bool {
    switch type {
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
      let point = event.location
      let bounds = CGDisplayBounds(CGMainDisplayID())
      let threshold: CGFloat = 6
      switch captureEdge {
      case "left":
        return point.x <= bounds.minX + threshold
      case "top":
        return point.y <= bounds.minY + threshold
      case "bottom":
        return point.y >= bounds.maxY - threshold
      case "right":
        fallthrough
      default:
        return point.x >= bounds.maxX - threshold
      }
    default:
      return false
    }
  }

  private func emitRelease(reason: String) {
    let sessionId = captureSessionId
    guard !sessionId.isEmpty else {
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        return
      }
      self.channel.invokeMethod("onRelease", arguments: [
        "sessionId": sessionId,
        "reason": reason
      ])
      self.stopCapture()
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
  plugin.handleEvent(type: type, event: event)
  return Unmanaged.passUnretained(event)
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
