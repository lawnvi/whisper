import Accelerate
import AudioToolbox
import CoreAudio
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

/// Modes of wsn_capture_set_audio (window_stream_native.h).
enum WSNCaptureAudioMode {
  static let off: Int32 = 0
  /// Captured, and it still plays here.
  static let on: Int32 = 1
  /// Captured, and silent here where the system allows it.
  static let onSilentHere: Int32 = 2
}

/// The sound of a streamed window's app (its process and the helpers that
/// play for it), delivered as WSN_CAPTURE_AUDIO: 48 kHz stereo s16le in
/// 20 ms chunks, pts on the video's clock (host time, as ScreenCaptureKit
/// stamps the frames).
///
/// Mode 2 taps the app's processes with Core Audio (macOS 14.2+, needs the
/// system audio recording permission): while the tap is read, nothing of
/// theirs reaches the speakers. Mode 1 uses an unmuted tap when that
/// permission is already there (it also hears helpers ScreenCaptureKit does
/// not know, such as a browser's audio process), else ScreenCaptureKit, so it
/// keeps playing here. Mode 2 without a tap falls back to that and says so.
///
/// Independent of the video stream, so restaging and display changes do not
/// touch it. Off the display (parked, or another window took it) it stops,
/// so the app plays here again; paused it keeps running (still silent here)
/// but delivers nothing.
@available(macOS 12.3, *)
final class WindowAudio {
  private enum Source: Equatable {
    case none
    case stream
    case tap(muted: Bool)
  }

  private let id: Int64
  private let queue: DispatchQueue
  private lazy var pipeline = PcmPipeline(id: id)

  // Queue only.
  private var mode = WSNCaptureAudioMode.off
  private var pid: pid_t = 0
  private var suspended = false
  private var stopped = false
  private var source = Source.none
  private var running: AnyObject?
  /// Bumped whenever the source changes: late samples of an old one are dropped.
  private var generation = 0
  /// The tap failed for this capture: do not try it again.
  private var tapFailed = false
  /// The last reason given for not silencing here, so each reconcile does
  /// not repeat it.
  private var lastReason = ""
  private var flushTimer: DispatchSourceTimer?
  private var outputWatch: DefaultOutputWatch?

  init(id: Int64) {
    self.id = id
    queue = DispatchQueue(label: "whisper.window_stream.audio.\(id)", qos: .userInteractive)
  }

  func setMode(_ value: Int32) {
    queue.async {
      let value = value == WSNCaptureAudioMode.on || value == WSNCaptureAudioMode.onSilentHere
        ? value : WSNCaptureAudioMode.off
      guard value != self.mode else { return }
      self.mode = value
      self.reconcile()
    }
  }

  /// The window's app, once the window is known.
  func setApp(pid: pid_t) {
    queue.async {
      guard pid != self.pid else { return }
      self.pid = pid
      if self.running != nil {
        self.switchTo(.none)
      }
      self.reconcile()
    }
  }

  /// Off the viewer's display: let the app play here again until it is back.
  func setSuspended(_ value: Bool) {
    queue.async {
      guard value != self.suspended else { return }
      self.suspended = value
      self.reconcile()
    }
  }

  /// Nobody is looking: nothing is delivered, but the source keeps running
  /// (and the app silent here) so a short pause does not bring its sound
  /// back here.
  func setPaused(_ value: Bool) {
    queue.async { self.pipeline.setPaused(value) }
  }

  func stop() {
    queue.async {
      guard !self.stopped else { return }
      self.stopped = true
      self.reconcile()
    }
  }

  // MARK: Choosing the source

