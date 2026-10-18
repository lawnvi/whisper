import AVFoundation
import CoreMedia
import CoreVideo
import Flutter
import GameController
import ImageIO
import UIKit
import VideoToolbox

/// Receives streamed windows on iPhone and iPad: H.264 (Annex-B) decoded by
/// VideoToolbox into a Flutter texture. Mirrors the Android receiver so the
/// Dart side is shared:
/// - method channel `com.vireen.whisper/window_stream`: create, resize,
///   dispose, snapshot, stats, watch, hardwareKeyboard; events
///   needKeyframe, size, frame (while watched), error, stats, decoderReset,
///   hardwareKeyboard;
/// - binary channel `com.vireen.whisper/window_stream_frames` on a
///   background task queue: int64 id, int64 pts µs, int32 flags (1 config,
///   2 keyframe), little-endian, then the payload.
///
/// iOS takes the hardware decoder away while the app is in the background
/// (kVTInvalidSessionErr, -12903): each receiver rebuilds its session from
/// the stream's parameter sets when that happens or when the app comes back,
/// and asks the source for a keyframe to start from.
public final class WindowStreamNativePlugin: NSObject, FlutterPlugin {
  private let textures: FlutterTextureRegistry
  private let control: FlutterMethodChannel
  private var frames: FlutterBasicMessageChannel?
  private let lock = NSLock()
  private var receivers: [Int64: StreamTextureReceiver] = [:]
  private var observers: [NSObjectProtocol] = []
  /// Last foreground rebuild, so the app's and the scene's notifications
  /// for the same return rebuild once.
  private var lastForeground = 0.0

