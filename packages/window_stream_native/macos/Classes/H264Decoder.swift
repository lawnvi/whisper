import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

/// Decodes Annex-B H.264 (as produced by Android MediaCodec) with
/// VideoToolbox and hands out display-ready sample buffers.
/// Not thread-safe: the owner calls it from one serial queue.
final class H264Decoder {
  var onImage: ((CMSampleBuffer, Double) -> Void)?
  var onError: ((OSStatus) -> Void)?

  private var formatDescription: CMVideoFormatDescription?
  private var session: VTDecompressionSession?
  private var waitingForKeyframe = true
  private var invalidated = false

  func invalidate() {
    invalidated = true
    if let session = session {
      VTDecompressionSessionInvalidate(session)
    }
    session = nil
    formatDescription = nil
  }

  func requireKeyframe() {
    waitingForKeyframe = true
  }

  /// A codec-config packet carries SPS and PPS.
  func configure(annexB buffer: OwnedBuffer) {
    guard !invalidated else { return }
    let nals = AnnexB.split(buffer.pointer, buffer.length)
    var sps: (UnsafePointer<UInt8>, Int)?
    var pps: (UnsafePointer<UInt8>, Int)?
    for nal in nals {
      switch nal.type {
      case 7: sps = (UnsafePointer(buffer.pointer + nal.offset), nal.length)
      case 8: pps = (UnsafePointer(buffer.pointer + nal.offset), nal.length)
      default: break
      }
    }
    guard let sps = sps, let pps = pps else { return }
    let pointers: [UnsafePointer<UInt8>] = [sps.0, pps.0]
    let sizes: [Int] = [sps.1, pps.1]
    var description: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
      allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
      parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
    guard status == noErr, let newDescription = description else {
      onError?(status)
      return
    }
    if let session = session,
      VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newDescription)
    {
      formatDescription = newDescription
      return
    }
    if let session = session {
      VTDecompressionSessionInvalidate(session)
      self.session = nil
    }
    formatDescription = newDescription
    createSession()
    waitingForKeyframe = true
  }

  private func createSession() {
    guard let formatDescription = formatDescription else { return }
    let decoderSpec: [CFString: Any] = [
      kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
    ]
    let imageAttributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var newSession: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault, formatDescription: formatDescription,
      decoderSpecification: decoderSpec as CFDictionary,
      imageBufferAttributes: imageAttributes as CFDictionary, outputCallback: nil,
      decompressionSessionOut: &newSession)
    guard status == noErr, let created = newSession else {
      onError?(status)
      return
    }
    VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    session = created
  }

  /// Returns false when the packet was skipped or failed.
  @discardableResult
  func decode(annexB buffer: OwnedBuffer, ptsUs: Int64, isKey: Bool) -> Bool {
    guard !invalidated, let session = session, let formatDescription = formatDescription else {
      return false
    }
    if waitingForKeyframe && !isKey {
      return false
    }
    guard let avcc = AnnexB.toAvcc(buffer) else { return false }
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: avcc.pointer, blockLength: avcc.length,
      blockAllocator: kCFAllocatorMalloc, customBlockSource: nil, offsetToData: 0,
      dataLength: avcc.length, flags: 0, blockBufferOut: &blockBuffer)
    guard status == kCMBlockBufferNoErr, let block = blockBuffer else {
      free(avcc.pointer)
      return false
    }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000),
      decodeTimeStamp: .invalid)
    var sampleSize = avcc.length
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
      sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
    guard status == noErr, let sample = sampleBuffer else { return false }

    let started = CACurrentMediaTime()
    var produced = false
    let decodeStatus = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
    ) {
      [weak self]
      (status: OSStatus, _: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?,
        presentationTime: CMTime, _: CMTime) in
      guard let self = self else { return }
      guard status == noErr, let imageBuffer = imageBuffer else {
        if status != noErr {
          self.onError?(status)
        }
        return
      }
      produced = true
      if let display = H264Decoder.displaySample(imageBuffer, pts: presentationTime) {
        self.onImage?(display, (CACurrentMediaTime() - started) * 1000)
      }
    }
    if decodeStatus != noErr {
      waitingForKeyframe = true
      if decodeStatus == kVTInvalidSessionErr {
        VTDecompressionSessionInvalidate(session)
        self.session = nil
        createSession()
      }
      onError?(decodeStatus)
      return false
    }
    if isKey {
      waitingForKeyframe = false
    }
    return produced
  }

  private static func displaySample(_ imageBuffer: CVImageBuffer, pts: CMTime) -> CMSampleBuffer? {
    var description: CMVideoFormatDescription?
    guard
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescriptionOut: &description)
        == noErr, let format = description
    else { return nil }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescription: format,
        sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let result = sample
    else { return nil }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true),
      CFArrayGetCount(attachments) > 0
    {
      let dictionary = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return result
  }
}

/// Annex-B helpers. MediaCodec separates NAL units with 00 00 00 01 or
/// 00 00 01 start codes.
enum AnnexB {
  struct Nal {
    let offset: Int
    let length: Int
    let type: UInt8
  }

  static func split(_ data: UnsafePointer<UInt8>, _ length: Int) -> [Nal] {
    var starts: [(codeStart: Int, payload: Int)] = []
    var index = 0
    while index + 2 < length {
      if data[index] == 0 && data[index + 1] == 0 {
        if data[index + 2] == 1 {
          starts.append((index, index + 3))
          index += 3
          continue
        }
        if index + 3 < length && data[index + 2] == 0 && data[index + 3] == 1 {
          starts.append((index, index + 4))
          index += 4
          continue
        }
      }
      index += 1
    }
    var nals: [Nal] = []
    for (position, start) in starts.enumerated() {
      let end = position + 1 < starts.count ? starts[position + 1].codeStart : length
      let nalLength = end - start.payload
      if nalLength > 0 {
        nals.append(Nal(offset: start.payload, length: nalLength, type: data[start.payload] & 0x1F))
      }
    }
    return nals
  }

  /// Converts to length-prefixed (AVCC) NAL units, dropping parameter sets
  /// and access-unit delimiters. Returns a malloc'd buffer.
  static func toAvcc(_ buffer: OwnedBuffer) -> (pointer: UnsafeMutablePointer<UInt8>, length: Int)? {
    let nals = split(buffer.pointer, buffer.length).filter { $0.type != 7 && $0.type != 8 && $0.type != 9 }
    if nals.isEmpty {
      return nil
    }
    let total = nals.reduce(0) { $0 + 4 + $1.length }
    guard let out = malloc(total)?.assumingMemoryBound(to: UInt8.self) else { return nil }
    var cursor = 0
    for nal in nals {
      let size = UInt32(nal.length).bigEndian
      withUnsafeBytes(of: size) { bytes in
        for byte in 0..<4 {
          out[cursor + byte] = bytes[byte]
        }
      }
      cursor += 4
      memcpy(out + cursor, buffer.pointer + nal.offset, nal.length)
      cursor += nal.length
    }
    return (out, total)
  }
}