  private func reconcile() {
    guard !stopped, mode != WSNCaptureAudioMode.off, pid > 0, !suspended else {
      switchTo(.none)
      return
    }
    if pid == getpid() {
      reason("audio: the window is Whisper's own, its sound is not sent")
      switchTo(.none)
      return
    }
    guard #available(macOS 13.0, *) else {
      reason("audio: needs macOS 13 (ScreenCaptureKit audio), not sent")
      switchTo(.none)
      return
    }
    if mode == WSNCaptureAudioMode.onSilentHere {
      switchTo(tapUsable() ? .tap(muted: true) : .stream)
    } else {
      switchTo(quietTapUsable() ? .tap(muted: false) : .stream)
    }
  }

  /// Whether mode 1 can use an unmuted tap without asking for anything.
  private func quietTapUsable() -> Bool {
    guard #available(macOS 14.2, *), !tapFailed else { return false }
    return AudioCapturePermission.status() == .granted
  }

  /// Whether mode 2 can use a process tap now; says why not when it cannot,
  /// and asks for the permission once when it was never asked.
  private func tapUsable() -> Bool {
    guard #available(macOS 14.2, *) else {
      reason("audio: silencing it here needs macOS 14.2, it plays here too")
      return false
    }
    if tapFailed {
      return false
    }
    switch AudioCapturePermission.status() {
    case .granted, .unknown:
      return true
    case .denied:
      reason("audio: system audio recording is not allowed for Whisper, it plays here too")
      return false
    case .undetermined:
      reason("audio: asking for the system audio recording permission; until then it plays here too")
      AudioCapturePermission.requestOnce { [weak self] granted in
        guard let self = self else { return }
        self.queue.async {
          guard granted else {
            self.reason("audio: system audio recording was not allowed, it plays here too")
            return
          }
          if self.source == .stream {
            self.reconcile()
          }
        }
      }
      return false
    }
  }

  private func switchTo(_ wanted: Source) {
    guard wanted != source || (wanted != .none && running == nil) else { return }
    if let old = running {
      (old as? WindowAudioSource)?.stop()
      running = nil
      if wanted == .none {
        note("audio: off")
      }
    }
    generation += 1
    pipeline.reset()
    source = wanted
    switch wanted {
    case .none:
      stopFlushTimer()
      outputWatch = nil
      return
    case .stream:
      if #available(macOS 13.0, *) {
        let generation = self.generation
        let stream = AppAudioStream(
          pid: pid, queue: queue,
          deliver: { [weak self] sample in
            guard let self = self, self.generation == generation else { return }
            self.pipeline.ingest(sampleBuffer: sample, source: 1)
          },
          note: { [weak self] text in self?.note(text) })
        running = stream
        stream.start()
        let silent = mode == WSNCaptureAudioMode.onSilentHere
        note("audio: capturing the app's sound with ScreenCaptureKit" + (silent ? " (plays here too)" : ""))
      }
    case .tap(let muted):
      if #available(macOS 14.2, *) {
        let generation = self.generation
        let tap = ProcessTapAudio(
          pid: pid, muted: muted, queue: queue,
          deliver: { [weak self] samples, frames, rate, ptsUs in
            guard let self = self, self.generation == generation else { return }
            self.pipeline.ingest(stereo: samples, frames: frames, rate: rate, ptsUs: ptsUs, source: 2)
          },
          note: { [weak self] text in self?.note(text) },
          failed: { [weak self] in
            // Not from inside the tap's own start.
            self?.queue.async {
              guard let self = self, self.generation == generation else { return }
              self.tapFailed = true
              self.switchTo(.none)
              self.reconcile()
            }
          })
        running = tap
        tap.start()
      }
    }
    startFlushTimer()
    updateLatency()
    if outputWatch == nil {
      outputWatch = DefaultOutputWatch(queue: queue) { [weak self] in self?.updateLatency() }
    }
  }

  /// Players hold their picture back by the output's latency so it matches
  /// what is heard; the captured sound is that much ahead of it, so its pts
  /// move by as much (a few ms on speakers, far more over Bluetooth).
  private func updateLatency() {
    let latency = OutputLatency.current()
    guard latency.us != pipeline.latencyUs else { return }
    pipeline.latencyUs = latency.us
    note("audio: output latency \(latency.text)")
  }

  /// The tail of a sound that stopped would otherwise wait for the next one.
  private func startFlushTimer() {
    guard flushTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
    timer.setEventHandler { [weak self] in self?.pipeline.flushIfIdle() }
    timer.resume()
    flushTimer = timer
  }

  private func stopFlushTimer() {
    flushTimer?.cancel()
    flushTimer = nil
  }

  private func note(_ text: String) {
    CaptureRegistry.shared.note(id: id, text)
  }

  private func reason(_ text: String) {
    guard text != lastReason else { return }
    lastReason = text
    note(text)
  }
}

protocol WindowAudioSource: AnyObject {
  func stop()
}

// MARK: - PCM: float in, 48 kHz stereo s16 chunks out

/// Queue-confined. Takes float PCM at any rate and channel layout, delivers
/// contiguous 20 ms chunks of 48 kHz stereo s16le. A gap (silence, or a
/// jump in the input's time) ends the current chunk, padded with silence.
@available(macOS 12.3, *)
final class PcmPipeline {
  static let rate = 48_000
  static let channels = 2
  static let chunkFrames = 960

  private let id: Int64
  private var paused = false
  /// Added to every pts: see WindowAudio.updateLatency.
  var latencyUs: Int64 = 0

  /// Interleaved stereo float at the input's rate.
  private var stereo = [Float]()
  /// The same at 48 kHz, when the input is at another rate.
  private var resampled = [Float]()
  /// Scaled to the s16 range before rounding.
  private var scaled = [Float]()
  private var lastSource = 0
  private var pending = [Int16](repeating: 0, count: PcmPipeline.chunkFrames * 4 * 2)
  private var pendingFrames = 0
  private var pendingPts: Int64 = 0
  private var expectedInputPts: Int64?
  private var lastAppend = 0.0

  private var converter: AudioConverterRef?
  private var converterRate = 0.0
  private var converterInput: UnsafePointer<Float>?
  private var converterInputFrames = 0
  private var unsupportedNoted = false

  init(id: Int64) {
    self.id = id
  }

  deinit {
    if let converter = converter {
      AudioConverterDispose(converter)
    }
  }

  func setPaused(_ value: Bool) {
    guard value != paused else { return }
    paused = value
    reset()
  }

  func reset() {
    pendingFrames = 0
    expectedInputPts = nil
    if let converter = converter {
      AudioConverterReset(converter)
    }
  }

  func flushIfIdle() {
    guard pendingFrames > 0, CACurrentMediaTime() - lastAppend > 0.06 else { return }
    flush()
  }

  /// A ScreenCaptureKit audio buffer.
  func ingest(sampleBuffer: CMSampleBuffer, source: Int) {
    guard !paused, sampleBuffer.isValid,
      let description = CMSampleBufferGetFormatDescription(sampleBuffer),
      let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
    else { return }
    let frames = CMSampleBufferGetNumSamples(sampleBuffer)
    guard frames > 0 else { return }
    var listSize = 0
    guard
      CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
        blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        == noErr, listSize > 0
    else { return }
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
    var block: CMBlockBuffer?
    guard
      CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize,
        blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        == noErr
    else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard pts.isValid else { return }
    let ptsUs = Int64((CMTimeGetSeconds(pts) * 1_000_000).rounded())
    if stereo.count < frames * 2 {
      stereo = [Float](repeating: 0, count: frames * 2)
    }
    let ok = stereo.withUnsafeMutableBufferPointer { out in
      PcmPipeline.interleaveStereo(
        UnsafeMutableAudioBufferListPointer(list), format: basic, frames: frames,
        into: out.baseAddress!)
    }
    withExtendedLifetime(block) {}
    guard ok else {
      if !unsupportedNoted {
        unsupportedNoted = true
        CaptureRegistry.shared.note(
          id: id, "audio: unsupported format \(basic.mFormatID) flags \(basic.mFormatFlags)")
      }
      return
    }
    stereo.withUnsafeBufferPointer { samples in
      process(samples.baseAddress!, frames: frames, rate: basic.mSampleRate, ptsUs: ptsUs, source: source)
    }
  }

