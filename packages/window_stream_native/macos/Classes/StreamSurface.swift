import AVFoundation
import AppKit
import CoreImage
import CoreMedia
import ImageIO

/// One streamed window: its NSWindow, its decoder and its audio output.
/// Video and audio arrive on arbitrary threads and are serialised onto the
/// surface's own queues; all AppKit work happens on the main thread.
final class StreamSurface {
  let id: Int64
  private let flags: Int32
  private let decodeQueue: DispatchQueue
  private let audioQueue: DispatchQueue
  private let statsLock = NSLock()

  private var title: String
  private var videoSize: CGSize
  private var windowController: StreamWindowController?
  private var decoder: H264Decoder?
  private var audio: AudioOutput?
  /// The same output, for stats readers on other threads (statsLock).
  private var audioStats: AudioOutput?
  private var stopped = false

  // Stats, guarded by statsLock.
  private var presentedFrames = 0
  private var droppedFrames = 0
  private var queuedFrames = 0
  private var lastDecodeMs = 0.0
  private var fpsWindowStart = CACurrentMediaTime()
  private var fpsWindowFrames = 0
  private var decodedFps = 0.0
  private var firstFrameShown = false
  private var latestImage: CVPixelBuffer?
  private var lastKeyframeAsk = 0.0
  /// The window's sound level (statsLock): for the output playing now and
  /// any configured later.
  private var volume = 1.0
  /// Main thread: the window has sound, so its volume control shows.
  private var hasSound = false

  /// Above this many packets waiting to be decoded, deltas are dropped until
  /// the next keyframe so latency never builds up.
  private let maxQueuedFrames = 6

  init(id: Int64, title: String, videoSize: CGSize, flags: Int32) {
    self.id = id
    self.title = title
    self.videoSize = videoSize
    self.flags = flags
    decodeQueue = DispatchQueue(label: "whisper.window_stream.decode.\(id)", qos: .userInteractive)
    audioQueue = DispatchQueue(label: "whisper.window_stream.audio.\(id)", qos: .userInteractive)
  }

  func start() {
    let decoder = H264Decoder()
    decoder.onImage = { [weak self] sampleBuffer, decodeMs in
      self?.present(sampleBuffer, decodeMs: decodeMs)
    }
    decoder.onError = { [weak self] status in
      guard let self = self else { return }
      SurfaceRegistry.shared.emitWindow(
        surface: self.id, kind: WSNConst.windowDecodeError, a: Double(status))
      SurfaceRegistry.shared.emitWindow(surface: self.id, kind: WSNConst.windowNeedKeyframe)
    }
    self.decoder = decoder
    let id = self.id
    let title = self.title
    let size = self.videoSize
    let showHud = (flags & WSNConst.flagShowHud) != 0
    let reflow = (flags & WSNConst.flagReflow) != 0
    onMain { [weak self] in
      guard let self = self, !self.isStopped else { return }
      let controller = StreamWindowController(
        surfaceId: id, title: title, videoSize: size, showHud: showHud, reflow: reflow,
        volume: self.currentVolume)
      controller.onVolume = { [weak self] value in self?.applyVolume(value) }
      if self.hasSound {
        controller.showVolumeControl()
      }
      self.windowController = controller
      controller.show()
    }
  }

  private var currentVolume: Double {
    statsLock.lock()
    defer { statsLock.unlock() }
    return volume
  }

  /// From Dart: the sound and the window's control follow, without the
  /// control reporting it back.
  func setVolume(_ value: Double) {
    let level = value.isFinite ? min(max(value, 0), 1) : 1
    applyVolume(level)
    onMain { [weak self] in self?.windowController?.setVolume(level) }
  }

  /// The words of the window's control changed.
  func refreshStrings() {
    onMain { [weak self] in self?.windowController?.refreshStrings() }
  }

  private func applyVolume(_ level: Double) {
    statsLock.lock()
    volume = level
    statsLock.unlock()
    audioQueue.async { [weak self] in self?.audio?.setVolume(level) }
  }

  private var isStopped: Bool {
    statsLock.lock()
    defer { statsLock.unlock() }
    return stopped
  }

  func stop() {
    statsLock.lock()
    stopped = true
    statsLock.unlock()
    decodeQueue.async { [decoder] in
      decoder?.invalidate()
    }
    audioQueue.async { [audio] in
      audio?.stop()
    }
    // Strong: the registry may hold the last reference, and the window must
    // still close.
    onMain { [self] in
      self.windowController?.close()
      self.windowController = nil
    }
  }

  func setTitle(_ value: String) {
    title = value
    onMain { [weak self] in self?.windowController?.setTitle(value) }
  }

  func setIcon(_ png: Data) {
    onMain { [weak self] in self?.windowController?.setIcon(png) }
  }

  func setVisual(_ visual: Int32, message: String?) {
    onMain { [weak self] in self?.windowController?.setVisual(visual, message: message) }
  }

  func setHudText(_ text: String) {
    onMain { [weak self] in self?.windowController?.setHudText(text) }
  }

