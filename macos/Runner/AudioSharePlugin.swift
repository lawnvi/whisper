import AVFoundation
import Cocoa
import CoreMedia
import FlutterMacOS
import ScreenCaptureKit

/// Entry points the audio isolate calls directly from its own thread, so the
/// sound does not wait for the main thread: AppKit stops it for half a second
/// whenever a window is minimized or restored. Their addresses go to Dart
/// through `ffiEntryPoints`.
enum AudioFfi {
  typealias CaptureCallback = @convention(c) (
    Int64, Int64, Int32, Int32, UnsafeMutablePointer<Int16>?, Int32
  ) -> Void

  private static let captureLock = NSLock()
  private static var captureCallback: CaptureCallback?
  static var plugin: AudioSharePlugin?

  /// Null stops the calls; once this returns none is running.
  static let setCaptureCallback: @convention(c) (UnsafeRawPointer?) -> Void = {
    pointer in
    AudioFfi.captureLock.lock()
    AudioFfi.captureCallback = pointer.map {
      unsafeBitCast($0, to: CaptureCallback.self)
    }
    AudioFfi.captureLock.unlock()
  }

  /// Frees a buffer handed to the capture callback.
  static let freeBuffer: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    pointer in
    free(pointer)
  }

  /// 0 when written, 1 when [handle] is not the playback running now.
  static let writePcm: @convention(c) (Int64, UnsafePointer<Int16>?, Int32)
    -> Int32 = { handle, pcm, sampleCount in
      guard let pcm, sampleCount > 0, let plugin = AudioFfi.plugin else {
        return 1
      }
      let bytes = UnsafeRawBufferPointer(
        start: pcm, count: Int(sampleCount) * MemoryLayout<Int16>.size)
      return plugin.writePcm(handle: handle, bytes: bytes) ? 0 : 1
    }

  /// True when the audio isolate took the buffer.
  static func deliverCapture(
    sequence: Int64,
    captureTimeMicros: Int64,
    sampleRate: Int,
    channels: Int,
    data: Data
  ) -> Bool {
    captureLock.lock()
    defer { captureLock.unlock() }
    guard let callback = captureCallback else {
      return false
    }
    let sampleCount = data.count / MemoryLayout<Int16>.size
    guard sampleCount > 0,
          let copy = malloc(sampleCount * MemoryLayout<Int16>.size) else {
      return true
    }
    data.withUnsafeBytes { raw in
      if let base = raw.baseAddress {
        memcpy(copy, base, sampleCount * MemoryLayout<Int16>.size)
      }
    }
    callback(
      sequence,
      captureTimeMicros,
      Int32(sampleRate),
      Int32(channels),
      copy.assumingMemoryBound(to: Int16.self),
      Int32(sampleCount))
    return true
  }

  static func entryPoints() -> [String: Any] {
    func address<T>(_ function: T) -> Int {
      Int(bitPattern: unsafeBitCast(function, to: UnsafeRawPointer.self))
    }
    return [
      "version": 1,
      "setCaptureCallback": address(setCaptureCallback),
      "freeBuffer": address(freeBuffer),
      "writePcm": address(writePcm),
    ]
  }
}