  /// Interleaved stereo float (a tap's IO cycle, already copied).
  func ingest(stereo samples: [Float], frames: Int, rate: Double, ptsUs: Int64, source: Int) {
    guard !paused, frames > 0, samples.count >= frames * 2 else { return }
    samples.withUnsafeBufferPointer { buffer in
      process(buffer.baseAddress!, frames: frames, rate: rate, ptsUs: ptsUs, source: source)
    }
  }

  private func process(
    _ samples: UnsafePointer<Float>, frames: Int, rate: Double, ptsUs: Int64, source: Int
  ) {
    guard rate > 0 else { return }
    // Digital silence (the app is quiet): a gap, nothing to send.
    var peak: Float = 0
    vDSP_maxmgv(samples, 1, &peak, vDSP_Length(frames * 2))
    if peak == 0 {
      flush()
      expectedInputPts = nil
      return
    }
    let durationUs = Int64((Double(frames) * 1_000_000 / rate).rounded())
    if let expected = expectedInputPts, abs(ptsUs - expected) > 3_000 {
      // Lost or overlapping input: start over at the new time.
      flush()
      if let converter = converter {
        AudioConverterReset(converter)
      }
    }
    expectedInputPts = ptsUs + durationUs
    if abs(rate - Double(PcmPipeline.rate)) < 1 {
      append(samples, frames: frames, ptsUs: ptsUs, source: source)
      return
    }
    guard let count = resample(samples, frames: frames, rate: rate), count > 0 else { return }
    resampled.withUnsafeBufferPointer { output in
      append(output.baseAddress!, frames: count, ptsUs: ptsUs, source: source)
    }
  }

  /// [frames] stereo float frames at 48 kHz whose first one is at [ptsUs].
  private func append(_ samples: UnsafePointer<Float>, frames: Int, ptsUs: Int64, source: Int) {
    // Anchored to this input's own time, so the chunks follow the host clock
    // rather than drifting with the audio device's.
    let start = ptsUs - Int64(pendingFrames) * 1_000_000 / Int64(PcmPipeline.rate)
    pendingPts = start
    var offset = 0
    while offset < frames {
      let room = pending.count / 2 - pendingFrames
      if room == 0 {
        emitChunks(source: source)
        continue
      }
      let count = min(room, frames - offset)
      pending.withUnsafeMutableBufferPointer { out in
        toInt16(
          samples + offset * 2, count: count * 2, into: out.baseAddress! + pendingFrames * 2)
      }
      pendingFrames += count
      offset += count
      emitChunks(source: source)
    }
    lastAppend = CACurrentMediaTime()
    lastSource = source
  }

  private func emitChunks(source: Int) {
    let chunk = PcmPipeline.chunkFrames
    var consumed = 0
    while pendingFrames - consumed >= chunk {
      let offsetUs = Int64(consumed) * 1_000_000 / Int64(PcmPipeline.rate)
      deliver(from: consumed, frames: chunk, ptsUs: pendingPts + offsetUs, source: source)
      consumed += chunk
    }
    guard consumed > 0 else { return }
    let left = pendingFrames - consumed
    if left > 0 {
      pending.withUnsafeMutableBufferPointer { buffer in
        let base = buffer.baseAddress!
        memmove(base, base + consumed * 2, left * 2 * MemoryLayout<Int16>.size)
      }
    }
    pendingPts += Int64(consumed) * 1_000_000 / Int64(PcmPipeline.rate)
    pendingFrames = left
  }

  /// Sends what is left as one chunk padded with silence.
  private func flush() {
    guard pendingFrames > 0 else { return }
    let chunk = PcmPipeline.chunkFrames
    if pendingFrames < chunk {
      pending.withUnsafeMutableBufferPointer { buffer in
        let base = buffer.baseAddress! + pendingFrames * 2
        memset(base, 0, (chunk - pendingFrames) * 2 * MemoryLayout<Int16>.size)
      }
      pendingFrames = chunk
    }
    emitChunks(source: lastSource)
    pendingFrames = 0
  }

  private func deliver(from frame: Int, frames: Int, ptsUs: Int64, source: Int) {
    let bytes = frames * PcmPipeline.channels * MemoryLayout<Int16>.size
    guard let data = malloc(bytes)?.assumingMemoryBound(to: UInt8.self) else { return }
    pending.withUnsafeBufferPointer { buffer in
      _ = memcpy(data, buffer.baseAddress! + frame * 2, bytes)
    }
    CaptureRegistry.shared.emit(
      id: id, kind: WSNCapture.kindAudio, data: data, length: Int32(bytes), ptsUs: ptsUs + latencyUs,
      flags: 0, width: Int32(PcmPipeline.rate), height: Int32(PcmPipeline.channels))
  }

  // MARK: Conversions

