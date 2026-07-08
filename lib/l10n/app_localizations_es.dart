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
  String connectRequestNotificationBody(String name, String host) {
    return '$name ($host) quiere conectarse';
  }

  @override
  String get connectRequestExpired => 'La solicitud de conexión ha expirado';

  @override
  String transferNotificationTitle(int count) {
    return 'Transfiriendo $count archivos';
  }

  @override
  String transferNotificationBodySending(
      int percent, String speed, String remaining) {
    return 'Enviando $percent% · $speed · quedan $remaining';
  }

  @override
  String transferNotificationBodyReceiving(
      int percent, String speed, String remaining) {
    return 'Recibiendo $percent% · $speed · quedan $remaining';
  }

  @override
  String transferNotificationBodyMixed(
      int percent, String speed, String remaining) {
    return 'Sincronizando $percent% · $speed · quedan $remaining';
  }

  @override
  String transferNotificationCompleted(int count) {
    return 'Transferencia completada · $count archivos';
  }

  @override
  String get transferNotificationInterrupted =>
      'Transferencia interrumpida, vuelve a la app para reanudar';

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
  String get retry => 'Reintentar';

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
  String get filePickerOpenFailed => 'No se pudo abrir el selector de archivos';

  @override
  String get clipboardImageSendFailed =>
      'No se pudo enviar la imagen del portapapeles';

  @override
  String get clipboardFilesSendFailed =>
      'No se pudieron enviar los archivos del portapapeles';

  @override
  String clipboardFilesCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count archivos',
      one: '1 archivo',
    );
    return '$_temp0';
  }

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

  @override
  String get launchAtStartup => 'Iniciar al arrancar';

  @override
  String get launchAtStartupDesc =>
      'Inicia Whisper automaticamente al iniciar sesion para reconectar dispositivos de confianza';

  @override
  String launchAtStartupFailed(String error) {
    return 'No se pudo actualizar el inicio automatico: $error';
  }

  @override
  String get androidBackgroundKeepAlive =>
      'Mantener la conexion en segundo plano';

  @override
  String get androidBackgroundKeepAliveDesc =>
      'Usa un servicio en primer plano durante sesiones activas para reducir desconexiones al elegir archivos o cambiar de app';

  @override
  String get androidBackgroundKeepAliveActiveTitle =>
      'Whisper mantiene la conexion activa';

  @override
  String get androidBackgroundKeepAliveActiveDesc =>
      'Activo mientras haya una sesion conectada';

  @override
  String get androidBatteryOptimization => 'Optimizacion de bateria';

  @override
  String get androidBatteryOptimizationDesc =>
      'Se recomienda permitir actividad en segundo plano y excluir Whisper de la optimizacion de bateria en Android';

  @override
  String get fileTransferQueued => 'En cola';

  @override
  String fileTransferPreparingResume(String progress) {
    return 'Preparando reanudacion $progress%';
  }

  @override
  String get fileTransferNegotiating => 'Negociando';

  @override
  String fileTransferWaitingReconnect(String progress) {
    return 'Esperando reconexion $progress%';
  }

  @override
  String get fileTransferPaused => 'Pausada';

  @override
  String get fileTransferVerifying => 'Verificando';

  @override
  String get fileTransferFailedRetryable => 'Error, se puede reintentar';

  @override
  String get fileTransferCanceled => 'Cancelada';

  @override
  String get audioShareCaptureConnecting =>
      'Captura: conectando al altavoz remoto';

  @override
  String get audioSharePlaybackPreparing =>
      'Reproduccion: preparando audio compartido';

  @override
  String get audioShareCaptureActiveStop =>
      'Captura: compartiendo el audio de este dispositivo, clic para detener';

  @override
  String get audioSharePlaybackActiveStop =>
      'Reproduccion: reproduciendo audio compartido, clic para detener';

  @override
  String get audioShareStart =>
      'Compartir el audio de este dispositivo con el otro';

  @override
  String get audioSharePlaybackStopped =>
      'Se detuvo la reproduccion del audio compartido';

  @override
  String get audioShareCaptureStopped => 'Se detuvo el audio compartido';

  @override
  String get audioSharePlaybackGainTitle => 'Ganancia del altavoz compartido';

  @override
  String audioSharePlaybackGainSetting(String gain) {
    return 'Ganancia del altavoz compartido: $gain';
  }

  @override
  String get audioSharePlaybackGainDesc =>
      'Solo afecta al audio compartido reproducido en este dispositivo. Valores altos pueden recortar';

  @override
  String get remoteInputScrollMultiplierTitle =>
      'Velocidad de desplazamiento compartido';

  @override
  String remoteInputScrollMultiplierSetting(String multiplier) {
    return 'Velocidad de desplazamiento compartido: $multiplier';
  }

  @override
  String get remoteInputScrollMultiplierDesc =>
      'Solo afecta eventos de rueda remotos recibidos cuando este dispositivo esta siendo controlado';

  @override
  String get audioShareUnsupportedCapture =>
      'Este dispositivo no admite captura de audio del sistema';

  @override
  String get audioShareRequestingPlayback =>
      'Solicitando al otro dispositivo que reproduzca este audio';

  @override
  String get audioGroupShareStart => 'Sincronizar con varios altavoces';

  @override
  String get audioGroupAdjust => 'Ajustar audio compartido';

  @override
  String get audioGroupSelectSinks =>
      'Seleccionar dispositivos de reproduccion';

  @override
  String get audioGroupStart => 'Iniciar reproduccion sincronizada';

  @override
  String get audioGroupApply => 'Aplicar configuracion';

  @override
  String get audioGroupStop => 'Detener audio compartido';

  @override
  String get audioGroupRoleStereo => 'Estereo';

  @override
  String get audioGroupRoleLeft => 'Canal izquierdo';

  @override
  String get audioGroupRoleRight => 'Canal derecho';

  @override
  String get audioGroupRoleMono => 'Mono';

  @override
  String get audioGroupRequestingPlayback =>
      'Solicitando reproduccion sincronizada en los dispositivos seleccionados';

  @override
  String get audioGroupSelectAtLeastOne =>
      'Selecciona al menos un dispositivo de reproduccion';

  @override
  String get audioGroupSyncCalibrating => 'Estimando sincronizacion';

  @override
  String get audioGroupSyncGood => 'Sincronizacion buena';

  @override
  String get audioGroupSyncFair => 'Sincronizacion aceptable';

  @override
  String get audioGroupSyncUnstable => 'Sincronizacion inestable';

  @override
  String get audioGroupDeviceIdle => 'Inactivo';

  @override
  String get audioGroupLatencyShortLabel => 'red ';

  @override
  String get audioGroupJitterShortLabel => 'fluct. ';

  @override
  String get audioGroupBufferShortLabel => 'bufer ';

  @override
  String get audioGroupRecentLatePacketShortLabel => 'tardios ';

  @override
  String get audioGroupClockOffsetLabel => 'desfase de reloj';

  @override
  String audioGroupSyncEvidence(
      Object quality,
      Object clockOffsetLabel,
      Object offset,
      Object rtt,
      Object jitter,
      Object buffer,
      Object latePackets) {
    return '$quality · $clockOffsetLabel ${offset}ms · RTT ${rtt}ms · fluctuacion ${jitter}ms · bufer ${buffer}ms · tardios $latePackets';
  }

  @override
  String audioGroupSyncEvidenceCompact(
      Object quality,
      Object latencyLabel,
      Object rtt,
      Object jitterLabel,
      Object jitter,
      Object bufferLabel,
      Object buffer,
      Object latePacketLabel,
      Object latePackets) {
    return '$quality · $latencyLabel$rtt · $jitterLabel$jitter · $bufferLabel$buffer · $latePacketLabel$latePackets';
  }

  @override
  String audioShareFailed(String error) {
    return 'Error al compartir audio: $error';
  }

  @override
  String get remoteInputSourceConnecting =>
      'Compartir teclado y mouse: conectando al otro dispositivo';

  @override
  String get remoteInputSinkConnecting =>
      'Compartir teclado y mouse: preparando recepcion de control';

  @override
  String get remoteInputEdgeActiveStop =>
      'Compartir teclado y mouse: cruce de borde activado, clic para detener';

  @override
  String get remoteInputSourceActiveStop =>
      'Compartir teclado y mouse: controlando al otro, clic para detener';

  @override
  String get remoteInputSinkActiveStop =>
      'Compartir teclado y mouse: recibiendo control, clic para detener';

  @override
  String get remoteInputStart => 'Activar compartir teclado y mouse';

  @override
  String get remoteInputStopped => 'Se detuvo compartir teclado y mouse';

  @override
  String get remoteInputStopCurrentFirst =>
      'Deten primero la sesion actual de teclado y mouse compartidos';

  @override
  String get remoteInputLocalUnsupported =>
      'Este dispositivo no admite compartir teclado y mouse';

  @override
  String get remoteInputPeerUnsupported =>
      'El dispositivo conectado no admite compartir teclado y mouse';

  @override
  String get remoteInputRequiresMutualTrust =>
      'Compartir teclado y mouse requiere confianza mutua';

  @override
  String get remoteInputPeerMustTrustThisDevice =>
      'El otro dispositivo aun no confia en este. Confia en este dispositivo desde el otro antes de compartir teclado y mouse';

  @override
  String get remoteInputLayoutRequired =>
      'Primero coloca la pantalla del otro dispositivo contra el borde en ajustes';

  @override
  String get remoteInputEnabledMoveToEdge =>
      'Compartir teclado y mouse esta activado. Mueve al borde de la pantalla para controlar el otro dispositivo';

  @override
  String remoteInputFailed(String error) {
    return 'Error al compartir teclado y mouse: $error';
  }

  @override
  String remoteInputAutoModeSetting(String mode) {
    return 'Compartir teclado y mouse: $mode';
  }

  @override
  String remoteInputLayoutSetting(String edge) {
    return 'Distribucion de pantalla: $edge';
  }

  @override
  String get remoteInputAutoModeTitle => 'Compartir teclado y mouse';

  @override
  String get remoteInputAutoModeOff => 'Desactivado';

  @override
  String get remoteInputAutoModeSource => 'Este dispositivo controla al otro';

  @override
  String get remoteInputAutoModeSink => 'El otro controla este dispositivo';

  @override
  String get remoteInputLayoutTitle => 'Distribucion de pantalla';

  @override
  String remoteInputCurrentEdge(String edge) {
    return 'Actual: $edge';
  }

  @override
  String get remoteInputLayoutSave => 'Guardar';

  @override
  String get remoteInputSnapLeft => 'Ajustar a la izquierda';

  @override
  String get remoteInputSnapRight => 'Ajustar a la derecha';

  @override
  String get remoteInputSnapTop => 'Ajustar arriba';

  @override
  String get remoteInputSnapBottom => 'Ajustar abajo';

  @override
  String get remoteInputLocalScreen => 'Este dispositivo';

  @override
  String get remoteInputPeerScreen => 'Otro dispositivo';

  @override
  String get remoteInputEdgeLeft => 'Izquierda';

  @override
  String get remoteInputEdgeRight => 'Derecha';

  @override
  String get remoteInputEdgeTop => 'Arriba';

  @override
  String get remoteInputEdgeBottom => 'Abajo';

  @override
  String get remoteInputEdgeNotAdjacent => 'Sin borde compartido';

  @override
  String get remoteInputWorkspaceTitle => 'Espacio de teclado y mouse';

  @override
  String get remoteInputWorkspaceTooltip => 'Espacio de teclado y mouse';

  @override
  String get remoteInputWorkspaceStart => 'Iniciar';

  @override
  String get remoteInputWorkspaceStop => 'Detener';

  @override
  String get remoteInputWorkspaceNoTargets =>
      'No hay equipos de escritorio disponibles';

  @override
  String get remoteInputWorkspaceSelectTargets => 'Equipos controlados';

  @override
  String get remoteInputWorkspaceCanvasTitle => 'Distribucion de pantalla';

  @override
  String get remoteInputWorkspaceDetailsTitle => 'Detalles del dispositivo';

  @override
  String get remoteInputWorkspaceFocusTarget => 'Ver dispositivo';

  @override
  String get remoteInputWorkspaceAddTarget => 'Agregar al espacio';

  @override
  String get remoteInputWorkspaceRemoveTarget => 'Quitar del espacio';

  @override
  String get remoteInputWorkspaceState => 'Estado';

  @override
  String get remoteInputWorkspaceConflict => 'Bordes superpuestos';

  @override
  String get remoteInputWorkspaceTargetIdle => 'No activado';

  @override
  String get remoteInputWorkspaceStatusIdle =>
      'El espacio de teclado y mouse esta desactivado';

  @override
  String get remoteInputWorkspaceStatusOffering =>
      'Esperando confirmacion de los equipos';

  @override
  String get remoteInputWorkspaceStatusArmed =>
      'Mueve al borde de la pantalla para controlar un equipo';

  @override
  String remoteInputWorkspaceStatusActive(String peer) {
    return 'Controlando $peer';
  }

  @override
  String remoteInputWorkspaceStatusFailed(String error) {
    return 'Error del espacio de teclado y mouse: $error';
  }

  @override
  String get audioPlaybackNotificationSubtitle =>
      'Reproduciendo audio del sistema';

  @override
  String get mediaActionPause => 'Pausar';

  @override
  String get mediaActionPlay => 'Reproducir';

  @override
  String get mediaActionDisconnect => 'Desconectar';

  @override
  String get notificationChannelKeepAlive => 'Mantener activo en segundo plano';

  @override
  String get notificationChannelKeepAliveDesc =>
      'Mantiene Whisper conectado mientras se ejecuta en segundo plano';

  @override
  String get notificationChannelMedia => 'Reproducción multimedia';

  @override
  String get notificationChannelTransfer => 'Transferencia de archivos';

  @override
  String get notificationChannelTransferDesc =>
      'Progreso de transferencia de archivos';

  @override
  String get notificationChannelGeneral => 'Mensajes';

  @override
  String get notificationChannelGeneralDesc => 'Mensajes entrantes y avisos';
}
