import 'dart:io';

enum ServerStartFailure { addressInUse, permissionDenied, unavailable }

ServerStartFailure classifyServerStartFailure(Object? error) {
  final code = switch (error) {
    SocketException(:final osError) => osError?.errorCode,
    OSError(:final errorCode) => errorCode,
    _ => null,
  };
  // errno differs between Darwin, Linux/Android, and Windows Winsock.
  if (const <int>{48, 98, 10048}.contains(code)) {
    return ServerStartFailure.addressInUse;
  }
  if (const <int>{1, 13, 10013}.contains(code)) {
    return ServerStartFailure.permissionDenied;
  }
  return ServerStartFailure.unavailable;
}