  /// Float32 PCM of any channel count, interleaved or not → interleaved
  /// stereo (mono doubled, extra channels dropped).
  static func interleaveStereo(
    _ list: UnsafeMutableAudioBufferListPointer, format: AudioStreamBasicDescription, frames: Int,
    into out: UnsafeMutablePointer<Float>
  ) -> Bool {
    guard format.mFormatID == kAudioFormatLinearPCM,
      format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
      list.count > 0
    else { return false }
    let channels = Int(format.mChannelsPerFrame)
    guard channels > 0 else { return false }
    if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
      guard let left = list[0].mData?.assumingMemoryBound(to: Float.self),
        Int(list[0].mDataByteSize) >= frames * 4
      else { return false }
      var right = left
      if list.count > 1, let second = list[1].mData?.assumingMemoryBound(to: Float.self),
        Int(list[1].mDataByteSize) >= frames * 4
      {
        right = second
      }
      var split = DSPSplitComplex(realp: left, imagp: right)
      out.withMemoryRebound(to: DSPComplex.self, capacity: frames) { complex in
        vDSP_ztoc(&split, 1, complex, 2, vDSP_Length(frames))
      }
      return true
    }
    guard let data = list[0].mData?.assumingMemoryBound(to: Float.self),
      Int(list[0].mDataByteSize) >= frames * channels * 4
    else { return false }
    switch channels {
    case 2:
      out.update(from: data, count: frames * 2)
    case 1:
      var split = DSPSplitComplex(realp: data, imagp: data)
      out.withMemoryRebound(to: DSPComplex.self, capacity: frames) { complex in
        vDSP_ztoc(&split, 1, complex, 2, vDSP_Length(frames))
      }
    default:
      for frame in 0..<frames {
        out[frame * 2] = data[frame * channels]
        out[frame * 2 + 1] = data[frame * channels + 1]
      }
    }
    return true
  }

  private func toInt16(
    _ samples: UnsafePointer<Float>, count: Int, into out: UnsafeMutablePointer<Int16>
  ) {
    if scaled.count < count {
      scaled = [Float](repeating: 0, count: count)
    }
    var gain: Float = 32767
    var low: Float = -32768
    var high: Float = 32767
    scaled.withUnsafeMutableBufferPointer { buffer in
      let base = buffer.baseAddress!
      vDSP_vsmul(samples, 1, &gain, base, 1, vDSP_Length(count))
      vDSP_vclip(base, 1, &low, &high, base, 1, vDSP_Length(count))
      vDSP_vfixr16(base, 1, out, 1, vDSP_Length(count))
    }
  }

  /// Interleaved stereo float at [rate] → 48 kHz in [resampled]; the number
  /// of frames made.
  private func resample(_ samples: UnsafePointer<Float>, frames: Int, rate: Double) -> Int? {
    if converter == nil || converterRate != rate {
      if let old = converter {
        AudioConverterDispose(old)
        converter = nil
      }
      var input = PcmPipeline.floatStereo(rate: rate)
      var output = PcmPipeline.floatStereo(rate: Double(PcmPipeline.rate))
      var created: AudioConverterRef?
      guard AudioConverterNew(&input, &output, &created) == noErr, let created = created else {
        return nil
      }
      var method = UInt32(kConverterPrimeMethod_None)
      AudioConverterSetProperty(
        created, kAudioConverterPrimeMethod, UInt32(MemoryLayout<UInt32>.size), &method)
      converter = created
      converterRate = rate
      CaptureRegistry.shared.note(id: id, "audio: resampling \(Int(rate)) Hz to 48000 Hz")
    }
    guard let converter = converter else { return nil }
    let capacity = Int((Double(frames) * Double(PcmPipeline.rate) / rate).rounded(.up)) + 64
    if resampled.count < capacity * 2 {
      resampled = [Float](repeating: 0, count: capacity * 2)
    }
    converterInput = samples
    converterInputFrames = frames
    var produced = UInt32(capacity)
    let status: OSStatus = resampled.withUnsafeMutableBufferPointer { buffer in
      var list = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: 2, mDataByteSize: UInt32(capacity * 8),
          mData: UnsafeMutableRawPointer(buffer.baseAddress!)))
      return AudioConverterFillComplexBuffer(
        converter, PcmPipeline.supplyInput, Unmanaged.passUnretained(self).toOpaque(), &produced,
        &list, nil)
    }
    converterInput = nil
    guard status == noErr || status == PcmPipeline.inputDone else { return nil }
    return Int(produced)
  }

  private static let inputDone: OSStatus = 0x5753_4e31  // 'WSN1': no more input this time

  private static let supplyInput: AudioConverterComplexInputDataProc = {
    _, packets, data, _, context in
    guard let context = context else { return PcmPipeline.inputDone }
    let pipeline = Unmanaged<PcmPipeline>.fromOpaque(context).takeUnretainedValue()
    guard let input = pipeline.converterInput, pipeline.converterInputFrames > 0 else {
      packets.pointee = 0
      return PcmPipeline.inputDone
    }
    let frames = pipeline.converterInputFrames
    pipeline.converterInputFrames = 0
    data.pointee.mNumberBuffers = 1
    data.pointee.mBuffers.mNumberChannels = 2
    data.pointee.mBuffers.mDataByteSize = UInt32(frames * 8)
    data.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: input)
    packets.pointee = UInt32(frames)
    return noErr
  }

  static func floatStereo(rate: Double) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
      mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
      mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32,
      mReserved: 0)
  }
}

// MARK: - The app's processes

enum AppProcesses {
  private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
  /// Private but long-standing (Activity Monitor groups helpers with it);
  /// looked up at run time, so its absence only loses XPC helpers.
  private static let responsible: ResponsibleFn? = {
    guard let handle = dlopen(nil, RTLD_NOW),
      let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
    else { return nil }
    return unsafeBitCast(symbol, to: ResponsibleFn.self)
  }()

  /// Whether [candidate] plays for the app [root]: it is the app, a process
  /// it started (Chrome's and Electron's helpers), or one the system runs on
  /// its behalf (WebKit's GPU process for Safari and web views). Never this
  /// process.
  static func belongs(_ candidate: pid_t, to root: pid_t) -> Bool {
    guard candidate > 0, root > 0, candidate != getpid() else { return false }
    if candidate == root {
      return true
    }
    if let responsible = responsible, responsible(candidate) == root {
      return true
    }
    var current = candidate
    for _ in 0..<32 {
      let parent = parentOf(current)
      if parent == root {
        return true
      }
      if parent <= 1 || parent == current {
        return false
      }
      current = parent
    }
    return false
  }

