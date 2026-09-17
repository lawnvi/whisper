import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

typedef WindowsNetworkInterface = ({int index, int type, String description});

/// Read driver descriptions because user-facing names can be localized or renamed.
Future<List<WindowsNetworkInterface>?> windowsNetworkInterfaces() async {
  if (!Platform.isWindows) return null;
  try {
    return await Isolate.run(_queryAdapters);
  } on Object {
    return null;
  }
}

List<WindowsNetworkInterface>? _queryAdapters() {
  final size = calloc<Uint32>()..value = 15000;
  try {
    for (var attempt = 0; attempt < 3; attempt++) {
      final buffer = calloc<Uint8>(size.value);
      try {
        final adapters = buffer.cast<IP_ADAPTER_ADDRESSES_LH>();
        final result = GetAdaptersAddresses(
          0, // AF_UNSPEC: include both IPv4 and IPv6 interfaces.
          GAA_FLAG_INCLUDE_ALL_INTERFACES |
              GAA_FLAG_SKIP_UNICAST |
              GAA_FLAG_SKIP_ANYCAST |
              GAA_FLAG_SKIP_MULTICAST |
              GAA_FLAG_SKIP_DNS_SERVER,
          nullptr,
          adapters,
          size,
        );
        if (result == ERROR_BUFFER_OVERFLOW) continue;
        if (result == ERROR_NO_DATA) return const [];
        if (result != NO_ERROR) return null;
        final interfaces = <WindowsNetworkInterface>[];
        for (
          var current = adapters;
          current != nullptr;
          current = current.ref.Next
        ) {
          final adapter = current.ref;
          interfaces.add((
            index: adapter.IfIndex,
            type: adapter.IfType,
            description: adapter.Description == nullptr
                ? ''
                : adapter.Description.toDartString(),
          ));
        }
        return interfaces;
      } finally {
        calloc.free(buffer);
      }
    }
    return null;
  } finally {
    calloc.free(size);
  }
}
