import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/new_ui/shell/device_row_status.dart';

void main() {
  group('the second line of a device row', () {
    test('connecting comes first, whatever else is going on', () {
      expect(
        deviceRowLine(
          const DeviceRowFacts(
            connecting: true,
            connected: true,
            transferName: 'log.txt',
          ),
        ),
        DeviceRowLine.connecting,
      );
    });

    test('a device that is not connected says where it is', () {
      expect(
        deviceRowLine(const DeviceRowFacts(nearby: true)),
        DeviceRowLine.nearbyUnpaired,
      );
      expect(
        deviceRowLine(const DeviceRowFacts(nearby: true, paired: true)),
        DeviceRowLine.nearby,
      );
      expect(deviceRowLine(const DeviceRowFacts()), DeviceRowLine.offline);
    });

    test('being away beats activity left over from before', () {
      expect(
        deviceRowLine(
          const DeviceRowFacts(paired: true, transferName: 'log.txt'),
        ),
        DeviceRowLine.offline,
      );
    });

    test('activity goes in the order of the design', () {
      const all = DeviceRowFacts(
        connected: true,
        transferName: 'log.txt',
        soundHere: true,
        controllingThis: true,
        pointerThere: true,
        playingOurs: true,
        flowWindows: 2,
        preview: 'hi',
      );
      expect(deviceRowLine(all), DeviceRowLine.transfer);
      expect(
        deviceRowLine(
          const DeviceRowFacts(
            connected: true,
            soundHere: true,
            controllingThis: true,
          ),
        ),
        DeviceRowLine.soundHere,
      );
      expect(
        deviceRowLine(
          const DeviceRowFacts(
            connected: true,
            controllingThis: true,
            pointerThere: true,
          ),
        ),
        DeviceRowLine.controllingThis,
      );
      expect(
        deviceRowLine(
          const DeviceRowFacts(
            connected: true,
            pointerThere: true,
            playingOurs: true,
          ),
        ),
        DeviceRowLine.pointerThere,
      );
      expect(
        deviceRowLine(
          const DeviceRowFacts(
            connected: true,
            playingOurs: true,
            flowWindows: 1,
          ),
        ),
        DeviceRowLine.playingOurs,
      );
      expect(
        deviceRowLine(const DeviceRowFacts(connected: true, flowWindows: 1)),
        DeviceRowLine.flowWindows,
      );
      expect(
        deviceRowLine(const DeviceRowFacts(connected: true, preview: 'hi')),
        DeviceRowLine.preview,
      );
    });

    test('only what is happening now is in the accent colour', () {
      expect(deviceRowLineIsLive(DeviceRowLine.transfer), isTrue);
      expect(deviceRowLineIsLive(DeviceRowLine.flowWindows), isTrue);
      expect(deviceRowLineIsLive(DeviceRowLine.preview), isFalse);
      expect(deviceRowLineIsLive(DeviceRowLine.connecting), isFalse);
      expect(deviceRowLineIsLive(DeviceRowLine.offline), isFalse);
    });
  });
}