  private static func parentOf(_ pid: pid_t) -> pid_t {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
    return pid_t(info.pbi_ppid)
  }

  /// Core Audio's process objects that belong to [root], and their pids.
  static func audioObjects(of root: pid_t) -> [(AudioObjectID, pid_t)] {
    CoreAudioObjects.processObjects().compactMap { object in
      let pid = CoreAudioObjects.pid(of: object)
      return belongs(pid, to: root) ? (object, pid) : nil
    }
  }
}

/// Small helpers over the Core Audio object API.
enum CoreAudioObjects {
  static let system = AudioObjectID(kAudioObjectSystemObject)

  static func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  static func value<T>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ fallback: T
  ) -> T {
    var where_ = address(selector, scope)
    var result = fallback
    var size = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(object, &where_, 0, nil, &size, &result)
    return status == noErr ? result : fallback
  }

  static func array<T>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of _: T.Type
  ) -> [T] {
    var where_ = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &where_, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    let count = Int(size) / MemoryLayout<T>.stride
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(object, &where_, 0, nil, &size, buffer) == noErr else {
      return []
    }
    return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
  }

  static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var where_ = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &where_, 0, nil, &size, &value) == noErr,
      let value = value
    else { return nil }
    return value.takeRetainedValue() as String
  }

  static func processObjects() -> [AudioObjectID] {
    array(system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
  }

  static func pid(of process: AudioObjectID) -> pid_t {
    value(process, kAudioProcessPropertyPID, pid_t(-1))
  }

  static func defaultOutputDevice() -> AudioObjectID {
    value(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(kAudioObjectUnknown))
  }
}

/// How long after a sample leaves an app it is heard: the default output
/// device's latency, safety offset and stream latency.
enum OutputLatency {
  static func current() -> (us: Int64, text: String) {
    let device = CoreAudioObjects.defaultOutputDevice()
    guard device != kAudioObjectUnknown else { return (0, "unknown (no output device)") }
    let output = kAudioObjectPropertyScopeOutput
    let rate = CoreAudioObjects.value(device, kAudioDevicePropertyNominalSampleRate, Float64(0))
    let latency = CoreAudioObjects.value(device, kAudioDevicePropertyLatency, scope: output, UInt32(0))
    let safety = CoreAudioObjects.value(
      device, kAudioDevicePropertySafetyOffset, scope: output, UInt32(0))
    let buffer = CoreAudioObjects.value(
      device, kAudioDevicePropertyBufferFrameSize, scope: output, UInt32(0))
    let streams = CoreAudioObjects.array(
      device, kAudioDevicePropertyStreams, scope: output, of: AudioObjectID.self)
    let streamLatency = streams.first.map {
      CoreAudioObjects.value($0, kAudioStreamPropertyLatency, UInt32(0))
    } ?? 0
    guard rate > 0 else { return (0, "unknown (no sample rate)") }
    let frames = Double(latency) + Double(safety) + Double(streamLatency)
    let us = Int64((frames / rate * 1_000_000).rounded())
    let name = CoreAudioObjects.string(device, kAudioObjectPropertyName) ?? "?"
    return (
      us,
      "\(us / 1000) ms on \(name) (device \(latency) + safety \(safety) + stream \(streamLatency)"
        + " frames at \(Int(rate)) Hz, buffer \(buffer))"
    )
  }
}

/// Calls back on [queue] when the default output device changes.
final class DefaultOutputWatch {
  private let queue: DispatchQueue
  private var block: AudioObjectPropertyListenerBlock?

  init(queue: DispatchQueue, changed: @escaping () -> Void) {
    self.queue = queue
    let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
    var where_ = CoreAudioObjects.address(kAudioHardwarePropertyDefaultOutputDevice)
    if AudioObjectAddPropertyListenerBlock(CoreAudioObjects.system, &where_, queue, block) == noErr {
      self.block = block
    }
  }

  deinit {
    guard let block = block else { return }
    var where_ = CoreAudioObjects.address(kAudioHardwarePropertyDefaultOutputDevice)
    AudioObjectRemovePropertyListenerBlock(CoreAudioObjects.system, &where_, queue, block)
  }
}

/// Calls back on [queue] when Core Audio's list of processes changes (an
/// app's helper starts playing, say). Removed on [cancel].
final class ProcessListWatch {
  private let queue: DispatchQueue
  private var block: AudioObjectPropertyListenerBlock?

  init(queue: DispatchQueue, changed: @escaping () -> Void) {
    self.queue = queue
    let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
    var where_ = CoreAudioObjects.address(kAudioHardwarePropertyProcessObjectList)
    if AudioObjectAddPropertyListenerBlock(CoreAudioObjects.system, &where_, queue, block) == noErr {
      self.block = block
    }
  }

  func cancel() {
    guard let block = block else { return }
    self.block = nil
    var where_ = CoreAudioObjects.address(kAudioHardwarePropertyProcessObjectList)
    AudioObjectRemovePropertyListenerBlock(CoreAudioObjects.system, &where_, queue, block)
  }

  deinit {
    cancel()
  }
}

// MARK: - ScreenCaptureKit: the app's sound, still playing here

/// An audio-only stream of the app's sound. Its picture (2×2 px, once a
/// second) is thrown away; it runs on the main display, so the window's
/// virtual display coming and going does not touch it.
@available(macOS 13.0, *)
final class AppAudioStream: NSObject, SCStreamOutput, SCStreamDelegate, WindowAudioSource {
  private let pid: pid_t
  private let queue: DispatchQueue
  private let deliver: (CMSampleBuffer) -> Void
  private let note: (String) -> Void

  // Queue only.
  private var stream: SCStream?
  private var stopped = false
  /// Pids already looked for in the shareable content.
  private var considered: Set<pid_t> = []
  private var failures: [Double] = []
  private var watch: ProcessListWatch?
  private var refreshing = false

