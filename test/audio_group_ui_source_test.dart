import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/source_reading.dart';

void main() {
  test('desktop sidebar exposes a multi-sink audio group setup flow', () {
    final source = deviceListSource();

    expect(
        source,
        contains(
            "import 'package:whisper/audio/audio_group_coordinator.dart';"));
    expect(source,
        contains("import 'package:whisper/audio/audio_protocol.dart';"));
    expect(
        source, contains('final AudioGroupCoordinator _audioGroupCoordinator'));
    expect(source, contains('_buildDesktopSidebarToolbar'));
    expect(source, contains('_buildDesktopAudioShareAction'));
    expect(source, contains('_toggleDesktopAudioShare'));
    expect(source, contains('_showAudioGroupSetupSheet'));
    expect(source, contains('connectedAudioGroupSinkDevices'));
    expect(source, contains('sendAudioGroupControlTo'));
    expect(source, contains('AudioChannelRole.left'));
    expect(source, contains('AudioChannelRole.right'));
  });

  test('single selected sink from the group sheet still uses group routing',
      () {
    final source = deviceListSource();

    expect(source, isNot(contains('if (sinks.length > 1)')));
    expect(source, contains('_audioGroupCoordinator.startGroup('));
  });

  test('one connected group-capable sink starts group playback directly', () {
    final source = deviceListSource();

    expect(source, contains('groupCandidates.length == 1'));
    expect(source, contains('groupCandidates.single.uid'));
    expect(source, contains('AudioChannelRole.stereo'));
  });

  test('active desktop audio button opens adjustment sheet before stopping',
      () {
    final source = deviceListSource();
    final tooltip = memberSource(source, 'String _desktopAudioShareTooltip');
    final toggle = memberSource(source, 'Future<void> _toggleDesktopAudioShare');
    final sheet = memberSource(
      source,
      'Future<_AudioGroupSetupResult?> _showAudioGroupSetupSheet',
    );

    expect(tooltip, contains('l10n.audioGroupAdjust'));
    expect(toggle, contains('_showActiveDesktopAudioGroupSetup'));
    expect(
        toggle,
        isNot(contains('audioGroupSession?.isLive == true) {\n'
            '        await _audioGroupCoordinator.stopGroup')));
    expect(source,
        contains('Map<String, AudioChannelRole> _activeAudioGroupSinks'));
    expect(source, contains('Future<void> _applyDesktopAudioGroupSelection'));
    expect(source, contains('_audioGroupCoordinator.updateGroup('));
    expect(sheet, contains('initialSinks'));
    expect(sheet, contains('allowStop'));
    expect(sheet, contains('applyingActiveConfig'));
    expect(sheet, contains('l10n.audioGroupApply'));
    expect(sheet, contains('l10n.audioGroupStop'));
  });

  test('desktop audio group sheet shows synchronization evidence', () {
    final source = deviceListSource();
    final sheet = memberSource(
      source,
      'Future<_AudioGroupSetupResult?> _showAudioGroupSetupSheet',
    );

    expect(sheet, contains('AnimatedBuilder'));
    expect(sheet, contains('_buildAudioGroupSinkSubtitle'));
    expect(source, contains('_audioGroupSyncEvidenceLabel'));
    expect(source, contains('audioGroupSyncEvidenceCompact'));
    expect(source, contains('latePacketCount'));
    expect(source, contains('syncErrorMicros'));
  });

  test('socket manager exposes connected audio group sink devices for UI', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source, contains('List<DeviceData> connectedAudioGroupSinkDevices'));
    expect(source, contains('supportsAudioGroupSinkFor(peerId)'));
    expect(source, contains('preferredPeerId'));
  });
}
