// class Message {
//   int id = 0;
//   int type = 0;
//   int size = 0;
//   String sender = "";
//   String receiver = "";
//   String name = "";
//   String content = "";
// }
//
// enum MessageType {
//   unknown,
//   text,
//   image,
//   video,
//   file,
//   copy
// }


class Message {
  String sender = "";
  String receiver = "";
  MessageEnum type = MessageEnum.Heartbeat;
  int size = 0;
  String name = "";
  bool clipboard = false;
}

enum MessageEnum {
  Heartbeat,
  Text,
  File
}
