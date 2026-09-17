import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:xml/xml.dart';

import 'player.dart';
import 'request_gate.dart';
import 'upnp.dart';

class ControlError implements Exception {
  const ControlError(this.code, this.message);
  final int code;
  final String message;
}

class Subscription {
  Subscription(this.id, this.service, this.callback);
  final String id;
  final String service;
  final Uri callback;
  // Some senders stop renewing the event subscription while media is playing
  // even though they continue to use the same control endpoint.  The callback
  // itself is the reliable liveness signal; failed NOTIFY requests remove the
  // subscription below.
  DateTime expires = DateTime.now().add(const Duration(days: 1));
  int sequence = 0;
  bool sending = false;
  String lastBody = '';
}

class DlnaReceiver {
  DlnaReceiver(
    this.player,
    this.address,
    this.interface, {
    required this.name,
    this.requests,
  });
  final CastRequestGate? requests;
  final CastPlayer player;
  final InternetAddress address;
  final NetworkInterface interface;
  String name;
  final uuid =
      'uuid:${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join().replaceAllMapped(RegExp(r'(.{8})(.{4})(.{4})(.{4})(.{12})'), (m) => '${m[1]}-${m[2]}-${m[3]}-${m[4]}-${m[5]}')}';
  final multicast = InternetAddress('239.255.255.250');
  final subscriptions = <String, Subscription>{};
  final searchTimers = <Timer>{};
  final httpClient = HttpClient()..findProxy = (_) => 'DIRECT';
  HttpServer? http;
  RawDatagramSocket? ssdp;
  Timer? announceTimer;
  int searches = 0;
  int descriptions = 0;
  int controls = 0;

  List<String> get targets => [
    'upnp:rootdevice',
    uuid,
    rendererType,
    ...actions.keys.map(serviceType),
  ];
  String get baseUrl => 'http://${address.address}:${http!.port}';
  String usn(String target) => target == uuid ? uuid : '$uuid::$target';

