import 'package:whisper/theme/radix_colors.dart';

/// The coloured tiles of the settings sections, the one place the interface
/// colours an icon for its own sake (DESIGN.md「色彩」). The same in both themes;
/// 连接 uses `accent`, the one blue.
abstract final class WhisperSettingsIcons {
  static const general = Radix.slate9;
  static const system = Radix.slate11;
  static const sharing = Radix.crimson9;
  static const notifications = Radix.orange9;
  static const about = Radix.slate9;

  /// The hairline along the top of a tile.
  static const highlight = Radix.whiteA5;
}
