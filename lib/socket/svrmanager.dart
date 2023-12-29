import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

abstract class ISocketEvent {
  void onError();

  void onMessage(String message);

  void onClose();

  void onConnect();
}

class WsSvrManager {
  late WebSocketSink? _sink;
  late ISocketEvent? _event;

  void setEvent(ISocketEvent event) {
    _event = event;
  }

  Future<void> startServer(int port) async {
    var handler = webSocketHandler((webSocket) {
      _sink = webSocket.sink;
      webSocket.stream.listen((message) {
        _listen(message);
      });
    });

    shelf_io.serve(handler, '0.0.0.0', port, shared: true).then((server) {
      var host = "${server.address.host}:${server.port}";
      print('Serving at ws://$host');
    });
  }

  Future<void> connectToServer(String host, var callback) async {
    final wsUrl = Uri.parse('ws://$host');
    WebSocketChannel channel = WebSocketChannel.connect(wsUrl);
    await channel.ready;
    _sink = channel.sink;
    channel.stream.listen((message) {
      _listen(message);
    });
  }

  void close() {
    _sink?.close();
  }

  void sendMessage(String message) {
    _sink?.add(utf8.encode(message));
  }

  void _listen(Uint8List data) {
    _event?.onMessage(utf8.decode(data));
  }
}
