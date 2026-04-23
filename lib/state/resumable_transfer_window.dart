import 'dart:math' as math;

const int defaultTransferDurableFlushWindowBytes = 256 * 1024 * 1024;
const int defaultTransferUiProgressWindowBytes = 512 * 1024;
const Duration defaultTransferUiProgressInterval = Duration(milliseconds: 150);

class TransferFrameRange {
  const TransferFrameRange({
    required this.offset,
    required this.length,
  });

  final int offset;
  final int length;
}

List<TransferFrameRange> buildTransferWindowFrames({
  required int startOffset,
  required int totalSize,
  required int windowSize,
  required int framePayloadSize,
}) {
  if (startOffset < 0 ||
      totalSize < 0 ||
      windowSize <= 0 ||
      framePayloadSize <= 0) {
    throw ArgumentError('Invalid transfer window arguments');
  }
  if (startOffset >= totalSize) {
    return const <TransferFrameRange>[];
  }

  final windowEnd = math.min(totalSize, startOffset + windowSize);
  final ranges = <TransferFrameRange>[];
  var offset = startOffset;
  while (offset < windowEnd) {
    final length = math.min(framePayloadSize, windowEnd - offset);
    ranges.add(TransferFrameRange(offset: offset, length: length));
    offset += length;
  }
  return ranges;
}

List<TransferFrameRange> buildTransferRawPayloadFrames({
  required int startOffset,
  required int payloadLength,
  required int rawFramePayloadSize,
}) {
  if (startOffset < 0 || payloadLength < 0 || rawFramePayloadSize <= 0) {
    throw ArgumentError('Invalid raw payload frame arguments');
  }
  if (payloadLength == 0) {
    return const <TransferFrameRange>[];
  }

  final ranges = <TransferFrameRange>[];
  var relativeOffset = 0;
  while (relativeOffset < payloadLength) {
    final length =
        math.min(rawFramePayloadSize, payloadLength - relativeOffset);
    ranges.add(
      TransferFrameRange(
        offset: startOffset + relativeOffset,
        length: length,
      ),
    );
    relativeOffset += length;
  }
  return ranges;
}

bool shouldReportTransferProgress({
  required int bytesSinceLastProgress,
  required int committedBytes,
  required int totalSize,
  required int progressWindowBytes,
}) {
  return committedBytes >= totalSize ||
      bytesSinceLastProgress >= progressWindowBytes;
}

bool shouldEmitTransferUiProgress({
  required int bytesSinceLastUiProgress,
  required Duration elapsedSinceLastUiProgress,
  required int committedBytes,
  required int totalSize,
  int progressWindowBytes = defaultTransferUiProgressWindowBytes,
  Duration progressInterval = defaultTransferUiProgressInterval,
  bool force = false,
}) {
  if (force || committedBytes >= totalSize) {
    return true;
  }
  return bytesSinceLastUiProgress >= progressWindowBytes &&
      elapsedSinceLastUiProgress >= progressInterval;
}

bool shouldFlushTransferCheckpoint({
  required int bytesSinceLastFlush,
  required int committedBytes,
  required int totalSize,
  int flushWindowBytes = defaultTransferDurableFlushWindowBytes,
}) {
  return committedBytes >= totalSize || bytesSinceLastFlush >= flushWindowBytes;
}
