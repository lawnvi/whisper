part of 'nfs_server.dart';

/// Record marking (RFC 5531 §11): fragments of a record, the last one
/// flagged, each with a 4-byte length.
class _RecordReader {
  final _chunks = <Uint8List>[];
  int _buffered = 0;
  final _fragments = BytesBuilder(copy: false);

  void add(Uint8List chunk) {
    _chunks.add(chunk);
    _buffered += chunk.length;
  }

  List<Uint8List> take() {
    final records = <Uint8List>[];
    while (_buffered >= 4) {
      final header = ByteData.sublistView(_peek(4)).getUint32(0);
      final length = header & 0x7fffffff;
      if (_buffered < 4 + length) {
        break;
      }
      _consume(4);
      _fragments.add(_consume(length));
      if (header & 0x80000000 != 0) {
        records.add(_fragments.takeBytes());
      }
    }
    return records;
  }

  Uint8List _peek(int count) {
    final out = Uint8List(count);
    var at = 0;
    for (final chunk in _chunks) {
      final n = min(count - at, chunk.length);
      out.setRange(at, at + n, chunk);
      at += n;
      if (at == count) {
        break;
      }
    }
    return out;
  }

  Uint8List _consume(int count) {
    final out = Uint8List(count);
    var at = 0;
    while (at < count) {
      final chunk = _chunks.first;
      final n = min(count - at, chunk.length);
      out.setRange(at, at + n, chunk);
      at += n;
      if (n == chunk.length) {
        _chunks.removeAt(0);
      } else {
        _chunks[0] = Uint8List.sublistView(chunk, n);
      }
    }
    _buffered -= count;
    return out;
  }
}

class _Xdr {
  _Xdr(this._data) : _view = ByteData.sublistView(_data);

  final Uint8List _data;
  final ByteData _view;
  int _at = 0;

  int u32() {
    final value = _view.getUint32(_at);
    _at += 4;
    return value;
  }

  int u64() {
    final value = _view.getUint64(_at);
    _at += 8;
    return value;
  }

  Uint8List fixed(int length) {
    if (_at + length > _data.length) {
      throw RangeError('short');
    }
    final value = Uint8List.sublistView(_data, _at, _at + length);
    _at += length;
    return value;
  }

  Uint8List opaque() {
    final length = u32();
    final value = fixed(length);
    _at += (4 - length % 4) % 4;
    return value;
  }

  String string() => utf8.decode(opaque(), allowMalformed: true);

  bool boolean() => u32() != 0;
}

class _XdrOut {
  final _out = BytesBuilder(copy: false);

  void u32(int value) =>
      _out.add((ByteData(4)..setUint32(0, value)).buffer.asUint8List());

  void u64(int value) =>
      _out.add((ByteData(8)..setUint64(0, value)).buffer.asUint8List());

  void boolean(bool value) => u32(value ? 1 : 0);

  void fixed(Uint8List data) {
    _out.add(data);
    final pad = (4 - data.length % 4) % 4;
    if (pad > 0) {
      _out.add(Uint8List(pad));
    }
  }

  void opaque(Uint8List data) {
    u32(data.length);
    fixed(data);
  }

  void string(String value) => opaque(utf8.encode(value));

  void raw(Uint8List data) => _out.add(data);

  Uint8List bytes() => _out.toBytes();
}
