import 'dart:convert';
import 'dart:io';
import 'package:whisper/socket/helper.dart';
import 'package:path_provider/path_provider.dart';

class SocketServerManager {
  ServerSocket? _serverSocket;
  int _port = 4567; // 替换为你需要的端口号
  String _host = "";
  IOSink? sink;
  int size = 0;

  bool get isRunning => _serverSocket != null;
  late Socket _client;

  Future<String> startServer(var callback) async {
    if (_serverSocket != null) return _host; // 如果服务器已经在运行，则直接返回

    try {
      _serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, _port);
      print(
          'Server listening on ${_serverSocket!.address}:${_serverSocket!.port}');
      _host = "${_serverSocket!.address}:${_serverSocket!.port}";
      _serverSocket!.listen(
        (Socket clientSocket) {
          _client = clientSocket;
          print(
              'Incoming connection from ${clientSocket.remoteAddress}:${clientSocket.remotePort}');
          clientSocket.listen(
            (List<int> data) {
              try {
                String message = utf8.decode(data);
                print('Received data: $message}');
                if (sink == null && message.startsWith("____start_file_stream")) {
                  prepareRecvFile(message.substring(22));
                }

                // 处理接收到的数据
                if (sink == null) {
                  callback(message);
                }
              }catch(e) {
                // print("recv decode err: $e");
              }

              if (sink != null && size > 0) {
                sink?.add(data);
                size -= data.length;
                print("recv ${data.length}, left: $size");
                if (size == 0) {
                  sink?.close();
                  sink = null;
                  print("recv over");
                }
              }
            },
            onError: (error) {
              print('Error: $error');
            },
            onDone: () {
              print('Connection closed');
            },
          );
        },
        onError: (error) {
          print('Server error: $error');
        },
      );
    } catch (e) {
      print('Error starting server: $e');
    }

    return _host;
  }

  void prepareRecvFile(String info) async {
    List<String> ls = info.split(":");
    size = int.parse(ls[0]);
    String name = ls[1];
    var appDir = await getApplicationDocumentsDirectory();
    File file = File('${appDir.path}/$name');
    sink = file.openWrite();
    print("prepare recv: ${appDir.path}/$name size: $size");
  }

  void write2file(List<int> bytes) {
    sink?.add(bytes);
  }

  void sendMessageToClient(String message) {
    _client.add(utf8.encode(message));
  }

  void sendFile(String path) async {
    socketSendFile(_client, path);
  }

  void stopServer() {
    _serverSocket?.close();
    _serverSocket = null;
    print('Server stopped');
  }
}
