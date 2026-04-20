import 'package:flutter/material.dart';
import 'package:whisper/theme/app_theme.dart';

class ChatConnectionBanner extends StatelessWidget {
  final bool connected;

  const ChatConnectionBanner({
    super.key,
    required this.connected,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            connected ? Icons.link_rounded : Icons.link_off_rounded,
            color: connected ? palette.connected : colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              connected ? '当前已连接，可以直接传文本和文件' : '当前未连接，仍可查看历史消息',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