  init(registrar: FlutterPluginRegistrar) {
    textures = registrar.textures()
    control = FlutterMethodChannel(
      name: "com.vireen.whisper/window_stream", binaryMessenger: registrar.messenger())
    super.init()
    observeLifecycle()
  }

  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = WindowStreamNativePlugin(registrar: registrar)
    registrar.addMethodCallDelegate(plugin, channel: plugin.control)
    let queue = registrar.messenger().makeBackgroundTaskQueue?()
    let frames = FlutterBasicMessageChannel(
      name: "com.vireen.whisper/window_stream_frames", binaryMessenger: registrar.messenger(),
      codec: FlutterBinaryCodec.sharedInstance(), taskQueue: queue)
    frames.setMessageHandler { [weak plugin] message, reply in
      if let data = message as? Data {
        plugin?.onFrame(data)
      }
      reply(nil)
    }
    plugin.frames = frames
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let id = (args["id"] as? NSNumber)?.int64Value ?? -1
    switch call.method {
    case "create":
      let receiver = StreamTextureReceiver(textures: textures)
      let textureId = textures.register(receiver)
      receiver.textureId = textureId
      receiver.onEvent = { [weak self] event, payload in
        DispatchQueue.main.async {
          var arguments = payload
          arguments["id"] = textureId
          self?.control.invokeMethod(event, arguments: arguments)
        }
      }
      if UIApplication.shared.applicationState == .background {
        receiver.enterBackground()
      }
      lock.lock()
      receivers[textureId] = receiver
      lock.unlock()
      result(textureId)
    case "resize":
      // The decoder outputs the stream's own size; Flutter scales the
      // texture to the viewer, so there is nothing to resize here.
      result(nil)
    case "dispose":
      lock.lock()
      let receiver = receivers.removeValue(forKey: id)
      lock.unlock()
      receiver?.invalidate()
      if receiver != nil {
        textures.unregisterTexture(id)
      }
      result(nil)
    case "snapshot":
      let maxEdge = (args["maxEdge"] as? NSNumber)?.intValue ?? 0
      let quality = (args["quality"] as? NSNumber)?.doubleValue ?? 0.78
      guard let receiver = receiver(id) else {
        result(nil)
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let jpeg = receiver.snapshot(maxEdge: maxEdge, quality: quality)
        DispatchQueue.main.async {
          result(jpeg.map { FlutterStandardTypedData(bytes: $0) })
        }
      }
    case "audioMute":
      receiver(id)?.audio.setMuted((args["muted"] as? Bool) ?? false)
      result(nil)
    case "watch":
      // The viewer is waiting for the picture to settle: one `frame` event
      // per decoded frame until it says stop.
      receiver(id)?.setWatching((args["on"] as? Bool) ?? false)
      result(nil)
    case "stats":
      result(receiver(id)?.stats())
    case "hardwareKeyboard":
      result(GCKeyboard.coalesced != nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func receiver(_ id: Int64) -> StreamTextureReceiver? {
    lock.lock()
    defer { lock.unlock() }
    return receivers[id]
  }

  private func allReceivers() -> [StreamTextureReceiver] {
    lock.lock()
    defer { lock.unlock() }
    return Array(receivers.values)
  }

  private func onFrame(_ data: Data) {
    guard data.count >= 20 else { return }
    let id: Int64 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int64.self) }
    let pts: Int64 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Int64.self) }
    let flags: Int32 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: Int32.self) }
    let value = Int32(littleEndian: flags)
    if value & (StreamAudioPlayer.flagAudio | StreamAudioPlayer.flagFormat) != 0 {
      // The window's sound, never video.
      guard let receiver = receiver(Int64(littleEndian: id)) else { return }
      let payload = data.subdata(in: 20..<data.count)
      if value & StreamAudioPlayer.flagFormat != 0, payload.count >= 8 {
        let rate: Int32 = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) }
        let channels: Int32 = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) }
        receiver.audio.configure(
          sampleRate: Int(Int32(littleEndian: rate)), channels: Int(Int32(littleEndian: channels)))
      } else if value & StreamAudioPlayer.flagAudio != 0 {
        receiver.audio.push(payload)
      }
      return
    }
    receiver(Int64(littleEndian: id))?.push(
      data.subdata(in: 20..<data.count), ptsUs: Int64(littleEndian: pts),
      flags: Int32(littleEndian: flags))
  }

  // MARK: App lifecycle

  private func observeLifecycle() {
    let center = NotificationCenter.default
    func on(_ name: Notification.Name, _ handler: @escaping () -> Void) {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in handler() })
    }
    on(UIApplication.didEnterBackgroundNotification) { [weak self] in
      self?.allReceivers().forEach { $0.enterBackground() }
    }
    on(UIApplication.willEnterForegroundNotification) { [weak self] in self?.enterForeground() }
    on(UIScene.willEnterForegroundNotification) { [weak self] in self?.enterForeground() }
    on(UIApplication.didReceiveMemoryWarningNotification) { [weak self] in
      self?.allReceivers().forEach { $0.releaseIdleFrame() }
    }
    on(.GCKeyboardDidConnect) { [weak self] in self?.keyboardChanged() }
    on(.GCKeyboardDidDisconnect) { [weak self] in self?.keyboardChanged() }
  }

  private func enterForeground() {
    let now = CACurrentMediaTime()
    guard now - lastForeground > 0.5 else { return }
    lastForeground = now
    allReceivers().forEach { $0.enterForeground() }
  }

  private func keyboardChanged() {
    // GameController updates `coalesced` after posting; read it a moment later.
    DispatchQueue.main.async { [weak self] in
      self?.control.invokeMethod(
        "hardwareKeyboard", arguments: ["id": -1, "attached": GCKeyboard.coalesced != nil])
    }
  }
}

/// One texture: decodes its stream and keeps the newest frame for Flutter
/// to pull.
final class StreamTextureReceiver: NSObject, FlutterTexture {
  var textureId: Int64 = -1
  var onEvent: ((String, [String: Any]) -> Void)? {
    didSet { audio.onEvent = onEvent }
  }

  /// The window's sound.
  let audio = StreamAudioPlayer()

  private weak var textures: FlutterTextureRegistry?
  private let queue = DispatchQueue(label: "whisper.window_stream.ios.decode", qos: .userInteractive)
  private let frameLock = NSLock()
  private var latest: CVPixelBuffer?
  private var latestAt = 0.0
  private var formatDescription: CMVideoFormatDescription?
  private var session: VTDecompressionSession?
  private var waitingForKeyframe = true
  private var lastSize = CGSize.zero
  private var lastKeyframeAsk = 0.0
  private var invalidated = false
  /// In the background iOS gives the decoder away: frames are dropped
  /// until the app returns and the session is rebuilt.
  private var backgrounded = false
  /// Report every decoded frame (`frame` events) while the viewer waits for
  /// the picture to settle.
  private var watching = false

