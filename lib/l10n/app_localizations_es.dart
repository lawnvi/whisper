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
  String get trust => 'Confiar en este dispositivo';

  @override
  String get writeClipboard => 'Permitir escribir en el portapapeles';

  @override
  String get deleteDevice => 'Eliminar dispositivo';

  @override
  String serverPort(Object port) {
    return 'Puerto del servidor $port';
  }

  @override
  String get serverPortTitle => 'Puerto del servidor';

  @override
  String get accessClipboard => 'Permitir acceso al portapapeles';

  @override
  String get doubleClickRmMessage => 'Eliminar mensaje al hacer doble clic';

  @override
  String get close2tray => 'Ocultar en la bandeja al cerrar';

  @override
  String get nickname => 'Apodo';

  @override
  String get nicknameDesc => 'Introduce un apodo';

  @override
  String get port => 'Puerto';

  @override
  String get portDesc => 'Introduce un puerto entre 1001 y 65535';

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
  String get messageSendFailed =>
      'No se pudo enviar el mensaje. Inténtalo de nuevo';

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
  String get connectAlreadyInProgress => 'La conexión ya está en curso';

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
  String get back => 'Volver';

  @override
  String get selectAll => 'Todo';

  @override
  String get clearAll => 'Limpiar';

  @override
  String get selectNotifyApp => 'Aplicaciones de notificaciones';

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
  String get localeNameEnglish => 'Inglés';

  @override
  String get localeNameSpanish => 'Español';

  @override
  String get autoConnectTrustedDevices =>
      'Conectar automáticamente los dispositivos con confianza mutua';

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

  @override
  String get emptyAppsTitle => 'No hay aplicaciones disponibles';

  @override
  String get emptyAppsSearchTitle => 'No se encontraron aplicaciones';

  @override
  String get fileDropRejected => 'No se pueden enviar estos archivos';

  @override
  String get validationRequired => 'Este campo es obligatorio';

  @override
  String get validationNicknameRequired => 'Introduce un apodo';

  @override
  String get validationNicknameTooLong =>
      'El apodo no puede superar los 64 caracteres';

  @override
  String get validationHostRequired =>
      'Introduce un nombre de host o dirección IP';

  @override
  String get validationHostInvalid =>
      'Introduce una dirección IPv4, IPv6, .local o un host válido';

  @override
  String get validationPortInvalid => 'Introduce un puerto entre 1001 y 65535';

  @override
  String get settingsSectionDeviceAppearance => 'Dispositivo y apariencia';

  @override
  String get settingsSectionDeviceAppearanceDesc =>
      'Nombre, tema y visibilidad de este dispositivo en la red cercana';

  @override
  String get settingsSectionConnectionTransfer => 'Conexión y transferencia';

  @override
  String get settingsSectionConnectionTransferDesc =>
      'Puerto del servidor, archivos guardados y conexiones de confianza';

  @override
  String get settingsSectionSystemBehavior => 'Comportamiento del sistema';

  @override
  String get settingsSectionSystemBehaviorDesc =>
      'Inicio, segundo plano y comportamiento de las ventanas';

  @override
  String get settingsSectionPermissionsSharing => 'Permisos y uso compartido';

  @override
  String get settingsSectionPermissionsSharingDesc =>
      'Acceso al portapapeles, confianza, audio, teclado y ratón';

  @override
  String get settingsSectionMobileIntegration => 'Integración móvil';

  @override
  String get settingsSectionMobileIntegrationDesc =>
      'Conexión en segundo plano y uso de la batería';

  @override
  String get settingsSectionNotificationForwarding =>
      'Reenvío de notificaciones';

  @override
  String get settingsSectionNotificationForwardingDesc =>
      'Gestión de notificaciones de Android y ayuda con códigos de verificación';

  @override
  String get settingsSectionLanguageFiles => 'Idioma y archivos';

  @override
  String get settingsSectionLanguageFilesDesc =>
      'Idioma, carpeta de guardado e información de la aplicación';

  @override
  String get settingsSaveDirectory => 'Carpeta de guardado';

  @override
  String get settingsChangeDirectory => 'Cambiar carpeta de guardado';

  @override
  String get settingsOpenDirectory => 'Abrir carpeta de guardado';

  @override
  String get settingsVersion => 'Versión';

  @override
  String get appListSearchPlaceholder => 'Buscar aplicaciones';

  @override
  String get appListClearSearch => 'Borrar búsqueda de aplicaciones';

  @override
  String get deselectAll => 'Deseleccionar todo';

  @override
  String get settingsLoadFailedTitle => 'No se pudieron cargar los ajustes';

  @override
  String get settingsLoadFailedBody =>
      'Comprueba los servicios locales de la aplicación e inténtalo de nuevo.';

  @override
  String get appListLoadFailedTitle => 'No se pudieron cargar las aplicaciones';

  @override
  String get appListLoadFailedBody =>
      'Comprueba el acceso a las aplicaciones e inténtalo de nuevo.';

  @override
  String get appListSaveFailed =>
      'No se pudo guardar la selección de aplicaciones de notificaciones';

  @override
  String get notificationApps => 'Aplicaciones de notificaciones';

  @override
  String notificationAppsSelected(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count aplicaciones seleccionadas',
      one: '1 aplicación seleccionada',
      zero: 'No hay aplicaciones seleccionadas',
    );
    return '$_temp0';
  }

  @override
  String get notificationAppsDisabled =>
      'Activa el reenvío de notificaciones para elegir aplicaciones';

  @override
  String get notificationForwardingUpdateFailed =>
      'No se pudo actualizar el reenvío de notificaciones';

  @override
  String get dangerousActions => 'Acciones peligrosas';

  @override
  String get pairingNewDeviceTitle => 'Emparejar un dispositivo nuevo';

  @override
  String pairingNewDeviceDescription(String device) {
    return '$device quiere establecer una conexión de confianza';
  }

  @override
  String get pairingIdentityChangedTitle =>
      'La identidad del dispositivo ha cambiado';

  @override
  String pairingIdentityChangedDescription(String device) {
    return 'La clave de identidad de $device no coincide con el emparejamiento anterior. Continúa solo si el dispositivo se reinstaló o restableció';
  }

  @override
  String get pairingLegacyTrustTitle =>
      'Confirma de nuevo este dispositivo de confianza';

  @override
  String pairingLegacyTrustDescription(String device) {
    return '$device usa un registro de confianza antiguo y debe emparejarse de nuevo para vincular su identidad';
  }

  @override
  String get pairingCompareCode =>
      'Confirma que ambos dispositivos muestran el mismo código de seis dígitos';

  @override
  String get pairingNotificationBody =>
      'Abre Whisper para comparar en la app el código de emparejamiento de seis dígitos';

  @override
  String pairingCodeSemantics(String code) {
    return 'Código de emparejamiento $code';
  }

  @override
  String get pairingReject => 'Rechazar';

  @override
  String get pairingApprove => 'Los códigos coinciden';

  @override
  String get pairingUpgradeRequired =>
      'El otro dispositivo está desactualizado. Actualiza Whisper e inténtalo de nuevo';

  @override
  String get pairingExpired => 'La solicitud de emparejamiento ha caducado';

  @override
  String get pairingRejectedByPeer =>
      'El otro dispositivo rechazó la solicitud de conexión';
}