  func focus() {
    onMain { [weak self] in self?.windowController?.focus() }
  }

  // MARK: Video

  func pushVideo(_ buffer: OwnedBuffer, ptsUs: Int64, flags: Int32) {
    statsLock.lock()
    if stopped {
      statsLock.unlock()
      return
    }
    let isConfig = (flags & WSNConst.packetConfig) != 0
    let isKey = (flags & WSNConst.packetKey) != 0
    if !isConfig && !isKey && queuedFrames >= maxQueuedFrames {
      droppedFrames += 1
      let now = CACurrentMediaTime()
      let ask = now - lastKeyframeAsk > 0.3
      if ask {
        lastKeyframeAsk = now
      }
      statsLock.unlock()
      decodeQueue.async { [weak self] in self?.decoder?.requireKeyframe() }
      if ask {
        SurfaceRegistry.shared.emitWindow(surface: id, kind: WSNConst.windowNeedKeyframe)
      }
      return
    }
    queuedFrames += 1
    statsLock.unlock()
    decodeQueue.async { [weak self] in
      guard let self = self else { return }
      self.statsLock.lock()
      self.queuedFrames -= 1
      self.statsLock.unlock()
      guard let decoder = self.decoder else { return }
      if isConfig {
        decoder.configure(annexB: buffer)
      } else {
        let decoded = decoder.decode(annexB: buffer, ptsUs: ptsUs, isKey: isKey)
        if !decoded {
          self.statsLock.lock()
          self.droppedFrames += 1
          self.statsLock.unlock()
        }
      }
    }
  }

  private func present(_ sampleBuffer: CMSampleBuffer, decodeMs: Double) {
    statsLock.lock()
    presentedFrames += 1
    fpsWindowFrames += 1
    lastDecodeMs = decodeMs
    let now = CACurrentMediaTime()
    if now - fpsWindowStart >= 1 {
      decodedFps = Double(fpsWindowFrames) / (now - fpsWindowStart)
      fpsWindowFrames = 0
      fpsWindowStart = now
    }
    let first = !firstFrameShown
    firstFrameShown = true
    latestImage = CMSampleBufferGetImageBuffer(sampleBuffer)
    statsLock.unlock()

    let width = CVPixelBufferGetWidth(CMSampleBufferGetImageBuffer(sampleBuffer)!)
    let height = CVPixelBufferGetHeight(CMSampleBufferGetImageBuffer(sampleBuffer)!)
    onMain { [weak self] in
      guard let self = self, let controller = self.windowController else { return }
      controller.updateVideoSize(CGSize(width: width, height: height))
      controller.enqueue(sampleBuffer)
      controller.noteFrame(CGSize(width: width, height: height))
      if first {
        SurfaceRegistry.shared.emitWindow(surface: self.id, kind: WSNConst.windowFirstFrame)
      }
    }
  }

  /// Encodes the last presented frame (for thumbnails and text recognition).
  func writeSnapshot(to path: String, maxEdge: Int) -> Bool {
    statsLock.lock()
    let image = latestImage
    statsLock.unlock()
    guard let pixelBuffer = image else { return false }
    var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let longest = max(ciImage.extent.width, ciImage.extent.height)
    if maxEdge > 0, longest > CGFloat(maxEdge) {
      let scale = CGFloat(maxEdge) / longest
      ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
    let context = CIContext(options: [.useSoftwareRenderer: false])
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, "public.jpeg" as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(
      destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    return CGImageDestinationFinalize(destination)
  }

  /// Video: decoded fps, dropped frames, decode ms, queued frames, presented
  /// frames. Then audio (zeros without it): restarts, resyncs, lead ms,
  /// target latency ms.
  func statsSnapshot() -> [Double] {
    statsLock.lock()
    let video = [
      decodedFps, Double(droppedFrames), lastDecodeMs, Double(queuedFrames),
      Double(presentedFrames),
    ]
    let audio = audioStats
    statsLock.unlock()
    return video + (audio?.statsSnapshot() ?? [0, 0, 0, 0])
  }

  // MARK: Audio

  func configureAudio(codec: Int32, sampleRate: Int, channels: Int) {
    audioQueue.async { [weak self] in
      guard let self = self, codec == WSNConst.audioPcmS16le else { return }
      self.audio?.stop()
      let output = AudioOutput(
        sampleRate: sampleRate, channels: channels, volume: self.currentVolume)
      self.audio = output
      self.statsLock.lock()
      self.audioStats = output
      self.statsLock.unlock()
    }
    guard codec == WSNConst.audioPcmS16le else { return }
    onMain { [weak self] in
      guard let self = self else { return }
      self.hasSound = true
      self.windowController?.showVolumeControl()
    }
  }

  func pushAudio(_ buffer: OwnedBuffer, ptsUs: Int64) {
    audioQueue.async { [weak self] in
      self?.audio?.enqueue(buffer, ptsUs: ptsUs)
    }
  }
}