  init(
    pid: pid_t, queue: DispatchQueue, deliver: @escaping (CMSampleBuffer) -> Void,
    note: @escaping (String) -> Void
  ) {
    self.pid = pid
    self.queue = queue
    self.deliver = deliver
    self.note = note
  }

  /// Queue.
  func start() {
    guard !stopped else { return }
    watch = ProcessListWatch(queue: queue) { [weak self] in self?.helpersMayHaveChanged() }
    load()
  }

  /// Queue.
  func stop() {
    guard !stopped else { return }
    stopped = true
    watch?.cancel()
    watch = nil
    if let stream = stream {
      self.stream = nil
      stream.stopCapture(completionHandler: nil)
    }
  }

  private func load() {
    refreshing = true
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) {
      [weak self] content, error in
      guard let self = self else { return }
      self.queue.async {
        self.refreshing = false
        guard !self.stopped else { return }
        guard let content = content else {
          self.note("audio: no shareable content (\(error?.localizedDescription ?? "unknown"))")
          return
        }
        self.apply(content)
      }
    }
  }

  private func apply(_ content: SCShareableContent) {
    let apps = content.applications.filter { AppProcesses.belongs($0.processID, to: pid) }
    let main = CGMainDisplayID()
    guard !apps.isEmpty,
      let display = content.displays.first(where: { $0.displayID == main }) ?? content.displays.first
    else {
      // The screen is locked, say: the list comes back empty for a while.
      retryLater("the app is not in the shareable content")
      return
    }
    considered.formUnion(apps.map(\.processID))
    considered.formUnion(AppProcesses.audioObjects(of: pid).map(\.1))
    let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
    if let stream = stream {
      stream.updateContentFilter(filter) { [weak self] error in
        guard let error = error else { return }
        self?.queue.async { self?.note("audio: filter update failed (\(error.localizedDescription))") }
      }
      return
    }
    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = true
    configuration.excludesCurrentProcessAudio = true
    configuration.sampleRate = PcmPipeline.rate
    configuration.channelCount = PcmPipeline.channels
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    configuration.queueDepth = 3
    configuration.showsCursor = false
    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    do {
      try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
      // Without a picture output ScreenCaptureKit logs every dropped frame.
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    } catch {
      note("audio: stream setup failed (\(error.localizedDescription))")
      return
    }
    self.stream = stream
    stream.startCapture { [weak self] error in
      guard let self = self, let error = error else { return }
      self.queue.async { self.failed(stream, error) }
    }
  }

  /// A helper of the app started or ended: include it in the filter.
  private func helpersMayHaveChanged() {
    guard !stopped, !refreshing, stream != nil else { return }
    let now = Set(AppProcesses.audioObjects(of: pid).map(\.1))
    let fresh = now.subtracting(considered)
    guard !fresh.isEmpty else { return }
    considered.formUnion(fresh)
    load()
  }

  private func failed(_ failedStream: SCStream, _ error: Error) {
    guard !stopped, stream === failedStream else { return }
    stream = nil
    retryLater("capture stopped (\(error.localizedDescription))")
  }

  /// Tries again a few times, further apart each time, then gives up.
  private func retryLater(_ why: String) {
    let now = CACurrentMediaTime()
    failures = failures.filter { now - $0 < 60 } + [now]
    guard failures.count <= 5 else {
      note("audio: \(why), giving up: no sound")
      return
    }
    let delay = Double(failures.count) * 2
    note("audio: \(why), trying again in \(Int(delay)) s")
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.load() }
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
              of type: SCStreamOutputType) {
    guard type == .audio, !stopped, stream === self.stream else { return }
    deliver(sampleBuffer)
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    queue.async { self.failed(stream, error) }
  }
}

// MARK: - Core Audio process tap: the app's sound, silent here

/// Taps the app's processes (macOS 14.2+) with mutedWhenTapped: while this
/// reads the tap, their sound goes nowhere else. The tap and its aggregate
/// device are private to this process, so they vanish with it even after a
/// crash, and the app's sound with them comes back here.
@available(macOS 14.2, *)
final class ProcessTapAudio: WindowAudioSource {
  typealias Deliver = (_ samples: [Float], _ frames: Int, _ rate: Double, _ ptsUs: Int64) -> Void

  private let pid: pid_t
  /// Silent here while tapped (mode 2), or still playing here (mode 1).
  private let muted: Bool
  private let queue: DispatchQueue
  private let deliver: Deliver
  private let note: (String) -> Void
  private let failed: () -> Void

  // Queue only.
  private var stopped = false
  private var description: CATapDescription?
  private var tap = AudioObjectID(kAudioObjectUnknown)
  private var aggregate = AudioObjectID(kAudioObjectUnknown)
  private var ioProc: AudioDeviceIOProcID?
  private var processes: [AudioObjectID] = []
  private var watch: ProcessListWatch?
  private var formatListener: AudioObjectPropertyListenerBlock?
  /// Read by the IO thread; replaced only while IO is stopped.
  private var format = AudioStreamBasicDescription()
  private let cycles = Counter()
  private var withOutputDevice = false

  init(
    pid: pid_t, muted: Bool, queue: DispatchQueue, deliver: @escaping Deliver,
    note: @escaping (String) -> Void, failed: @escaping () -> Void
  ) {
    self.pid = pid
    self.muted = muted
    self.queue = queue
    self.deliver = deliver
    self.note = note
    self.failed = failed
  }

  /// Queue.
  func start() {
    watch = ProcessListWatch(queue: queue) { [weak self] in self?.updateProcesses() }
    updateProcesses()
    if processes.isEmpty {
      note("audio: tap waits for the app to play something")
    }
  }

  /// Queue.
  func stop() {
    guard !stopped else { return }
    stopped = true
    watch?.cancel()
    watch = nil
    teardown()
    note(muted ? "audio: tap removed, the app plays here again" : "audio: tap removed")
  }

