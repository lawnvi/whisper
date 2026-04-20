import 'dart:io';

import 'package:flutter/material.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/widget/context_menu_region.dart';

class ChatMessageList extends StatelessWidget {
  final Widget Function(MessageData message, bool isOpponent) buildFileMessage;
  final Widget Function(MessageData message, bool isOpponent) buildTextMessage;
  final ScrollController controller;
  final GlobalKey<AnimatedListState> listKey;
  final List<MessageData> messages;
  final void Function(String path) onOpenContainingFolder;
  final void Function(String path) onOpenFile;
  final void Function(String content) onCopyText;
  final Future<void> Function(MessageData message, {bool deleteFile})
      onDeleteMessage;
  final String? selfUid;

  const ChatMessageList({
    super.key,
    required this.buildFileMessage,
    required this.buildTextMessage,
    required this.controller,
    required this.listKey,
    required this.messages,
    required this.onOpenContainingFolder,
    required this.onOpenFile,
    required this.onCopyText,
    required this.onDeleteMessage,
    required this.selfUid,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Align(
      alignment: Alignment.topCenter,
      child: AnimatedList(
        key: listKey,
        controller: controller,
        initialItemCount: messages.length,
        reverse: true,
        shrinkWrap: true,
        itemBuilder: (context, index, animation) {
          final message = messages[index];
          final isOpponent = message.receiver == selfUid;
          final isFile = message.type == MessageEnum.File;

          return FadeTransition(
            opacity: animation,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              child: Column(
                crossAxisAlignment: isOpponent
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.end,
                children: [
                  Container(
                    alignment: isOpponent
                        ? Alignment.centerLeft
                        : Alignment.centerRight,
                    child: ContextMenuRegion(
                      items: [
                        if (!isFile)
                          ContextMenuActionItem(
                            label: AppLocalizations.of(context)?.copyMessage ??
                                '复制消息',
                            onSelected: () {
                              if (message.content?.isNotEmpty == true) {
                                onCopyText(message.content!);
                              }
                            },
                          ),
                        if (!isFile)
                          ContextMenuActionItem(
                            label: AppLocalizations.of(context)?.delete ?? '删除',
                            onSelected: () {
                              onDeleteMessage(message);
                            },
                          ),
                        if (isFile && (isOpponent || isDesktop()))
                          ContextMenuActionItem(
                            label: AppLocalizations.of(context)?.open ?? '打开',
                            onSelected: () {
                              onOpenFile(message.path);
                            },
                          ),
                        if (isFile && (isOpponent || isDesktop()))
                          ContextMenuActionItem(
                            label: (Platform.isMacOS
                                    ? AppLocalizations.of(context)?.openInFinder
                                    : AppLocalizations.of(context)
                                        ?.openInDir) ??
                                '所在文件夹',
                            onSelected: () {
                              onOpenContainingFolder(message.path);
                            },
                          ),
                        if (isFile && isOpponent)
                          ContextMenuActionItem(
                            label:
                                '${AppLocalizations.of(context)?.delete ?? '删除'} (${AppLocalizations.of(context)?.keepFile ?? '保留文件'})',
                            onSelected: () {
                              onDeleteMessage(message);
                            },
                          ),
                        if (isFile && isOpponent)
                          ContextMenuActionItem(
                            label:
                                '${AppLocalizations.of(context)?.delete ?? '删除'} (${AppLocalizations.of(context)?.deleteFile ?? '删除文件'})',
                            onSelected: () {
                              onDeleteMessage(message, deleteFile: true);
                            },
                          ),
                        if (isFile && !isOpponent)
                          ContextMenuActionItem(
                            label: AppLocalizations.of(context)?.delete ?? '删除',
                            onSelected: () {
                              onDeleteMessage(message);
                            },
                          ),
                      ],
                      child: GestureDetector(
                        onTap: () {
                          if (isFile) {
                            onOpenFile(message.path);
                          }
                        },
                        onLongPress: () {},
                        child: isFile
                            ? buildFileMessage(message, isOpponent)
                            : buildTextMessage(message, isOpponent),
                      ),
                    ),
                  ),
                  SizedBox(height: message.type == MessageEnum.File ? 4 : 2),
                  Stack(
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: isOpponent
                                ? isMobile()
                                    ? 10
                                    : 0
                                : 20,
                          ),
                          Text(
                            " ${formatTimestamp(message.timestamp)} ",
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          SizedBox(
                            width: isOpponent
                                ? 20
                                : isMobile()
                                    ? 10
                                    : 0,
                          ),
                        ],
                      ),
                      if (message.type == MessageEnum.Text)
                        Positioned(
                          left: isOpponent ? null : -12,
                          right: isOpponent ? -12 : null,
                          top: Platform.isMacOS ? -12.2 : -14,
                          child: IconButton(
                            hoverColor: Colors.grey.withOpacity(0),
                            focusColor: Colors.grey,
                            highlightColor: Colors.transparent,
                            icon: Icon(
                              Icons.copy,
                              size: isMobile() ? 16 : 18,
                              color: colorScheme.onSurfaceVariant,
                            ),
                            onPressed: () {
                              if (message.content?.isNotEmpty == true) {
                                onCopyText(message.content!);
                              }
                            },
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