  Future<void> start() async {
    try {
      http = await HttpServer.bind(address, 0);
      http!.idleTimeout = const Duration(seconds: 15);
      http!.listen((request) => unawaited(handle(request)));
      ssdp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        1900,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      ssdp!.multicastHops = 2;
      // Membership selects the receiving interface; announcements must also
      // use the selected LAN instead of the VPN or Wi-Fi Direct default route.
      ssdp!.setRawOption(
        RawSocketOption(
          RawSocketOption.levelIPv4,
          RawSocketOption.IPv4MulticastInterface,
          address.rawAddress,
        ),
      );
      ssdp!.joinMulticast(multicast, interface);
      ssdp!.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? packet;
        while ((packet = ssdp?.receive()) != null) {
          discover(packet!);
        }
      });
      announce('ssdp:alive');
      announceTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => announce('ssdp:alive'),
      );
      player.addListener(notifySubscribers);
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void rename(String value) {
    final updated = value.trim();
    if (updated.isEmpty || updated == name) return;
    name = updated;
    if (http != null) announce('ssdp:alive');
  }

  void discover(Datagram packet) {
    if (packet.data.length > 8192 || searchTimers.length >= 64) return;
    final lines = utf8.decode(packet.data, allowMalformed: true).split('\r\n');
    if (lines.first != 'M-SEARCH * HTTP/1.1') return;
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon > 0) {
        headers[line.substring(0, colon).toLowerCase()] = line
            .substring(colon + 1)
            .trim();
      }
    }
    if (headers['man'] != '"ssdp:discover"') return;
    final matches = headers['st'] == 'ssdp:all'
        ? targets
        : targets.where((t) => t == headers['st']);
    if (matches.isEmpty) return;
    searches++;
    final mx = (int.tryParse(headers['mx'] ?? '') ?? 1).clamp(1, 5);
    late Timer timer;
    timer = Timer(Duration(milliseconds: Random().nextInt(mx * 1000)), () {
      searchTimers.remove(timer);
      for (final target in matches) {
        ssdp?.send(
          utf8.encode(
            'HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=90\r\n'
            'EXT:\r\nLOCATION: $baseUrl/description.xml\r\n'
            'SERVER: Whisper/1.0 UPnP/1.0 WhisperMediaReceiver/1.0\r\nST: $target\r\n'
            'USN: ${usn(target)}\r\n\r\n',
          ),
          packet.address,
          packet.port,
        );
      }
    });
    searchTimers.add(timer);
  }

  void announce(String kind) {
    for (final target in targets) {
      ssdp?.send(
        utf8.encode(
          'NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
          'CACHE-CONTROL: max-age=90\r\nLOCATION: $baseUrl/description.xml\r\n'
          'NT: $target\r\nNTS: $kind\r\nUSN: ${usn(target)}\r\n'
          'SERVER: Whisper/1.0 UPnP/1.0 WhisperMediaReceiver/1.0\r\n\r\n',
        ),
        multicast,
        1900,
      );
    }
  }

  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    try {
      final path = request.uri.path;
      response.headers.contentType = ContentType(
        'text',
        'xml',
        charset: 'utf-8',
      );
      if (request.method == 'GET' && path == '/status') {
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'name': name,
            'protocol': 'DLNA media only',
            'searches': searches,
            'descriptions': descriptions,
            'controls': controls,
            'player': player.status,
          }),
        );
      } else if (request.method == 'GET' && path == '/description.xml') {
        descriptions++;
        response.write(deviceDescription(name, uuid));
      } else if (request.method == 'GET' &&
          actions.keys.any((service) => path == '/$service.xml')) {
        response.write(serviceDescription(path.substring(1, path.length - 4)));
      } else if (path.startsWith('/event/') &&
          actions.containsKey(path.substring(7))) {
        subscribe(request, path.substring(7));
      } else if (request.method == 'POST' &&
          path.startsWith('/control/') &&
          actions.containsKey(path.substring(9))) {
        final service = path.substring(9);
        final data = <int>[];
        await for (final chunk in request.timeout(
          const Duration(seconds: 10),
        )) {
          data.addAll(chunk);
          if (data.length > 65536) {
            throw const ControlError(402, 'Invalid Args');
          }
        }
        final xml = XmlDocument.parse(utf8.decode(data));
        final body = xml.rootElement.childElements
            .where((e) => e.localName == 'Body')
            .single;
        final action = body.childElements.single;
        final actionName = action.localName;
        if (!actions[service]!.containsKey(actionName) ||
            action.namespaceUri != serviceType(service)) {
          throw const ControlError(401, 'Invalid Action');
        }
        final args = {
          for (final e in action.childElements) e.localName: e.innerText,
        };
        final required = actions[service]![actionName]!.$1;
        if (required.isNotEmpty &&
            required
                .split(',')
                .any((a) => !args.containsKey(a.split(':').first))) {
          throw const ControlError(402, 'Invalid Args');
        }
        controls++;
        response.write(
          soapResponse(
            service,
            actionName,
            await control(
              service,
              actionName,
              args,
              senderAddress: request.connectionInfo!.remoteAddress.address,
            ),
          ),
        );
      } else {
        response.statusCode = 404;
      }
    } on ControlError catch (error) {
      response.statusCode = 500;
      response.write(soapFault(error.code, error.message));
    } catch (error) {
      response.statusCode = 500;
      response.write(soapFault(501, 'Action Failed'));
    } finally {
      await response.close();
    }
  }

  Future<Map<String, Object>> control(
    String service,
    String action,
    Map<String, String> args, {
    String? senderAddress,
  }) async {
    if (args.containsKey('InstanceID') && args['InstanceID'] != '0') {
      throw const ControlError(718, 'Invalid InstanceID');
    }
    if (args.containsKey('Channel') && args['Channel'] != 'Master') {
      throw const ControlError(402, 'Invalid Args');
    }
    if (service == 'AVTransport' &&
        action == 'Stop' &&
        senderAddress != null &&
        requests?.cancel(senderAddress) == true) {
      return {};
    }
    if (senderAddress != null &&
        requests != null &&
        !action.startsWith('Get') &&
        action != 'ListPresets') {
      if (!await requests!.authorize(senderAddress)) {
        throw const ControlError(606, 'Action not authorized');
      }
    }
    final status = player.status;
    final duration = timeText(status['duration'] as num);
    final position = timeText(status['position'] as num);
    switch ('$service/$action') {
      case 'AVTransport/SetAVTransportURI':
        final uri = Uri.tryParse(args['CurrentURI']!);
        if (uri == null ||
            !['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          throw const ControlError(716, 'Resource not found');
        }
        await player.command('load', {
          'url': uri.toString(),
          'metadata': args['CurrentURIMetaData']!,
        });
      case 'AVTransport/Play':
        if (args['Speed'] != '1') {
          throw const ControlError(717, 'Play speed not supported');
        }
        if (player.uri.isEmpty) {
          throw const ControlError(701, 'Transition not available');
        }
        await player.command('play');
      case 'AVTransport/Pause':
        await player.command('pause');
      case 'AVTransport/Stop':
        await player.command('stop');
      case 'AVTransport/Seek':
        if (args['Unit'] != 'REL_TIME') {
          throw const ControlError(710, 'Seek mode not supported');
        }
        final seconds = timeSeconds(args['Target']!);
        if (seconds == null || !seconds.isFinite) {
          throw const ControlError(711, 'Illegal seek target');
        }
        await player.command('seek', {'seconds': seconds});
      case 'AVTransport/GetTransportInfo':
        return {
          'CurrentTransportState': status['state'],
          'CurrentTransportStatus': status['error'] == ''
              ? 'OK'
              : 'ERROR_OCCURRED',
          'CurrentSpeed': '1',
        };
      case 'AVTransport/GetPositionInfo':
        return {
          'Track': player.uri.isEmpty ? 0 : 1,
          'TrackDuration': duration,
          'TrackMetaData': player.metadata,
          'TrackURI': player.uri,
          'RelTime': position,
          'AbsTime': position,
          'RelCount': -1,
          'AbsCount': -1,
        };
      case 'AVTransport/GetMediaInfo':
        return {
          'NrTracks': player.uri.isEmpty ? 0 : 1,
          'MediaDuration': duration,
          'CurrentURI': player.uri,
          'CurrentURIMetaData': player.metadata,
          'NextURI': '',
          'NextURIMetaData': '',
          'PlayMedium': 'NETWORK',
          'RecordMedium': 'NOT_IMPLEMENTED',
          'WriteStatus': 'NOT_IMPLEMENTED',
        };
      case 'AVTransport/GetDeviceCapabilities':
        return {
          'PlayMedia': 'NETWORK',
          'RecMedia': 'NOT_IMPLEMENTED',
          'RecQualityModes': 'NOT_IMPLEMENTED',
        };
      case 'AVTransport/GetTransportSettings':
        return {'PlayMode': 'NORMAL', 'RecQualityMode': 'NOT_IMPLEMENTED'};
      case 'AVTransport/GetCurrentTransportActions':
        return {'Actions': player.uri.isEmpty ? '' : 'Play,Pause,Stop,Seek'};
      case 'RenderingControl/GetVolume':
        return {'CurrentVolume': ((status['volume'] as num) * 100).round()};
      case 'RenderingControl/SetVolume':
        final value = int.tryParse(args['DesiredVolume']!);
        if (value == null || value < 0 || value > 100) {
          throw const ControlError(402, 'Invalid Args');
        }
        await player.command('volume', {'value': value / 100});
      case 'RenderingControl/GetMute':
        return {'CurrentMute': status['muted'] == true ? 1 : 0};
      case 'RenderingControl/SetMute':
        final value = args['DesiredMute'];
        if (!['0', '1', 'true', 'false'].contains(value)) {
          throw const ControlError(402, 'Invalid Args');
        }
        await player.command('mute', {
          'value': value == '1' || value == 'true',
        });
      case 'RenderingControl/ListPresets':
        return {'CurrentPresetNameList': 'FactoryDefaults'};
      case 'RenderingControl/SelectPreset':
        if (args['PresetName'] != 'FactoryDefaults') {
          throw const ControlError(402, 'Invalid Args');
        }
        await player.command('volume', {'value': 1.0});
        await player.command('mute', {'value': false});
      case 'ConnectionManager/GetProtocolInfo':
        return {'Source': '', 'Sink': protocolInfo};
      case 'ConnectionManager/GetCurrentConnectionIDs':
        return {'ConnectionIDs': '0'};
      case 'ConnectionManager/GetCurrentConnectionInfo':
        if (args['ConnectionID'] != '0') {
          throw const ControlError(706, 'Invalid connection reference');
        }
        return {
          'RcsID': 0,
          'AVTransportID': 0,
          'ProtocolInfo': '',
          'PeerConnectionManager': '',
          'PeerConnectionID': -1,
          'Direction': 'Input',
          'Status': 'OK',
        };
      default:
        throw const ControlError(401, 'Invalid Action');
    }
    return {};
  }

  void subscribe(HttpRequest request, String service) {
    // Do not drop an otherwise healthy subscription solely because a sender
    // missed its optional renewal window.  Stale callbacks are removed when a
    // NOTIFY fails.
    final sid = request.headers.value('sid');
    final peer = request.connectionInfo!.remoteAddress.address;
    Subscription? sub;
    if (sid != null) {
      sub = subscriptions[sid];
      if (sub == null || sub.callback.host != peer || sub.service != service) {
        request.response.statusCode = 412;
        return;
      }
      if (request.method == 'UNSUBSCRIBE') {
        subscriptions.remove(sid);
        return;
      }
    } else if (request.method == 'SUBSCRIBE') {
      final callback = request.headers.value('callback') ?? '';
      final uri = callback.startsWith('<') && callback.endsWith('>')
          ? Uri.tryParse(callback.substring(1, callback.length - 1))
          : null;
      if (uri == null ||
          uri.scheme != 'http' ||
          uri.host != peer ||
          uri.userInfo.isNotEmpty ||
          subscriptions.length >= 16 ||
          request.headers.value('nt') != 'upnp:event') {
        request.response.statusCode = 412;
        return;
      }
      sub = Subscription(
        'uuid:${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}',
        service,
        uri,
      );
      subscriptions[sub.id] = sub;
    }
    if (request.method != 'SUBSCRIBE' || sub == null) {
      request.response.statusCode = 412;
      return;
    }
    sub.expires = DateTime.now().add(const Duration(days: 1));
    request.response.headers.set('SID', sub.id);
    request.response.headers.set('TIMEOUT', 'Second-300');
    // Initial NOTIFY must follow the SUBSCRIBE response, even before a player event.
    unawaited(request.response.done.then((_) => notifySubscribers()));
  }

  void notifySubscribers() {
    // Liveness is determined by the callback response in notify().
    for (final sub in subscriptions.values) {
      final state = player.status;
      final String property;
      if (sub.service == 'ConnectionManager') {
        property =
            {
                  'SourceProtocolInfo': '',
                  'SinkProtocolInfo': protocolInfo,
                  'CurrentConnectionIDs': '0',
                }.entries
                .map(
                  (e) => '<e:property>${tags({e.key: e.value})}</e:property>',
                )
                .join();
      } else {
        final values = sub.service == 'AVTransport'
            ? '<TransportState val="${state['state']}"/><TransportStatus val="${state['error'] == '' ? 'OK' : 'ERROR_OCCURRED'}"/>'
            : '<Volume channel="Master" val="${((state['volume'] as num) * 100).round()}"/><Mute channel="Master" val="${state['muted'] == true ? 1 : 0}"/>';
        final ns = sub.service == 'AVTransport' ? 'AVT' : 'RCS';
        property =
            '<e:property><LastChange>${escape('<Event xmlns="urn:schemas-upnp-org:metadata-1-0/$ns/"><InstanceID val="0">$values</InstanceID></Event>')}</LastChange></e:property>';
      }
      final body =
          '<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">$property</e:propertyset>';
      if (!sub.sending && sub.lastBody != body) unawaited(notify(sub, body));
    }
  }

  Future<void> notify(Subscription sub, String body) async {
    sub.sending = true;
    try {
      final request = await httpClient
          .openUrl('NOTIFY', sub.callback)
          .timeout(const Duration(seconds: 2));
      request.headers.contentType = ContentType(
        'text',
        'xml',
        charset: 'utf-8',
      );
      request.headers.set('NT', 'upnp:event');
      request.headers.set('NTS', 'upnp:propchange');
      request.headers.set('SID', sub.id);
      request.headers.set('SEQ', '${sub.sequence}');
      request.write(body);
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      await response.drain<void>().timeout(const Duration(seconds: 2));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const HttpException('Event rejected');
      }
      sub.lastBody = body;
      sub.sequence = sub.sequence == 0xffffffff ? 1 : sub.sequence + 1;
    } catch (_) {
      subscriptions.remove(sub.id);
    } finally {
      sub.sending = false;
      // A pause or volume change may arrive while the previous event is in
      // flight, with no later playback tick to flush the latest state.
      if (identical(subscriptions[sub.id], sub)) notifySubscribers();
    }
  }

  Future<void> close() async {
    announceTimer?.cancel();
    for (final timer in searchTimers) {
      timer.cancel();
    }
    player.removeListener(notifySubscribers);
    subscriptions.clear();
    if (ssdp != null && http != null) announce('ssdp:byebye');
    ssdp?.close();
    ssdp = null;
    httpClient.close(force: true);
    await http?.close(force: true);
    http = null;
  }
}