  private func updateProcesses() {
    guard !stopped else { return }
    let now = AppProcesses.audioObjects(of: pid).map(\.0).sorted()
    guard now != processes else { return }
    processes = now
    guard !now.isEmpty else { return }
    if let description = description, tap != kAudioObjectUnknown {
      // Same tap, new members: no gap and no moment of sound here.
      description.processes = now
      var where_ = CoreAudioObjects.address(kAudioTapPropertyDescription)
      var reference: CATapDescription = description
      let status = withUnsafeMutablePointer(to: &reference) { pointer in
        AudioObjectSetPropertyData(
          tap, &where_, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer)
      }
      if status == noErr {
        note("audio: tap now covers \(now.count) process(es) of the app")
        return
      }
      note("audio: tap update failed (\(status)), making a new one")
      teardown()
    }
    build()
  }

  private func build() {
    let description = CATapDescription(stereoMixdownOfProcesses: processes)
    description.name = "Whisper window audio"
    description.uuid = UUID()
    description.isPrivate = true
    description.muteBehavior = muted ? .mutedWhenTapped : .unmuted
    var created = AudioObjectID(kAudioObjectUnknown)
    var status = AudioHardwareCreateProcessTap(description, &created)
    guard status == noErr, created != kAudioObjectUnknown else {
      fail("audio: could not create the tap (\(status))")
      return
    }
    self.description = description
    tap = created
    format = CoreAudioObjects.value(
      tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
    guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
      fail("audio: the tap has no format")
      return
    }
    status = makeAggregate(description.uuid.uuidString, withOutput: withOutputDevice)
    guard status == noErr else {
      fail("audio: could not create the tap's device (\(status))")
      return
    }
    status = startIO()
    guard status == noErr else {
      fail("audio: could not start the tap (\(status))")
      return
    }
    watchFormat()
    let behavior = readBackMuteBehavior()
    let here: String
    switch behavior {
    case .mutedWhenTapped: here = "silent here"
    case .unmuted: here = "plays here too"
    case nil: here = "mute state unknown"
    default: here = "mute behavior \(behavior!.rawValue)"
    }
    note(
      "audio: tapping \(processes.count) process(es) of the app at \(Int(format.mSampleRate)) Hz,"
        + " \(here)" + (withOutputDevice ? " (clocked by the output device)" : ""))
    // A device that never runs gives nothing: try once more clocked by the
    // output device, then give up on the tap.
    let before = cycles.value
    queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self = self, !self.stopped, self.tap != kAudioObjectUnknown else { return }
      guard self.cycles.value == before else { return }
      if !self.withOutputDevice {
        self.note("audio: the tap's device does not run, retrying on the output device's clock")
        self.withOutputDevice = true
        self.teardown()
        self.build()
      } else {
        self.fail("audio: the tap's device does not run")
      }
    }
  }

  private func makeAggregate(_ tapUID: String, withOutput: Bool) -> OSStatus {
    var composition: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Whisper window audio",
      kAudioAggregateDeviceUIDKey: "com.vireen.whisper.window-audio.\(UUID().uuidString)",
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
      ],
    ]
    if withOutput {
      let output = CoreAudioObjects.defaultOutputDevice()
      if let uid = CoreAudioObjects.string(output, kAudioDevicePropertyDeviceUID) {
        composition[kAudioAggregateDeviceMainSubDeviceKey] = uid
        composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
      }
    }
    var device = AudioObjectID(kAudioObjectUnknown)
    let status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device)
    if status == noErr {
      aggregate = device
    }
    return status
  }

  private func startIO() -> OSStatus {
    let format = self.format
    let rate = format.mSampleRate
    let deliver = self.deliver
    let queue = self.queue
    let cycles = self.cycles
    let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    let channels = Int(format.mChannelsPerFrame)
    // The tap's buffers come after any of the output device's own.
    let tapBuffers = planar ? channels : 1
    var procID: AudioDeviceIOProcID?
    // Runs on the device's IO thread: copy the cycle out and get off it.
    let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) {
      _, input, inputTime, _, _ in
      let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
      guard list.count >= tapBuffers, let firstData = list[list.count - tapBuffers].mData else {
        return
      }
      let first = list.count - tapBuffers
      let frames = Int(list[first].mDataByteSize) / (planar ? 4 : 4 * max(channels, 1))
      guard frames > 0 else { return }
      cycles.increment()
      let time = inputTime.pointee
      let host = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : mach_absolute_time()
      let ptsUs = Int64(AudioConvertHostTimeToNanos(host) / 1000)
      var ok = true
      let samples = [Float](unsafeUninitializedCapacity: frames * 2) { buffer, count in
        if planar {
          let left = firstData.assumingMemoryBound(to: Float.self)
          let right = (tapBuffers > 1 ? list[first + 1].mData : nil)?
            .assumingMemoryBound(to: Float.self) ?? left
          var split = DSPSplitComplex(realp: left, imagp: right)
          buffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: frames) { complex in
            vDSP_ztoc(&split, 1, complex, 2, vDSP_Length(frames))
          }
        } else {
          var single = AudioBufferList(mNumberBuffers: 1, mBuffers: list[first])
          ok = withUnsafeMutablePointer(to: &single) { pointer in
            PcmPipeline.interleaveStereo(
              UnsafeMutableAudioBufferListPointer(pointer), format: format, frames: frames,
              into: buffer.baseAddress!)
          }
        }
        count = ok ? frames * 2 : 0
      }
      guard ok else { return }
      queue.async { deliver(samples, frames, rate, ptsUs) }
    }
    guard status == noErr, let procID = procID else { return status }
    ioProc = procID
    if withOutputDevice {
      readOnlyTheTap(procID, tapStreams: 1)
    }
    return AudioDeviceStart(aggregate, procID)
  }

  /// With the output device in the aggregate, keep its own input streams
  /// (a headset's microphone, say) closed: only the tap's are read.
  private func readOnlyTheTap(_ procID: AudioDeviceIOProcID, tapStreams: Int) {
    let streams = CoreAudioObjects.array(
      aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput,
      of: AudioObjectID.self)
    guard streams.count > tapStreams else { return }
    let size = MemoryLayout<UnsafeMutableRawPointer>.size + 4 + 4 * streams.count
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
    defer { raw.deallocate() }
    raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
    let offset = MemoryLayout<UnsafeMutableRawPointer>.size
    raw.storeBytes(of: UInt32(streams.count), toByteOffset: offset, as: UInt32.self)
    for index in 0..<streams.count {
      let on: UInt32 = index >= streams.count - tapStreams ? 1 : 0
      raw.storeBytes(of: on, toByteOffset: offset + 4 + 4 * index, as: UInt32.self)
    }
    var where_ = CoreAudioObjects.address(
      kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
    let status = AudioObjectSetPropertyData(aggregate, &where_, 0, nil, UInt32(size), raw)
    if status != noErr {
      note("audio: could not limit the tap's device to the tap (\(status))")
    }
  }

  private func watchFormat() {
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self = self, !self.stopped, self.tap != kAudioObjectUnknown else { return }
      let format = CoreAudioObjects.value(
        self.tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
      guard format.mSampleRate != self.format.mSampleRate
        || format.mChannelsPerFrame != self.format.mChannelsPerFrame
        || format.mFormatFlags != self.format.mFormatFlags
      else { return }
      self.note("audio: tap format now \(Int(format.mSampleRate)) Hz, restarting it")
      self.teardown()
      self.build()
    }
    var where_ = CoreAudioObjects.address(kAudioTapPropertyFormat)
    if AudioObjectAddPropertyListenerBlock(tap, &where_, queue, listener) == noErr {
      formatListener = listener
    }
  }

  /// What the system says it does with the tapped sound.
  private func readBackMuteBehavior() -> CATapMuteBehavior? {
    var where_ = CoreAudioObjects.address(kAudioTapPropertyDescription)
    var value: Unmanaged<CATapDescription>?
    var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
    guard AudioObjectGetPropertyData(tap, &where_, 0, nil, &size, &value) == noErr,
      let value = value
    else { return nil }
    // Ownership of the returned object is not documented: not released here
    // (at worst one small leak per tap rather than an over-release).
    return value.takeUnretainedValue().muteBehavior
  }

  private func teardown() {
    if let listener = formatListener, tap != kAudioObjectUnknown {
      var where_ = CoreAudioObjects.address(kAudioTapPropertyFormat)
      AudioObjectRemovePropertyListenerBlock(tap, &where_, queue, listener)
    }
    formatListener = nil
    if aggregate != kAudioObjectUnknown {
      if let ioProc = ioProc {
        AudioDeviceStop(aggregate, ioProc)
        AudioDeviceDestroyIOProcID(aggregate, ioProc)
      }
      AudioHardwareDestroyAggregateDevice(aggregate)
    }
    ioProc = nil
    aggregate = AudioObjectID(kAudioObjectUnknown)
    if tap != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(tap)
    }
    tap = AudioObjectID(kAudioObjectUnknown)
    description = nil
  }

  private func fail(_ text: String) {
    note(text)
    teardown()
    stopped = true
    watch?.cancel()
    watch = nil
    failed()
  }
}