final class AudioSharePlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  // Playback state is used from the main thread and from the audio isolate's
  // thread (AudioFfi.writePcm).
  private let playbackLock = NSLock()
  private var playbackHandle: Int64 = 0
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var playbackFormat: AVAudioFormat?
  private var nextEngineRestart: TimeInterval = 0
  private var playbackChannels = 0
  private var playbackSessionId = ""
  private var capture: Any?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.vireen.whisper/audio_share",
      binaryMessenger: registrar.messenger)
    let instance = AudioSharePlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    AudioFfi.plugin = instance
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
        result(NSNumber(value: try startPlayback(sessionId: sessionId, format: format)))
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

    case "ffiEntryPoints":
      result(AudioFfi.entryPoints())

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

  /// Returns the handle direct writes name this playback by.
  private func startPlayback(sessionId: String, format: [String: Any]) throws -> Int64 {
    playbackLock.lock()
    defer { playbackLock.unlock() }
    stopPlaybackLocked()
    playbackSessionId = sessionId

    let sampleRate = Double(format["sampleRate"] as? Int ?? 48000)
    let channels = AVAudioChannelCount(clamping: min(max(format["channels"] as? Int ?? 2, 1), 8))
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
    playbackHandle += 1
    return playbackHandle
  }

  private func writePcm(sessionId: String, pcm: Data) {
    playbackLock.lock()
    defer { playbackLock.unlock() }
    guard sessionId == playbackSessionId else {
      return
    }
    pcm.withUnsafeBytes { schedulePcmLocked($0) }
  }

  /// From the audio isolate's thread.
  fileprivate func writePcm(handle: Int64, bytes: UnsafeRawBufferPointer) -> Bool {
    playbackLock.lock()
    defer { playbackLock.unlock() }
    guard handle == playbackHandle, player != nil else {
      return false
    }
    schedulePcmLocked(bytes)
    return true
  }

  /// The output changed (headphones in or out, AirPods, a new default) or
  /// went, and the engine stopped by itself. Started again on whatever the
  /// output is then, at most once a second; with none, what arrives is
  /// dropped until one comes. Playing a node of a stopped engine raises an
  /// exception, so nothing plays before this says the engine runs.
  private func resumeEngineLocked() -> Bool {
    guard let engine = engine, let player = player,
          let format = playbackFormat else {
      return false
    }
    if engine.isRunning {
      return true
    }
    let now = ProcessInfo.processInfo.systemUptime
    if now < nextEngineRestart {
      return false
    }
    nextEngineRestart = now + 1
    engine.connect(player, to: engine.mainMixerNode, format: format)
    do {
      try engine.start()
    } catch {
      return false
    }
    player.play()
    return true
  }

  private func schedulePcmLocked(_ pcm: UnsafeRawBufferPointer) {
    guard let player = player,
          let format = playbackFormat,
          pcm.count > 0,
          playbackChannels > 0,
          resumeEngineLocked() else {
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
    let bytes = pcm.bindMemory(to: UInt8.self)
    for frame in 0..<Int(frameCount) {
      for channel in 0..<playbackChannels {
        let byteIndex = (frame * playbackChannels + channel) * 2
        let lo = UInt16(bytes[byteIndex])
        let hi = UInt16(bytes[byteIndex + 1]) << 8
        let sample = Int16(littleEndian: Int16(bitPattern: hi | lo))
        channelData[channel][frame] = Float(sample) / 32768.0
      }
    }
    player.scheduleBuffer(buffer, completionHandler: nil)
    if !player.isPlaying {
      player.play()
    }
  }

  private func stopPlayback(sessionId: String = "") {
    playbackLock.lock()
    defer { playbackLock.unlock() }
    if !sessionId.isEmpty && sessionId != playbackSessionId {
      return
    }
    stopPlaybackLocked()
  }

  private func stopPlaybackLocked() {
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    playbackFormat = nil
    nextEngineRestart = 0
    playbackChannels = 0
    playbackSessionId = ""
    // Writes still naming the old handle are dropped.
    playbackHandle += 1
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
        let wasCancelled = error is CancellationError || capture.isStopRequested
        if !wasCancelled {
          capture.sendError(sessionId: sessionId, message: error.localizedDescription)
        }
        DispatchQueue.main.async {
          result(FlutterError(
            code: wasCancelled ? "audio-capture-cancelled" : "audio-capture",
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
  private struct CapturedPcm {
    let data: Data
    let sampleRate: Int
    let channels: Int
  }

  /// The stream sends silence too, so this long without a buffer while the
  /// screens are awake means it stopped.
  private static let stallLimit: TimeInterval = 3
  /// Between attempts to open the stream again; a display waking up takes a
  /// moment to be offered for capture.
  private static let restartWaits: [UInt64] = [0, 1, 2, 4, 8]

  private let channel: FlutterMethodChannel
  private let sampleQueue = DispatchQueue(label: "com.vireen.whisper.audio.capture")
  private let stateQueue = DispatchQueue(label: "com.vireen.whisper.audio.capture.state")
  private var stream: SCStream?
  private var stopRequested = false
  private var sessionId = ""
  private var sequence: Int64 = 0
  private var sampleRate = 48000
  private var channels = 2
  private var lastSampleAt = Date()
  private var restarting = false
  private var retryNow = false
  private var watchdog: DispatchSourceTimer?
  private var observers: [NSObjectProtocol] = []
  private var audioBufferListStorage: UnsafeMutableRawPointer?
  private var audioBufferListStorageSize = 0

  var isStopRequested: Bool {
    stateQueue.sync { stopRequested }
  }

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  deinit {
    audioBufferListStorage?.deallocate()
  }

  func start(sessionId: String, format: [String: Any]) async throws {
    try throwIfStopRequested()
    self.sessionId = sessionId
    sequence = 0
    sampleRate = format["sampleRate"] as? Int ?? 48000
    channels = max(1, min(format["channels"] as? Int ?? 2, 2))
    try await startStream()
    watchForStops()
  }

  private func startStream() async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: true)
    try throwIfStopRequested()
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
    try throwIfStopRequested()
    try await stream.startCapture()
    let shouldKeepStream = stateQueue.sync { () -> Bool in
      if stopRequested {
        return false
      }
      self.stream = stream
      return true
    }
    if !shouldKeepStream {
      try? await stream.stopCapture()
      throw CancellationError()
    }
  }

  /// Turning the display off stops the stream without a word, and it stays
  /// stopped when the display comes back: sharing went silent for good. So
  /// it is opened again after a wake, or when nothing has come for a while.
  private func watchForStops() {
    let center = NSWorkspace.shared.notificationCenter
    var added: [NSObjectProtocol] = []
    added.append(center.addObserver(
      forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
    ) { _ in
      traceRemoteInput(.audioCaptureAsleep)
    })
    for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
      added.append(center.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in
        traceRemoteInput(.audioCaptureWoke)
        self?.stateQueue.async { self?.lastSampleAt = Date() }
        self?.restart()
      })
    }
    let watching = stateQueue.sync { () -> Bool in
      guard !stopRequested else {
        return false
      }
      lastSampleAt = Date()
      observers = added
      let timer = DispatchSource.makeTimerSource(queue: stateQueue)
      timer.schedule(deadline: .now() + 1, repeating: 1)
      timer.setEventHandler { [weak self] in
        // Silent past the limit, or left with no stream by a restart the
        // screens going off cut short and no wake reported.
        guard let self = self,
              !self.stopRequested, !self.restarting, !Self.displaysAsleep(),
              Date().timeIntervalSince(self.lastSampleAt) > Self.stallLimit else {
          return
        }
        traceRemoteInput(.audioCaptureStalled)
        DispatchQueue.main.async { self.restart() }
      }
      timer.resume()
      watchdog = timer
      return true
    }
    if !watching {
      added.forEach { center.removeObserver($0) }
    }
  }

  private func restart() {
    let old = stateQueue.sync { () -> SCStream?? in
      guard !stopRequested, !restarting else {
        // A wake while attempts wait between tries: try again at once.
        retryNow = true
        return .none
      }
      restarting = true
      retryNow = false
      let current = stream
      stream = nil
      return .some(current)
    }
    guard case .some(let previous) = old else {
      return
    }
    traceRemoteInput(.audioCaptureRestarting)
    // A stream that died may never finish stopping: not waited for.
    Task {
      try? await previous?.stopCapture()
    }
    Task {
      var started = false
      var asleep = false
      for wait in Self.restartWaits {
        await waitBeforeRetry(seconds: wait)
        if isStopRequested {
          break
        }
        // No display is offered while the screens are off. The wake starts
        // this again; attempts now would only use up the tries and report a
        // failure that ends the sharing.
        if Self.displaysAsleep() {
          asleep = true
          break
        }
        do {
          try await startStreamWithin(seconds: 5)
          started = true
          traceRemoteInput(.audioCaptureRestarted)
          break
        } catch {
          traceRemoteInput(.audioCaptureRestartFailed, count: Int(wait))
          continue
        }
      }
      let stopped = stateQueue.sync { () -> Bool in
        restarting = false
        lastSampleAt = Date()
        return stopRequested
      }
      if !started && !stopped && !asleep {
        sendError(sessionId: sessionId, message: "System audio capture stopped")
      }
    }
  }

  /// Asked of the system each time: a missed notification can't leave it wrong.
  private static func displaysAsleep() -> Bool {
    CGDisplayIsAsleep(CGMainDisplayID()) != 0
  }

  /// The wait between tries, cut short by a wake.
  private func waitBeforeRetry(seconds: UInt64) async {
    var left = seconds * 4
    while left > 0 {
      if stateQueue.sync(execute: { retryNow }) {
        break
      }
      try? await Task.sleep(nanoseconds: 250_000_000)
      left -= 1
    }
    stateQueue.sync { retryNow = false }
  }

  /// Opening a stream while the displays come back can wait on the system for
  /// good; such an attempt counts as failed.
  private func startStreamWithin(seconds: UInt64) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        try await startStream()
      }
      group.addTask {
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        throw NSError(
          domain: "AudioSharePlugin",
          code: 3,
          userInfo: [NSLocalizedDescriptionKey: "Opening system audio capture timed out"])
      }
      try await group.next()
      group.cancelAll()
    }
  }

  func stop() {
    let (stream, observers) = stateQueue.sync { () -> (SCStream?, [NSObjectProtocol]) in
      stopRequested = true
      watchdog?.cancel()
      watchdog = nil
      let current = self.stream
      self.stream = nil
      let watching = self.observers
      self.observers = []
      return (current, watching)
    }
    observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    Task {
      try? await stream?.stopCapture()
    }
  }

  private func throwIfStopRequested() throws {
    if isStopRequested {
      throw CancellationError()
    }
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .audio,
          sampleBuffer.isValid,
          let captured = pcm16Data(from: sampleBuffer) else {
      return
    }
    stateQueue.async { [weak self] in
      self?.lastSampleAt = Date()
    }
    let currentSequence = sequence
    sequence += 1
    let captureTimeMicros = Int64(Date().timeIntervalSince1970 * 1_000_000)
    if AudioFfi.deliverCapture(
      sequence: Int64(currentSequence),
      captureTimeMicros: captureTimeMicros,
      sampleRate: captured.sampleRate,
      channels: captured.channels,
      data: captured.data
    ) {
      return
    }
    DispatchQueue.main.async { [channel, sessionId, captured] in
      channel.invokeMethod("onCapturePcm", arguments: [
        "sessionId": sessionId,
        "sequence": currentSequence,
        "captureTimeMicros": captureTimeMicros,
        "sampleRate": captured.sampleRate,
        "channels": captured.channels,
        "pcm": FlutterStandardTypedData(bytes: captured.data),
      ])
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    // Tried again first; reported only if it can't be opened.
    DispatchQueue.main.async { [weak self] in
      self?.restart()
    }
  }

  func sendError(sessionId: String, message: String) {
    DispatchQueue.main.async { [channel] in
      channel.invokeMethod("onCaptureError", arguments: [
        "sessionId": sessionId,
        "message": message,
      ])
    }
  }

  private func pcm16Data(from sampleBuffer: CMSampleBuffer) -> CapturedPcm? {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
          let streamDescription =
            CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
      return nil
    }
    let asbd = streamDescription.pointee
    let channels = Int(asbd.mChannelsPerFrame)
    let sampleRate = Int(asbd.mSampleRate.rounded())
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
    let audioBufferListStorage = ensureAudioBufferListStorage(size: listSize)
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
    let outputSampleCount = frameCount * channels
    var data = Data(count: outputSampleCount * MemoryLayout<Int16>.size)
    let converted = data.withUnsafeMutableBytes { rawOutput -> Bool in
      let output = rawOutput.bindMemory(to: Int16.self)
      guard output.count >= outputSampleCount,
            let outputBase = output.baseAddress else {
        return false
      }
      if isFloat && asbd.mBitsPerChannel == 32 {
        copyFloat32(
          from: audioBufferList,
          frameCount: frameCount,
          channels: channels,
          nonInterleaved: isNonInterleaved,
          to: outputBase)
        return true
      }
      if isSignedInteger && asbd.mBitsPerChannel == 16 {
        copyInt16(
          from: audioBufferList,
          frameCount: frameCount,
          channels: channels,
          nonInterleaved: isNonInterleaved,
          to: outputBase)
        return true
      }
      return false
    }
    guard converted else {
      return nil
    }
    return CapturedPcm(
      data: data,
      sampleRate: sampleRate > 0 ? sampleRate : 48000,
      channels: channels)
  }

  private func copyFloat32(
    from buffers: UnsafeMutableAudioBufferListPointer,
    frameCount: Int,
    channels: Int,
    nonInterleaved: Bool,
    to output: UnsafeMutablePointer<Int16>
  ) {
    if nonInterleaved {
      var channel = 0
      while channel < channels {
        let sourceChannel = buffers.count == 1 ? 0 : min(channel, buffers.count - 1)
        guard sourceChannel >= 0,
              sourceChannel < buffers.count,
              let data = buffers[sourceChannel].mData else {
          channel += 1
          continue
        }
        let source = data.assumingMemoryBound(to: Float.self)
        var frame = 0
        while frame < frameCount {
          output[frame * channels + channel] = floatToInt16(source[frame])
          frame += 1
        }
        channel += 1
      }
      return
    }

    guard let buffer = buffers.first,
          let data = buffer.mData else {
      return
    }
    let source = data.assumingMemoryBound(to: Float.self)
    let sourceChannels = sourceChannelsForInterleavedBuffer(
      byteCount: Int(buffer.mDataByteSize),
      frameCount: frameCount,
      bytesPerSample: MemoryLayout<Float>.size,
      targetChannels: channels)
    copyInterleavedFloat32(
      from: source,
      frameCount: frameCount,
      sourceChannels: sourceChannels,
      targetChannels: channels,
      to: output)
  }

  private func copyInt16(
    from buffers: UnsafeMutableAudioBufferListPointer,
    frameCount: Int,
    channels: Int,
    nonInterleaved: Bool,
    to output: UnsafeMutablePointer<Int16>
  ) {
    if nonInterleaved {
      var channel = 0
      while channel < channels {
        let sourceChannel = buffers.count == 1 ? 0 : min(channel, buffers.count - 1)
        guard sourceChannel >= 0,
              sourceChannel < buffers.count,
              let data = buffers[sourceChannel].mData else {
          channel += 1
          continue
        }
        let source = data.assumingMemoryBound(to: Int16.self)
        var frame = 0
        while frame < frameCount {
          output[frame * channels + channel] = source[frame]
          frame += 1
        }
        channel += 1
      }
      return
    }

    guard let buffer = buffers.first,
          let data = buffer.mData else {
      return
    }
    let source = data.assumingMemoryBound(to: Int16.self)
    let sourceChannels = sourceChannelsForInterleavedBuffer(
      byteCount: Int(buffer.mDataByteSize),
      frameCount: frameCount,
      bytesPerSample: MemoryLayout<Int16>.size,
      targetChannels: channels)
    copyInterleavedInt16(
      from: source,
      frameCount: frameCount,
      sourceChannels: sourceChannels,
      targetChannels: channels,
      to: output)
  }

  private func copyInterleavedFloat32(
    from source: UnsafePointer<Float>,
    frameCount: Int,
    sourceChannels: Int,
    targetChannels: Int,
    to output: UnsafeMutablePointer<Int16>
  ) {
    if sourceChannels == targetChannels {
      let sampleCount = frameCount * targetChannels
      var index = 0
      while index < sampleCount {
        output[index] = floatToInt16(source[index])
        index += 1
      }
      return
    }
    var frame = 0
    while frame < frameCount {
      var channel = 0
      while channel < targetChannels {
        let sourceChannel = sourceChannels == 1 ? 0 : min(channel, sourceChannels - 1)
        output[frame * targetChannels + channel] =
          floatToInt16(source[frame * sourceChannels + sourceChannel])
        channel += 1
      }
      frame += 1
    }
  }

  private func copyInterleavedInt16(
    from source: UnsafePointer<Int16>,
    frameCount: Int,
    sourceChannels: Int,
    targetChannels: Int,
    to output: UnsafeMutablePointer<Int16>
  ) {
    if sourceChannels == targetChannels {
      output.update(from: source, count: frameCount * targetChannels)
      return
    }
    var frame = 0
    while frame < frameCount {
      var channel = 0
      while channel < targetChannels {
        let sourceChannel = sourceChannels == 1 ? 0 : min(channel, sourceChannels - 1)
        output[frame * targetChannels + channel] =
          source[frame * sourceChannels + sourceChannel]
        channel += 1
      }
      frame += 1
    }
  }

  private func sourceChannelsForInterleavedBuffer(
    byteCount: Int,
    frameCount: Int,
    bytesPerSample: Int,
    targetChannels: Int
  ) -> Int {
    guard frameCount > 0, bytesPerSample > 0 else {
      return max(1, targetChannels)
    }
    let sampleCount = byteCount / bytesPerSample
    let detectedChannels = sampleCount / frameCount
    return max(1, min(max(1, detectedChannels), targetChannels))
  }

  private func ensureAudioBufferListStorage(size: Int) -> UnsafeMutableRawPointer {
    if let storage = audioBufferListStorage,
       audioBufferListStorageSize >= size {
      return storage
    }
    audioBufferListStorage?.deallocate()
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: size,
      alignment: MemoryLayout<AudioBufferList>.alignment)
    audioBufferListStorage = storage
    audioBufferListStorageSize = size
    return storage
  }

  @inline(__always)
  private func floatToInt16(_ value: Float) -> Int16 {
    if value >= 1.0 {
      return Int16.max
    }
    if value <= -1.0 {
      return -Int16.max
    }
    return Int16(value * Float(Int16.max))
  }
}