  // Statistics, on the decode queue.
  private let counterLock = NSLock()
  private var pending = 0
  private var decodedTotal = 0
  private var droppedTotal = 0
  private var presentedTotal = 0
  private var windowStart = CACurrentMediaTime()
  private var windowFrames = 0
  private var windowDecodeSeconds = 0.0
  private var lastFps = 0.0
  private var lastDecodeMs = 0.0
  private var resets = 0

  private static let invalidSession: OSStatus = -12903  // kVTInvalidSessionErr
  private static let malfunction: OSStatus = -12911  // kVTVideoDecoderMalfunctionErr

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    frameLock.lock()
    defer { frameLock.unlock() }
    guard let buffer = latest else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  func invalidate() {
    audio.stop()
    queue.async {
      self.invalidated = true
      self.dropSession()
      self.frameLock.lock()
      self.latest = nil
      self.frameLock.unlock()
    }
  }

  func push(_ payload: Data, ptsUs: Int64, flags: Int32) {
    counterLock.lock()
    pending += 1
    counterLock.unlock()
    queue.async {
      self.counterLock.lock()
      self.pending -= 1
      self.counterLock.unlock()
      guard !self.invalidated else { return }
      if flags & 1 != 0 {
        self.configure(payload)
      } else if self.backgrounded {
        self.droppedTotal += 1
      } else {
        self.decode(payload, ptsUs: ptsUs, isKey: flags & 2 != 0)
      }
    }
  }

  func setWatching(_ on: Bool) {
    queue.async {
      let started = on && !self.watching
      self.watching = on
      // The frame already on screen counts: a window that only draws when
      // something changes may send no other for a while.
      guard started else { return }
      self.frameLock.lock()
      let buffer = self.latest
      self.frameLock.unlock()
      if let buffer = buffer {
        self.onEvent?(
          "frame",
          [
            "width": CVPixelBufferGetWidth(buffer), "height": CVPixelBufferGetHeight(buffer),
            "count": self.presentedTotal, "replay": true,
          ])
      }
    }
  }

  // MARK: Lifecycle

  func enterBackground() {
    queue.async {
      self.backgrounded = true
    }
  }

  /// Back from the background: a fresh session (the old one is usually
  /// invalid by now) and a keyframe to start it from.
  func enterForeground() {
    queue.async {
      guard !self.invalidated else { return }
      self.backgrounded = false
      self.rebuildSession(reason: "foreground")
    }
  }

  /// Memory is short: a window not drawn for a while lets its last frame go
  /// (it comes back with the next frame once the window shows again).
  func releaseIdleFrame() {
    frameLock.lock()
    if latest != nil, CACurrentMediaTime() - latestAt > 1.0 {
      latest = nil
    }
    frameLock.unlock()
  }

  // MARK: Snapshot and statistics

