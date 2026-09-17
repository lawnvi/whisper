import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/cast_receiver/upnp.dart';
import 'package:xml/xml.dart';

void main() {
  test('advertises a renderer with control and event endpoints', () {
    final document = XmlDocument.parse(
      deviceDescription('Whisper Media Receiver', 'uuid:test'),
    );
    expect(
      document.findAllElements('deviceType').single.innerText,
      rendererType,
    );
    expect(document.findAllElements('controlURL').length, actions.length);
    expect(document.findAllElements('eventSubURL').length, actions.length);
  });

  test('service descriptions expose every action argument', () {
    for (final service in actions.keys) {
      final document = XmlDocument.parse(serviceDescription(service));
      final names = document
          .findAllElements('stateVariable')
          .map((element) => element.getElement('name')!.innerText)
          .toSet();
      for (final related in document.findAllElements('relatedStateVariable')) {
        expect(names, contains(related.innerText));
      }
    }
  });

  test('SOAP values are escaped and media time is bounded', () {
    final body = soapResponse('AVTransport', 'GetPositionInfo', {
      'TrackURI': 'https://example.com/a?x=1&y=2',
    });
    expect(body, contains('&amp;'));
    expect(timeText(-1), '00:00:00');
    expect(timeText(3661), '01:01:01');
    expect(timeSeconds('01:01:01.5'), 3661.5);
    expect(timeSeconds('1'), isNull);
  });
}
