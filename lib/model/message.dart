class Message {
  int id = 0;
  int type = 0;
  int size = 0;
  String sender = "";
  String receiver = "";
  String name = "";
  String content = "";
}

enum MessageType {
  unknown,
  text,
  image,
  video,
  file,
  copy
}
