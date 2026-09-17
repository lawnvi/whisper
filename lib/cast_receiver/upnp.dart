import 'package:xml/xml.dart';

const rendererType = 'urn:schemas-upnp-org:device:MediaRenderer:1';
const protocolInfo =
    'http-get:*:video/mp4:*,http-get:*:video/quicktime:*,'
    'http-get:*:application/vnd.apple.mpegurl:*,http-get:*:application/x-mpegURL:*,'
    'http-get:*:audio/mpeg:*,http-get:*:audio/mp4:*';

// A deliberately small control surface; no next-track, DRM or screen mirroring.
const actions = <String, Map<String, (String, String)>>{
  'AVTransport': {
    'SetAVTransportURI': (
      'InstanceID:ui4,CurrentURI:uri,CurrentURIMetaData:string',
      '',
    ),
    'Play': ('InstanceID:ui4,Speed:string', ''),
    'Pause': ('InstanceID:ui4', ''),
    'Stop': ('InstanceID:ui4', ''),
    'Seek': ('InstanceID:ui4,Unit:string,Target:string', ''),
    'GetTransportInfo': (
      'InstanceID:ui4',
      'CurrentTransportState:string,CurrentTransportStatus:string,CurrentSpeed:string',
    ),
    'GetPositionInfo': (
      'InstanceID:ui4',
      'Track:ui4,TrackDuration:string,TrackMetaData:string,TrackURI:uri,RelTime:string,AbsTime:string,RelCount:i4,AbsCount:i4',
    ),
    'GetMediaInfo': (
      'InstanceID:ui4',
      'NrTracks:ui4,MediaDuration:string,CurrentURI:uri,CurrentURIMetaData:string,NextURI:uri,NextURIMetaData:string,PlayMedium:string,RecordMedium:string,WriteStatus:string',
    ),
    'GetDeviceCapabilities': (
      'InstanceID:ui4',
      'PlayMedia:string,RecMedia:string,RecQualityModes:string',
    ),
    'GetTransportSettings': (
      'InstanceID:ui4',
      'PlayMode:string,RecQualityMode:string',
    ),
    'GetCurrentTransportActions': ('InstanceID:ui4', 'Actions:string'),
  },
  'RenderingControl': {
    'GetVolume': ('InstanceID:ui4,Channel:string', 'CurrentVolume:ui2'),
    'SetVolume': ('InstanceID:ui4,Channel:string,DesiredVolume:ui2', ''),
    'GetMute': ('InstanceID:ui4,Channel:string', 'CurrentMute:boolean'),
    'SetMute': ('InstanceID:ui4,Channel:string,DesiredMute:boolean', ''),
    'ListPresets': ('InstanceID:ui4', 'CurrentPresetNameList:string'),
    'SelectPreset': ('InstanceID:ui4,PresetName:string', ''),
  },
  'ConnectionManager': {
    'GetProtocolInfo': ('', 'Source:string,Sink:string'),
    'GetCurrentConnectionIDs': ('', 'ConnectionIDs:string'),
    'GetCurrentConnectionInfo': (
      'ConnectionID:i4',
      'RcsID:i4,AVTransportID:i4,ProtocolInfo:string,PeerConnectionManager:string,PeerConnectionID:i4,Direction:string,Status:string',
    ),
  },
};

String escape(Object value) => XmlText('$value').toXmlString();
String serviceType(String service) => 'urn:schemas-upnp-org:service:$service:1';
String tags(Map<String, Object> values) =>
    values.entries.map((e) => '<${e.key}>${escape(e.value)}</${e.key}>').join();

String deviceDescription(String name, String uuid) =>
    '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
<specVersion><major>1</major><minor>0</minor></specVersion><device>
${tags({'deviceType': rendererType, 'friendlyName': name, 'manufacturer': 'Whisper', 'modelName': 'Media Receiver', 'UDN': uuid})}
<serviceList>${actions.keys.map((s) => '<service>${tags({'serviceType': serviceType(s), 'serviceId': 'urn:upnp-org:serviceId:$s', 'SCPDURL': '/$s.xml', 'controlURL': '/control/$s', 'eventSubURL': '/event/$s'})}</service>').join()}</serviceList></device></root>''';

String serviceDescription(String service) {
  final variables = <String, String>{};
  String arguments(String text, String direction) => text.isEmpty
      ? ''
      : text.split(',').map((arg) {
          final parts = arg.split(':');
          variables[parts[0]] = parts[1];
          return '<argument>${tags({'name': parts[0], 'direction': direction, 'relatedStateVariable': 'A_ARG_TYPE_${parts[0]}'})}</argument>';
        }).join();
  final actionList = actions[service]!.entries
      .map(
        (a) =>
            '<action><name>${a.key}</name><argumentList>${arguments(a.value.$1, 'in')}${arguments(a.value.$2, 'out')}</argumentList></action>',
      )
      .join();
  return '''<?xml version="1.0"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
<specVersion><major>1</major><minor>0</minor></specVersion><actionList>$actionList</actionList>
<serviceStateTable>${variables.entries.map((v) => '<stateVariable sendEvents="no">${tags({'name': 'A_ARG_TYPE_${v.key}', 'dataType': v.value})}</stateVariable>').join()}
${service == 'ConnectionManager' ? ['SourceProtocolInfo', 'SinkProtocolInfo', 'CurrentConnectionIDs'].map((v) => '<stateVariable sendEvents="yes"><name>$v</name><dataType>string</dataType></stateVariable>').join() : '<stateVariable sendEvents="yes"><name>LastChange</name><dataType>string</dataType></stateVariable>'}
</serviceStateTable></scpd>''';
}

String envelope(String body) =>
    '<?xml version="1.0"?>'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
    '<s:Body>$body</s:Body></s:Envelope>';
String soapResponse(
  String service,
  String action,
  Map<String, Object> values,
) => envelope(
  '<u:${action}Response xmlns:u="${serviceType(service)}">${tags(values)}</u:${action}Response>',
);
String soapFault(int code, String description) => envelope(
  '<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>'
  '<detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
  '${tags({'errorCode': code, 'errorDescription': description})}'
  '</UPnPError></detail></s:Fault>',
);

String timeText(num seconds) {
  final value = seconds.isFinite ? seconds.floor().clamp(0, 864000) : 0;
  return '${(value ~/ 3600).toString().padLeft(2, '0')}:'
      '${(value ~/ 60 % 60).toString().padLeft(2, '0')}:'
      '${(value % 60).toString().padLeft(2, '0')}';
}

double? timeSeconds(String value) {
  final match = RegExp(
    r'^(\d+):([0-5]\d):([0-5]\d(?:\.\d+)?)$',
  ).firstMatch(value);
  if (match == null) return null;
  return double.parse(match[1]!) * 3600 +
      double.parse(match[2]!) * 60 +
      double.parse(match[3]!);
}
