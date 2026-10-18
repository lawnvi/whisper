import AVFoundation
import CoreAudio
import CoreMedia

/// Plays 16-bit interleaved PCM on a render synchronizer.
///
/// Sender timestamps jitter by a few milliseconds per packet; scheduling each
/// packet at its own timestamp makes the renderer insert tiny gaps or
/// overlaps, which are heard as crackle. Packets are therefore laid end to end
/// on a continuous local timeline, which only re-syncs to the sender's clock
/// when the two drift apart by more than [resyncThreshold].
///
/// Phones hand over an app's audio exactly as the app made it: before the
/// phone's volume, speaker EQ and limiter. Short-drama apps output about
/// -9 dBFS RMS with peaks past full scale and plenty of 5-20 Hz rumble;
/// played as is, laptop speakers clip and drone. Samples therefore go
/// through a 20 Hz DC blocker, 6 dB of headroom and a soft limiter, in
/// float so several windows can mix without clipping.
final class AudioOutput {
  private let renderer = AVSampleBufferAudioRenderer()
  private let synchronizer = AVSampleBufferRenderSynchronizer()
  private let queue = DispatchQueue(label: "whisper.window_stream.audio.render", qos: .userInteractive)
  private let channels: Int
  private let sampleRate: Int
  private var format: CMAudioFormatDescription?

  // Everything below is touched on `queue` only.
  /// Bytes left over when a packet does not end on a frame boundary.
  private var carry = Data()
  private var nextPts: CMTime?
  private var anchored = false
  private var pending: [CMSampleBuffer] = []
  private var stopped = false
  /// How far behind the newest packet playback runs: the output device's
  /// own latency plus room for network jitter. Grows each time packets come
  /// too late, shrinks back once things are calm.
  private var latencyMs: Int64 = 90
  private var blockers: [DCBlocker]

  /// The output device needs samples this long before they are heard
  /// (buffers and the device itself: ~40 ms on a MacBook's speakers, far
  /// more over Bluetooth). Samples handed over later are cut, and a little
  /// cut from every packet sounds like a buzz over garbled speech.
  private var deviceMs = 40.0
  private var deviceCheckedAt = Date.distantPast
  /// Room for network jitter on top of the device's latency.
  private let jitterMs = 45.0
  /// -6 dB: phones leave this to their volume control.
  private let headroom: Float = 0.5
  private let resyncThreshold = CMTime(value: 80, timescale: 1000)
  private let maxAhead = CMTime(value: 400, timescale: 1000)

  /// Drift: the phone's and the Mac's audio clocks run a little apart
  /// (~0.1 ms a second), so the queue slowly fills or empties. When it is
  /// clearly too full or too empty, one sample per packet is blended away
  /// or added (about 2 ms a second, inaudible), instead of starving and
  /// restarting with a gap. Changing the playback rate instead was heard
  /// as a stutter every time it changed.
  private var smoothedLeadMs: Double?
  private var trimming = false
  private var padding = false
  /// The sender's timeline, apart from ours once samples were added or
  /// removed: jumps in it (the phone skipping) are followed.
  private var nextSenderPts: CMTime?
  /// Extra latency added after a starve is given back once things are calm.
  private var lastStarve = Date()
  private var baseLatencyMs: Int64 { Int64((deviceMs + jitterMs).rounded()) }
  private var maxLatencyMs: Int64 { baseLatencyMs + 150 }

  /// The window's volume (wsn_surface_set_volume or its own control) as a
  /// gain, and the gain samples get now: it ramps towards the target by
  /// `gainStep` a frame (silence to full in 20 ms), so a change never clicks.
  /// `queue` only.
  private var targetGain: Float
  private var gain: Float
  private let gainStep: Float

  private let statsLock = NSLock()
  private var restarts = 0
  private var resyncs = 0
  private var leadMs = 0.0

