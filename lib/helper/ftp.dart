import 'package:ftp_server/ftp_server.dart';
import 'package:ftp_server/server_type.dart';

class SimpleFtpServer {
  static final SimpleFtpServer _singleton = SimpleFtpServer._internal();

  // 私有构造函数，阻止类被直接实例化
  SimpleFtpServer._internal();

  // 工厂构造函数，返回单例实例
  factory SimpleFtpServer() {
    return _singleton;
  }

  FtpServer? _ftpServer;

  void start(String path, int port) async {
    _ftpServer = FtpServer(
        port,
        allowedDirectories: [path],
        startingDirectory: path,
        serverType: ServerType.readAndWrite,
        logFunction: (String message){
          print(message);
        }
    );
    await _ftpServer?.start();
  }

  void stop() async {
    await _ftpServer!.stop();
    _ftpServer = null;
  }

  bool isActive() {
    return _ftpServer != null;
  }
}