  /// The newest frame as JPEG, its longer edge at most [maxEdge] pixels
  /// (0: as decoded).
  func snapshot(maxEdge: Int, quality: Double) -> Data? {
    frameLock.lock()
    let buffer = latest
    frameLock.unlock()
    guard let buffer = buffer else { return nil }
    var full: CGImage?
    guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &full) == noErr,
      var image = full
    else { return nil }
    let width = image.width
    let height = image.height
    let longest = max(width, height)
    if maxEdge > 0, longest > maxEdge {
      let scale = Double(maxEdge) / Double(longest)
      let w = max(1, Int((Double(width) * scale).rounded()))
      let h = max(1, Int((Double(height) * scale).rounded()))
      guard
        let context = CGContext(
          data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return nil }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      guard let scaled = context.makeImage() else { return nil }
      image = scaled
    }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data as CFMutableData, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image,
      [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  /// decoded fps, dropped, decode ms, queued, presented, resets.
  func stats() -> [Double] {
    counterLock.lock()
    let queued = pending
    counterLock.unlock()
    return queue.sync {
      [
        lastFps, Double(droppedTotal), lastDecodeMs, Double(queued), Double(presentedTotal),
        Double(resets),
      ]
    }
  }

  private func countFrame(decodeSeconds: Double) {
    decodedTotal += 1
    windowFrames += 1
    windowDecodeSeconds += decodeSeconds
    let now = CACurrentMediaTime()
    let elapsed = now - windowStart
    guard elapsed >= 2 else { return }
    lastFps = Double(windowFrames) / elapsed
    lastDecodeMs = windowFrames > 0 ? windowDecodeSeconds / Double(windowFrames) * 1000 : 0
    windowStart = now
    windowFrames = 0
    windowDecodeSeconds = 0
    counterLock.lock()
    let queued = pending
    counterLock.unlock()
    onEvent?(
      "stats",
      [
        "values": [
          lastFps, Double(droppedTotal), lastDecodeMs, Double(queued), Double(presentedTotal),
          Double(resets),
        ],
        "audio": audio.stats(),
      ])
  }

  // MARK: Decoding

  private func askKeyframe(force: Bool = false) {
    let now = CACurrentMediaTime()
    if force || now - lastKeyframeAsk > 0.4 {
      lastKeyframeAsk = now
      onEvent?("needKeyframe", [:])
    }
  }

  private static func nalUnits(_ data: Data) -> [Data] {
    var starts: [(Int, Int)] = []
    let bytes = [UInt8](data)
    var index = 0
    while index + 2 < bytes.count {
      if bytes[index] == 0 && bytes[index + 1] == 0 {
        if bytes[index + 2] == 1 {
          starts.append((index, index + 3))
          index += 3
          continue
        }
        if index + 3 < bytes.count && bytes[index + 2] == 0 && bytes[index + 3] == 1 {
          starts.append((index, index + 4))
          index += 4
          continue
        }
      }
      index += 1
    }
    return starts.enumerated().compactMap { position, start in
      let end = position + 1 < starts.count ? starts[position + 1].0 : bytes.count
      return end > start.1 ? Data(bytes[start.1..<end]) : nil
    }
  }

  private func configure(_ data: Data) {
    let nals = StreamTextureReceiver.nalUnits(data)
    guard let sps = nals.first(where: { ($0.first ?? 0) & 0x1F == 7 }),
      let pps = nals.first(where: { ($0.first ?? 0) & 0x1F == 8 })
    else { return }
    var description: CMVideoFormatDescription?
    let status = sps.withUnsafeBytes { spsBytes in
      pps.withUnsafeBytes { ppsBytes -> OSStatus in
        let pointers: [UnsafePointer<UInt8>] = [
          spsBytes.bindMemory(to: UInt8.self).baseAddress!,
          ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
        ]
        let sizes = [sps.count, pps.count]
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
          parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
      }
    }
    guard status == noErr, let format = description else {
      onEvent?("error", ["reason": "format"])
      return
    }
    if let session = session,
      VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format)
    {
      formatDescription = format
      return
    }
    formatDescription = format
    if backgrounded {
      // Built once the app is back in front.
      dropSession()
      return
    }
    _ = makeSession()
  }

  private func dropSession() {
    if let session = session {
      VTDecompressionSessionInvalidate(session)
    }
    session = nil
  }