  init(sampleRate: Int, channels: Int, volume: Double = 1) {
    self.sampleRate = sampleRate
    self.channels = channels
    targetGain = AudioOutput.gain(forVolume: volume)
    gain = targetGain
    gainStep = 1 / Float(max(1, sampleRate / 50))
    blockers = (0..<channels).map { _ in DCBlocker(cutoffHz: 20, sampleRate: Double(sampleRate)) }
    deviceMs = AudioOutput.outputLatencyMs() ?? deviceMs
    deviceCheckedAt = Date()
    latencyMs = baseLatencyMs
    synchronizer.addRenderer(renderer)
    var description = AudioStreamBasicDescription(
      mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
      mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
      mBitsPerChannel: 32, mReserved: 0)
    var formatOut: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
      magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatOut)
    format = formatOut
    renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
      self?.drain()
    }
  }

  /// Called on the surface's audio queue; [buffer] is freed after return.
  func enqueue(_ buffer: OwnedBuffer, ptsUs: Int64) {
    let bytes = Data(bytes: buffer.pointer, count: buffer.length)
    queue.async { [weak self] in
      self?.place(bytes, senderUs: ptsUs)
    }
  }

  /// The window's volume, 0 (silent) to 1 (as sent). Any thread.
  func setVolume(_ volume: Double) {
    let target = AudioOutput.gain(forVolume: volume)
    queue.async { [weak self] in
      self?.targetGain = target
    }
  }

  /// Volume to gain on a cubic taper (as PulseAudio's): half the slider
  /// is about -18 dB, which sounds like half as loud.
  static func gain(forVolume volume: Double) -> Float {
    let level = Float(min(max(volume, 0), 1))
    return level * level * level
  }

  /// restarts (renderer starved or ran too far ahead), resyncs to the
  /// sender's clock, current lead over the playhead in ms, target latency.
  func statsSnapshot() -> [Double] {
    statsLock.lock()
    defer { statsLock.unlock() }
    return [Double(restarts), Double(resyncs), leadMs, Double(latencyMs)]
  }

  private func place(_ data: Data, senderUs: Int64) {
    guard !stopped, let format = format else { return }
    carry.append(data)
    let frameBytes = 2 * channels
    let sourceFrames = carry.count / frameBytes
    guard sourceFrames > 1 else { return }
    let used = sourceFrames * frameBytes
    let adjust = driftAdjustment()
    let frames = sourceFrames + adjust
    let samples = frames * channels
    guard let memory = malloc(samples * 4) else { return }
    let out = memory.assumingMemoryBound(to: Float.self)
    carry.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      for index in 0..<(sourceFrames * channels) {
        if index % channels == 0 && gain != targetGain {
          gain = gain < targetGain
            ? min(targetGain, gain + gainStep) : max(targetGain, gain - gainStep)
        }
        let low = UInt16(raw[2 * index])
        let high = UInt16(raw[2 * index + 1])
        let value = Float(Int16(bitPattern: low | (high << 8))) / 32768
        let sample = AudioOutput.limit(blockers[index % channels].process(value) * headroom * gain)
        if index < samples {
          out[index] = sample
        } else {
          // Trimming: the last frame blends into the one before it.
          let into = index - channels
          out[into] = (out[into] + sample) / 2
        }
      }
    }
    if adjust > 0 {
      // Padding: one more frame, between the last two.
      let last = (sourceFrames - 1) * channels
      for channel in 0..<channels {
        let a = out[last - channels + channel]
        let b = out[last + channel]
        out[last + channels + channel] = b
        out[last + channel] = (a + b) / 2
      }
    }
    carry = used < carry.count ? carry.subdata(in: used..<carry.count) : Data()

    let senderPts = CMTime(value: senderUs, timescale: 1_000_000)
    var pts = nextPts ?? senderPts
    if let expected = nextSenderPts,
      CMTimeCompare(CMTimeAbsoluteValue(CMTimeSubtract(senderPts, expected)), resyncThreshold) > 0
    {
      // The phone skipped or repeated audio; follow it to stay in sync.
      pts = CMTimeAdd(pts, CMTimeSubtract(senderPts, expected))
      count { $0.resyncs += 1 }
    }
    let rate = CMTimeScale(sampleRate)
    nextSenderPts = CMTimeAdd(senderPts, CMTime(value: CMTimeValue(sourceFrames), timescale: rate))
    nextPts = CMTimeAdd(pts, CMTime(value: CMTimeValue(frames), timescale: rate))

    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: memory, blockLength: samples * 4,
        blockAllocator: kCFAllocatorMalloc, customBlockSource: nil, offsetToData: 0,
        dataLength: samples * 4, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
      let dataBuffer = block
    else {
      free(memory)
      return
    }
    var sample: CMSampleBuffer?
    guard
      CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: dataBuffer, formatDescription: format,
        sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil,
        sampleBufferOut: &sample) == noErr, let audioSample = sample
    else { return }
    schedule(audioSample, pts: pts)
  }

  /// Linear up to -3 dBFS, then bends smoothly towards full scale.
  static func limit(_ value: Float) -> Float {
    let knee: Float = 0.7
    let magnitude = abs(value)
    guard magnitude > knee else { return value }
    let bent = knee + (1 - knee) * tanh((magnitude - knee) / (1 - knee))
    return value < 0 ? -bent : bent
  }

  private func schedule(_ sample: CMSampleBuffer, pts: CMTime) {
    if !anchored {
      anchor(at: pts)
    } else {
      let lead = CMTimeSubtract(pts, synchronizer.currentTime())
      statsLock.lock()
      leadMs = CMTimeGetSeconds(lead) * 1000
      statsLock.unlock()
      if CMTimeGetSeconds(lead) * 1000 < deviceMs + 5 {
        // Too late for the device: part of this packet would be cut.
        // Restart just behind it with more room.
        latencyMs = min(max(latencyMs, baseLatencyMs) + 30, maxLatencyMs)
        lastStarve = Date()
        restart(at: pts)
      } else if CMTimeCompare(lead, maxAhead) > 0 {
        restart(at: pts)
      } else {
        track(leadMs: CMTimeGetSeconds(lead) * 1000)
      }
    }
    pending.append(sample)
    drain()
  }

  private func restart(at pts: CMTime) {
    renderer.flush()
    pending.removeAll()
    anchor(at: pts)
    count { $0.restarts += 1 }
  }

  private func anchor(at pts: CMTime) {
    smoothedLeadMs = nil
    trimming = false
    padding = false
    synchronizer.setRate(1, time: CMTimeSubtract(pts, CMTime(value: latencyMs, timescale: 1000)))
    anchored = true
  }

  /// Follows how far ahead of the playhead the queue runs, and gives back
  /// latency added after a starve once things have been calm.
  private func track(leadMs: Double) {
    smoothedLeadMs = smoothedLeadMs.map { $0 * 0.95 + leadMs * 0.05 } ?? leadMs
    let now = Date()
    // Headphones come and go: follow the device in use.
    if now.timeIntervalSince(deviceCheckedAt) > 2 {
      deviceCheckedAt = now
      if let measured = AudioOutput.outputLatencyMs(), abs(measured - deviceMs) > 2 {
        // A slower device makes the next packet count as late, which
        // restarts with room for it.
        deviceMs = measured
        latencyMs = max(latencyMs, baseLatencyMs)
      }
    }
    if latencyMs > baseLatencyMs, now.timeIntervalSince(lastStarve) > 20 {
      latencyMs = max(baseLatencyMs, latencyMs - 10)
      // Another step only after another calm spell.
      lastStarve = now.addingTimeInterval(-10)
    }
  }

  /// The default output device's latency in ms: what Core Audio reports for
  /// the device, its safety offset, its buffer and its stream.
  static func outputLatencyMs() -> Double? {
    func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 _ scope: AudioObjectPropertyScope, _ value: inout T) -> Bool {
      var address = AudioObjectPropertyAddress(
        mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
      var size = UInt32(MemoryLayout<T>.size)
      return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
    var device = AudioObjectID(0)
    guard
      read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
           kAudioObjectPropertyScopeGlobal, &device), device != 0
    else { return nil }
    var rate: Float64 = 0
    guard read(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate),
      rate > 0
    else { return nil }
    var latency: UInt32 = 0
    var safety: UInt32 = 0
    var buffer: UInt32 = 0
    _ = read(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, &latency)
    _ = read(device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, &safety)
    _ = read(device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, &buffer)
    var streamLatency: UInt32 = 0
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    if AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 {
      var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
      if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr,
        let first = streams.first
      {
        _ = read(first, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, &streamLatency)
      }
    }
    let frames = Double(latency) + Double(safety) + Double(buffer) + Double(streamLatency)
    return frames / rate * 1000
  }

  /// -1: blend one frame away from this packet; +1: add one; 0: as is.
  /// Wide bands, so it only acts on real drift, not on network jitter;
  /// padding starts well before the device would run short.
  private func driftAdjustment() -> Int {
    guard anchored, let lead = smoothedLeadMs else { return 0 }
    let target = Double(latencyMs)
    if trimming {
      trimming = lead > target + 25
    } else if lead > target + 60 {
      trimming = true
    }
    if padding {
      padding = lead < target - 10
    } else if lead < target - 25 {
      padding = true
    }
    return trimming ? -1 : padding ? 1 : 0
  }

  private func drain() {
    while !pending.isEmpty && renderer.isReadyForMoreMediaData {
      renderer.enqueue(pending.removeFirst())
    }
  }

  private func count(_ update: (AudioOutput) -> Void) {
    statsLock.lock()
    update(self)
    statsLock.unlock()
  }

  func stop() {
    queue.sync {
      stopped = true
      pending.removeAll()
      renderer.stopRequestingMediaData()
      synchronizer.setRate(0, time: .zero)
      renderer.flush()
      synchronizer.removeRenderer(renderer, at: .zero, completionHandler: nil)
    }
  }
}

/// First-order high-pass: removes DC and rumble below [cutoffHz] while
/// leaving bass (40 Hz is down about 1 dB) alone.
struct DCBlocker {
  private let pole: Float
  private var lastInput: Float = 0
  private var lastOutput: Float = 0

  init(cutoffHz: Double, sampleRate: Double) {
    pole = Float(1 - 2 * Double.pi * cutoffHz / sampleRate)
  }

  mutating func process(_ input: Float) -> Float {
    let output = input - lastInput + pole * lastOutput
    lastInput = input
    lastOutput = output
    return output
  }
}
