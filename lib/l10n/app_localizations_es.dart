// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get connectDeviceTitle => 'Conectar dispositivo';

  @override
  String get connectDeviceDesc => 'Ingresar IP y puerto';

  @override
  String get connectTo => 'Conectar a';

  @override
  String get connectRequest => 'Solicitud de conexión';

  @override
  String connectRequestDesc(String device) {
    return '¿Nuevo dispositivo: $device?';
  }

  @override
  String get connect => 'Conectar';

  @override
  String get confirm => 'Confirmar';

  @override
  String get allow => 'Permitir';

  @override
  String get refuse => 'Rechazar';

  @override
  String get cancel => 'Cancelar';

  @override
  String get setting => 'Ajustes';

  @override
  String get sendTips => 'Escribe algo...';

  @override
  String get trust => 'Confiar en dispositivo';

  @override
  String get writeClipboard => 'Escribir al portapapeles';

  @override
  String get deleteDevice => 'Eliminar dispositivo';

  @override
  String serverPort(Object port) {
    return 'Puerto del servidor $port';
  }

  @override
  String get serverPortTitle => 'Puerto del servidor';

  @override
  String get trustNewDevice => 'Acceso automático a nuevos dispositivos';

  @override
  String get accessClipboard => 'Acceder al portapapeles';

  @override
  String get doubleClickRmMessage => 'Eliminar mensaje al hacer doble clic';

  @override
  String get close2tray => 'Ocultar en la bandeja al cerrar';

  @override
  String get nickname => 'Apodo';

  @override
  String get nicknameDesc => 'Ingresa tu apodo';

  @override
  String get port => 'Puerto';

  @override
  String get portDesc => 'Rango del puerto: [1000, 65535]';

  @override
  String get timeoutTitle => 'Tiempo de espera de conexión';

  @override
  String get disconnect => 'Desconectar';

  @override
  String get keepConnect => 'Mantener';

  @override
  String get menuShow => 'Mostrar';

  @override
  String get menuHide => 'Ocultar';

  @override
  String get menuClipboard => 'Enviar portapapeles';

  @override
  String get menuSendFile => 'Enviar archivos';

  @override
  String get exit => 'Salir';

  @override
  String get delete => 'Eliminar';

  @override
  String get deleteConfirm => 'Confirmar eliminación';

  @override
  String get warning => 'Advertencia';

  @override
  String get deleteWarningText =>
      'La conexión está activa, no se puede eliminar rápidamente';

  @override
  String get close => 'Cerrar';

  @override
  String deleteDeviceTitle(String device) {
    return 'Eliminar $device';
  }

  @override
  String get deleteDeviceDesc =>
      'Borra todos los mensajes de este dispositivo. No se puede recuperar.';

  @override
  String get brokeConnectTitle => 'Desconectar';

  @override
  String brokeConnectDesc(String device) {
    return 'Desconectar $device';
  }

  @override
  String get connectFailed => 'Error de conexión';

  @override
  String get deviceBusy => 'Dispositivo ocupado';

  @override
  String get startServerFailed => 'No se pudo iniciar el servidor';

  @override
  String get deleteMessageTitle => 'Eliminar mensaje';

  @override
  String get deleteMessageDesc => '¿Seguro que quieres eliminarlo?';

  @override
  String language(Object language) {
    return 'Idioma $language';
  }

  @override
  String get pushNotification => 'Enviar notificaciones de Android';

  @override
  String get ignoreNotification => 'Ignorar notificaciones de Android';

  @override
  String get ftpService => 'Servicio FTP';

  @override
  String get back => 'Volver';

  @override
  String get selectAll => 'Todo';

  @override
  String get clearAll => 'Limpiar';

  @override
  String get selectNotifyApp => 'Escuchar notificaciones de apps';

  @override
  String get copyVerifyCode => 'Copiar código de verificación al portapapeles';

  @override
  String get open => 'Abrir';

  @override
  String get openInFinder => 'Abrir en Finder';

  @override
  String get openInDir => 'Abrir carpeta';

  @override
  String get keepFile => 'Conservar archivo';

  @override
  String get deleteFile => 'Eliminar archivo';

  @override
  String get copyMessage => 'Copiar contenido del mensaje';

  @override
  String get themeMode => 'Modo de tema';

  @override
  String get followSystem => 'Seguir al sistema';

  @override
  String get lightMode => 'Claro';

  @override
  String get darkMode => 'Oscuro';

  @override
  String get selectThemeMode => 'Seleccionar modo de tema';

  @override
  String get selectLanguage => 'Seleccionar idioma';

  @override
  String get searchChats => 'Buscar';

  @override
  String get selectConversationPlaceholder =>
      'Selecciona un dispositivo para empezar a chatear';

  @override
  String get connectedNow => 'Conectado ahora';

  @override
  String get nearbyAvailable => 'Disponible cerca';

  @override
  String get noMessagesYet => 'Aun no hay mensajes';

  @override
  String get sharedFile => 'Compartio un archivo';

  @override
  String get connectToSend => 'Conectate para enviar mensajes';

  @override
  String get localeNameZhHans => 'Chino simplificado';

  @override
  String get localeNameEnglish => 'Ingles';

  @override
  String get localeNameSpanish => 'Espanol';

  @override
  String get autoConnectTrustedDevices =>
      'Conectar automaticamente dispositivos con confianza mutua';

  @override
  String get mutualTrustEnabled => 'La confianza mutua esta activada';

  @override
  String get mutualTrustNotEstablished =>
      'La confianza mutua aun no esta establecida';
}
