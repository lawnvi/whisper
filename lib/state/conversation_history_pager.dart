import 'package:flutter/foundation.dart';
import 'package:whisper/model/LocalDatabase.dart';

typedef HistoryPageReader =
    Future<List<MessageData>> Function(int beforeId, int limit);

class ConversationHistoryPager extends ChangeNotifier {
  ConversationHistoryPager(this.read);
  final HistoryPageReader read;
  bool loading = false, hasMore = true, failed = false;
  int _generation = 0;
  bool _disposed = false;
  int get generation => _generation;

  Future<List<MessageData>> load({int beforeId = 0}) async {
    if (_disposed || loading || !hasMore) return const [];
    final generation = _generation;
    final limit = beforeId == 0 ? 20 : 12;
    loading = true;
    failed = false;
    notifyListeners();
    try {
      final page = await read(beforeId, limit);
      if (_disposed || generation != _generation) return const [];
      hasMore = page.length == limit;
      return page;
    } catch (_) {
      if (!_disposed && generation == _generation) failed = true;
      return const [];
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void reset() {
    _generation++;
    loading = false;
    hasMore = true;
    failed = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}

List<MessageData> unseenHistoryMessages(
  List<MessageData> existing,
  List<MessageData> page,
) {
  String identity(MessageData message) =>
      message.uuid.isEmpty ? 'row:${message.id}' : 'uuid:${message.uuid}';
  final seen = existing.map(identity).toSet();
  return page.where((message) => seen.add(identity(message))).toList();
}
