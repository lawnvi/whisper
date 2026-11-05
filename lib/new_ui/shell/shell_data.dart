import 'package:flutter/widgets.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/shell/device_row_status.dart';
import 'package:whisper/new_ui/shell/shell_palette.dart';
import 'package:whisper/state/chat_session_list.dart';
import 'package:whisper/widget/context_menu_region.dart';

/// What the content area shows: a device, or one of the pages opened from the
/// bottom left. Those are not about one device, so the sidebar lets go.
enum ShellPlace { device, links, sound, input }

/// What the device list screen knows, for the shell to draw.
class ShellData {
  const ShellData({
    required this.self,
    required this.sessions,
    required this.selectedPeerId,
    required this.factsFor,
    required this.isPaired,
    this.place = ShellPlace.device,
    this.loading = false,
    this.lanDown = false,
    this.soundActive = false,
    this.inputActive = false,
    this.linksActive = false,
    this.soundSupported = true,
    this.inputSupported = true,
    this.linksSupported = true,
  });

  final DeviceData? self;
  final List<ChatSessionItem> sessions;
  final String? selectedPeerId;
  final DeviceRowFacts Function(ChatSessionItem) factsFor;
  final bool Function(DeviceData) isPaired;
  final bool loading;
  final ShellPlace place;

  /// No local network: nothing can find this device.
  final bool lanDown;

  /// Whether what the bottom left buttons open is running right now.
  final bool soundActive, inputActive, linksActive;
  final bool soundSupported, inputSupported, linksSupported;

  ChatSessionItem? get selected {
    for (final session in sessions) {
      if (session.device.uid == selectedPeerId) return session;
    }
    return null;
  }
}

/// What it can do. The screen keeps every lifecycle the app relies on: server,
/// discovery, tray, quick send, shutdown. The shell only asks.
class ShellActions {
  const ShellActions({
    required this.select,
    required this.connect,
    required this.disconnect,
    required this.openPairing,
    required this.removeDevice,
    required this.contextActions,
    required this.sendDropped,
    required this.openSound,
    required this.openInput,
    required this.openShareLinks,
    required this.openSettings,
    required this.openDiagnostics,
    required this.openSelfNotes,
    required this.buildConversation,
    required this.buildFiles,
    required this.buildApps,
    required this.buildSelfPanel,
    required this.buildPlace,
    required this.buildCard,
    required this.paletteItems,
    required this.searchMessages,
    this.buildTouchCard,
    this.canControl,
    this.openControl,
  });

  final ValueChanged<String?> select;
  final ValueChanged<DeviceData> connect, disconnect;
  final Future<void> Function({bool startWithAddress}) openPairing;
  final Future<void> Function(String uid) removeDevice;

  /// A row's context menu, with [openCard] among the items where it helps.
  final List<ContextMenuActionItem> Function(
    DeviceData device, {
    VoidCallback? openCard,
  })
  contextActions;

  /// Files were dropped on a connected device in the list.
  final void Function(DeviceData target, List<String> paths) sendDropped;
  final VoidCallback openSound, openInput, openShareLinks, openSettings;

  /// 本机: a conversation with this device, for when there is nobody else.
  final VoidCallback openSelfNotes;
  final ValueChanged<DeviceData> openDiagnostics;

  /// The three pages of a device. Built when first shown, then kept.
  final Widget Function(BuildContext, DeviceData) buildConversation;
  final Widget Function(BuildContext, DeviceData) buildFiles;
  final Widget Function(BuildContext, DeviceData) buildApps;
  final Widget Function(BuildContext) buildSelfPanel;

  /// The page of a place that is not a device, under its toolbar.
  final Widget Function(
    BuildContext,
    ShellPlace,
    double rightInset, {
    GlobalKey? titleKey,
    GlobalKey? controlsKey,
  })
  buildPlace;
  final Widget Function(BuildContext, DeviceData, VoidCallback close) buildCard;

  /// A device's card on touch. [page] is the compact size class's device page,
  /// with [onOpenTab] behind its round entries; otherwise it is the card, which
  /// has none because the toolbar has the tabs.
  final Widget Function(
    BuildContext,
    DeviceData, {
    required bool page,
    required VoidCallback onClose,
    required ValueChanged<int> onOpenTab,
  })?
  buildTouchCard;

  /// Whether the toolbar offers to control [DeviceData] from this touch screen:
  /// a connected computer that accepts it.
  final bool Function(DeviceData)? canControl;
  final ValueChanged<DeviceData>? openControl;

  /// What ⌘K can find: devices, pages and actions, then chat history.
  final List<PaletteItem> Function(BuildContext) paletteItems;
  final Future<List<PaletteItem>> Function(BuildContext, String) searchMessages;
}