/// A count shared with an IO thread.
final class Counter {
  private var lock = os_unfair_lock()
  private var count = 0

  func increment() {
    os_unfair_lock_lock(&lock)
    count += 1
    os_unfair_lock_unlock(&lock)
  }

  var value: Int {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    return count
  }
}

// MARK: - Permission

/// The "system audio recording" permission (kTCCServiceAudioCapture) that
/// process taps need. There is no public API to read or ask for it; TCC's
/// is looked up at run time, and without it the tap is simply tried.
enum AudioCapturePermission {
  enum Status {
    case granted
    case denied
    case undetermined
    /// The private TCC calls are not there: just try.
    case unknown
  }

  private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
  private typealias RequestFn = @convention(c) (
    CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void
  ) -> Void

  private static let service = "kTCCServiceAudioCapture" as CFString
  private static let framework: UnsafeMutableRawPointer? = dlopen(
    "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
  private static let preflight: PreflightFn? = framework.flatMap { dlsym($0, "TCCAccessPreflight") }
    .map { unsafeBitCast($0, to: PreflightFn.self) }
  private static let request: RequestFn? = framework.flatMap { dlsym($0, "TCCAccessRequest") }
    .map { unsafeBitCast($0, to: RequestFn.self) }

  private static let lock = NSLock()
  private static var asked = false
  private static var answer: Bool?
  private static var waiting: [(Bool) -> Void] = []

  static func status() -> Status {
    lock.lock()
    let answered = answer
    lock.unlock()
    if let answered = answered {
      return answered ? .granted : .denied
    }
    guard let preflight = preflight else { return .unknown }
    switch preflight(service, nil) {
    case 0: return .granted
    case 1: return .denied
    default: return .undetermined
    }
  }

  /// Shows the system's prompt once per run; [done] gets the answer.
  static func requestOnce(_ done: @escaping (Bool) -> Void) {
    guard let request = request else {
      done(false)
      return
    }
    lock.lock()
    if let answered = answer {
      lock.unlock()
      done(answered)
      return
    }
    waiting.append(done)
    let first = !asked
    asked = true
    lock.unlock()
    guard first else { return }
    request(service, nil) { granted in
      lock.lock()
      answer = granted
      let all = waiting
      waiting.removeAll()
      lock.unlock()
      for callback in all {
        callback(granted)
      }
    }
  }
}