  @discardableResult
  private func makeSession() -> Bool {
    dropSession()
    guard let format = formatDescription else { return false }
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var created: VTDecompressionSession?
    let createStatus = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
      imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
      decompressionSessionOut: &created)
    guard createStatus == noErr, let newSession = created else {
      onEvent?("error", ["reason": "decoder"])
      return false
    }
    VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    session = newSession
    waitingForKeyframe = true
    return true
  }

  /// The session stopped working (taken away in the background, a decoder
  /// fault) or the app is back: a new one, from the next keyframe.
  private func rebuildSession(reason: String) {
    guard formatDescription != nil else {
      askKeyframe(force: true)
      return
    }
    resets += 1
    if makeSession() {
      onEvent?("decoderReset", ["reason": reason])
    }
    askKeyframe(force: true)
  }

  private func decode(_ data: Data, ptsUs: Int64, isKey: Bool) {
    if session == nil, formatDescription != nil, isKey {
      // Lost earlier (built in the background, or a failed rebuild).
      makeSession()
    }
    guard let session = session, let format = formatDescription else {
      droppedTotal += 1
      askKeyframe()
      return
    }
    if waitingForKeyframe && !isKey {
      droppedTotal += 1
      askKeyframe()
      return
    }
    var avcc = Data(capacity: data.count + 16)
    for nal in StreamTextureReceiver.nalUnits(data) {
      let type = (nal.first ?? 0) & 0x1F
      if type == 7 || type == 8 || type == 9 {
        continue
      }
      var length = UInt32(nal.count).bigEndian
      avcc.append(Data(bytes: &length, count: 4))
      avcc.append(nal)
    }
    guard !avcc.isEmpty, let memory = malloc(avcc.count) else { return }
    avcc.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: avcc.count)
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: memory, blockLength: avcc.count,
        blockAllocator: kCFAllocatorMalloc, customBlockSource: nil, offsetToData: 0,
        dataLength: avcc.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
      let dataBuffer = block
    else {
      free(memory)
      return
    }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000),
      decodeTimeStamp: .invalid)
    var size = avcc.count
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: dataBuffer, formatDescription: format,
        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
      let sampleBuffer = sample
    else { return }
    let started = CACurrentMediaTime()
    var failure: OSStatus = noErr
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil
    ) {
      [weak self]
      (status: OSStatus, _: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?, _: CMTime, _: CMTime)
      in
      guard let self = self else { return }
      guard status == noErr, let imageBuffer = imageBuffer else {
        // Synchronous decoding: this runs before DecodeFrame returns.
        failure = status
        return
      }
      self.present(imageBuffer)
    }
    let outcome = status != noErr ? status : failure
    if outcome == StreamTextureReceiver.invalidSession || outcome == StreamTextureReceiver.malfunction {
      droppedTotal += 1
      rebuildSession(reason: outcome == StreamTextureReceiver.invalidSession ? "invalid" : "malfunction")
    } else if outcome != noErr {
      droppedTotal += 1
      waitingForKeyframe = true
      askKeyframe()
    } else {
      if isKey {
        waitingForKeyframe = false
      }
      countFrame(decodeSeconds: CACurrentMediaTime() - started)
    }
  }

  private func present(_ buffer: CVPixelBuffer) {
    frameLock.lock()
    latest = buffer
    latestAt = CACurrentMediaTime()
    frameLock.unlock()
    presentedTotal += 1
    let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    if size != lastSize {
      lastSize = size
      onEvent?("size", ["width": Int(size.width), "height": Int(size.height)])
    }
    if watching {
      onEvent?(
        "frame",
        ["width": Int(size.width), "height": Int(size.height), "count": presentedTotal])
    }
    let id = textureId
    DispatchQueue.main.async { [weak self] in
      self?.textures?.textureFrameAvailable(id)
    }
  }

}

/// Plays one window's sound: PCM s16le chunks as the stream delivers them,
/// through a small jitter buffer. Playback starts once [targetMs] of sound
/// is queued; when the queue grows past [maxMs] (the network caught up in a
/// burst, the app was away) it is dropped and filled again, so the sound
/// never drifts behind the picture; when it runs dry (a pause, a gap) the
/// player stops and waits for the target again rather than stuttering.
final class StreamAudioPlayer {
  static let flagAudio: Int32 = 16
  static let flagFormat: Int32 = 32
  static let targetMs = 60.0
  static let maxMs = 150.0

  var onEvent: ((String, [String: Any]) -> Void)?

  private let queue = DispatchQueue(label: "whisper.window_stream.ios.audio", qos: .userInteractive)
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var format: AVAudioFormat?
  private var channels = 0
  private var queuedFrames = 0
  private var generation = 0
  private var playing = false
  private var muted = false
  private var stopped = false
  private var announced = false
  private var holdsSession = false
  private var underruns = 0
  private var resyncs = 0
  private var chunks = 0
  private var observers: [NSObjectProtocol] = []

  /// Windows playing sound now (the audio session is ours while > 0).
  private static let sessionLock = NSLock()
  private static var sessionUsers = 0

