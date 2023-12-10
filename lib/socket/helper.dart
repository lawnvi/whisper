import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

Future<String> getLocalIpAddress() async {
  Completer<String> completer = Completer<String>();

  try {
    for (var interface in await NetworkInterface.list()) {
      for (var addr in interface.addresses) {
        if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
          completer.complete(addr.address);
          return completer.future;
        }
      }
    }
    completer.completeError('No local IP address found');
  } catch (e) {
    completer.completeError('Error getting local IP address: $e');
  }

  return completer.future;
}

void socketSendFile(Socket socket, String path) async {
  final file = File(path);
  final fs = file.openRead();
  final size = file.lengthSync();
  final name = p.basename(path);
  socket.add(utf8.encode("____start_file_stream:$size:$name"));
  print("start send $name, size: $size");
  await for (var data in fs) {
    socket.add(data);
  }
  print("send signal over 0");
}