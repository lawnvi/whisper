import Cocoa
import AVFoundation
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

    super.awakeFromNib()
  }

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
      super.order(place, relativeTo: otherWin)
      hiddenWindowAtLaunch()
  }
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