  init() {
    // The route changed or the system reset the engine: rebuilt on the next
    // chunk, from the target again.
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
      ) { [weak self] note in
        guard let self = self else { return }
        self.queue.async {
          guard let engine = self.engine, note.object as? AVAudioEngine === engine else { return }
          self.resetQueue()
        }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
      ) { [weak self] _ in
        self?.queue.async { self?.resetQueue() }
      })
  }

  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  func configure(sampleRate: Int, channels: Int) {
    queue.async {
      guard !self.stopped, sampleRate >= 8000, sampleRate <= 192_000, channels >= 1, channels <= 8
      else { return }
      if let format = self.format, Int(format.sampleRate) == sampleRate,
        Int(format.channelCount) == channels, self.engine != nil
      {
        return
      }
      self.teardown()
      guard
        let format = AVAudioFormat(
          commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
          channels: AVAudioChannelCount(channels), interleaved: false)
      else { return }
      let engine = AVAudioEngine()
      let player = AVAudioPlayerNode()
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: format)
      player.volume = self.muted ? 0 : 1
      self.engine = engine
      self.player = player
      self.format = format
      self.channels = channels
    }
  }

  func push(_ pcm: Data) {
    queue.async {
      guard !self.stopped, let format = self.format, let player = self.player, self.channels > 0
      else { return }
      let frameBytes = self.channels * 2
      let frames = pcm.count / frameBytes
      guard frames > 0,
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
        let out = buffer.floatChannelData
      else { return }
      buffer.frameLength = AVAudioFrameCount(frames)
      let channels = self.channels
      pcm.withUnsafeBytes { raw in
        let samples = raw.bindMemory(to: Int16.self)
        for frame in 0..<frames {
          for channel in 0..<channels {
            out[channel][frame] = Float(Int16(littleEndian: samples[frame * channels + channel])) / 32768
          }
        }
      }
      self.chunks += 1
      if !self.announced {
        self.announced = true
        self.onEvent?("audio", ["playing": true])
      }
      let rate = format.sampleRate
      let queuedMs = Double(self.queuedFrames) / rate * 1000
      let chunkMs = Double(frames) / rate * 1000
      if queuedMs + chunkMs > StreamAudioPlayer.maxMs {
        // Too far behind the picture: start again from the target.
        self.resyncs += 1
        self.resetQueue()
      }
      let generation = self.generation
      self.queuedFrames += frames
      // Consumed, not played back: the queue is the jitter buffer alone,
      // without the output's own latency.
      player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
        self?.queue.async { self?.played(frames, generation: generation) }
      }
      if !self.playing, Double(self.queuedFrames) / rate * 1000 >= StreamAudioPlayer.targetMs {
        self.start()
      }
    }
  }

  func setMuted(_ on: Bool) {
    queue.async {
      self.muted = on
      self.player?.volume = on ? 0 : 1
    }
  }

  func stop() {
    queue.async {
      self.stopped = true
      self.teardown()
    }
  }

  /// queued ms, underruns, resyncs, playing (1/0), chunks.
  func stats() -> [Double] {
    queue.sync {
      let rate = format?.sampleRate ?? 48000
      return [
        Double(queuedFrames) / rate * 1000, Double(underruns), Double(resyncs), playing ? 1 : 0,
        Double(chunks),
      ]
    }
  }

  // MARK: On the queue

  private func start() {
    guard let engine = engine, let player = player else { return }
    if !holdsSession {
      holdsSession = true
      StreamAudioPlayer.acquireSession()
    }
    if !engine.isRunning {
      do {
        try engine.start()
      } catch {
        resetQueue()
        return
      }
    }
    player.play()
    playing = true
  }

  private func played(_ frames: Int, generation: Int) {
    guard generation == self.generation else { return }
    queuedFrames = max(0, queuedFrames - frames)
    if queuedFrames == 0, playing {
      // Ran dry: wait for the target again instead of stuttering.
      underruns += 1
      player?.pause()
      playing = false
    }
  }

  /// Drops everything queued; playback starts again at the target.
  private func resetQueue() {
    generation += 1
    queuedFrames = 0
    playing = false
    player?.stop()
  }

  private func teardown() {
    resetQueue()
    engine?.stop()
    if let player = player {
      engine?.detach(player)
    }
    engine = nil
    player = nil
    format = nil
    channels = 0
    if holdsSession {
      holdsSession = false
      StreamAudioPlayer.releaseSession()
    }
  }

  /// Playback, not mixed with other apps' sound, while any window plays.
  private static func acquireSession() {
    sessionLock.lock()
    defer { sessionLock.unlock() }
    sessionUsers += 1
    guard sessionUsers == 1 else { return }
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback, options: [])
    try? session.setActive(true)
  }

  private static func releaseSession() {
    sessionLock.lock()
    defer { sessionLock.unlock() }
    sessionUsers = max(0, sessionUsers - 1)
    guard sessionUsers == 0 else { return }
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }
}
