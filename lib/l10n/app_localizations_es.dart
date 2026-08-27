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
    int percent,
    String speed,
    String remaining,
  ) {
    return 'Enviando $percent% · $speed · quedan $remaining';
  }

  @override
  String transferNotificationBodyReceiving(
    int percent,
    String speed,
    String remaining,
  ) {
    return 'Recibiendo $percent% · $speed · quedan $remaining';
  }

  @override
  String transferNotificationBodyMixed(
    int percent,
    String speed,
    String remaining,
  ) {
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
  String get sendFiles => 'Enviar archivos';

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
  String get clipboardAutoSync => 'Sincronizar el portapapeles automáticamente';

  @override
  String get clipboardAutoSyncDesc =>
      'Desactivado: envío manual; activado: solo se sincroniza con el dispositivo de confianza actual';

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
      'Desconecta y borra todos los mensajes de este dispositivo. No se puede recuperar.';

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
  String get selectMessages => 'Seleccionar mensajes';

  @override
  String selectedMessageCount(int count) {
    return '$count seleccionados';
  }

  @override
  String deleteSelectedMessagesTitle(int count) {
    return 'Eliminar $count mensajes';
  }

  @override
  String get deleteSelectedMessagesDesc =>
      'Se eliminarán los registros seleccionados. Los archivos locales se conservarán.';

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
  String get copyFile => 'Copiar archivo';

  @override
  String get fileCopied => 'Archivo copiado';

  @override
  String get fileCopyFailed => 'No se pudo copiar el archivo';

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
      'Mantiene activa la recepcion por LAN para recibir solicitudes de conexion en segundo plano o con la pantalla bloqueada';

  @override
  String get androidBackgroundKeepAliveActiveTitle =>
      'Whisper escucha conexiones LAN';

  @override
  String get androidBackgroundKeepAliveActiveDesc =>
      'Puede recibir solicitudes de dispositivos cercanos en segundo plano';

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
  String get fileTransferWaitingPeerVerification =>
      'Esperando verificacion del otro dispositivo';

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
    Object latePackets,
  ) {
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
    Object latePackets,
  ) {
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
      'Primero coloca la pantalla del otro dispositivo contra el borde en el espacio de teclado y mouse';

  @override
  String get remoteInputEnabledMoveToEdge =>
      'Compartir teclado y mouse esta activado. Mueve al borde de la pantalla para controlar el otro dispositivo';

  @override
  String remoteInputFailed(String error) {
    return 'Error al compartir teclado y mouse: $error';
  }

  @override
  String get remoteInputLayoutTitle => 'Distribucion de pantalla';

  @override
  String get remoteInputLocalScreen => 'Este dispositivo';

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
  String get remoteInputWorkspaceReachable => 'Accesible';

  @override
  String get remoteInputWorkspaceDisconnected =>
      'No conectado al espacio de trabajo';

  @override
  String get remoteInputWorkspaceUnsupported =>
      'No admite rutas del espacio de trabajo';

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
  String get settingsSectionLanguageFilesDesc => 'Idioma y carpeta de guardado';

  @override
  String get settingsSaveDirectory => 'Carpeta de guardado';

  @override
  String get settingsChangeDirectory => 'Cambiar carpeta de guardado';

  @override
  String get settingsOpenDirectory => 'Abrir carpeta de guardado';

  @override
  String get settingsVersion => 'Versión';

  @override
  String get settingsSectionAbout => 'Acerca de';

  @override
  String get settingsSectionAboutDesc =>
      'Actualizaciones e información de la aplicación';

  @override
  String get checkForUpdates => 'Buscar actualizaciones';

  @override
  String currentVersion(String version) {
    return 'Versión actual $version';
  }

  @override
  String get checkingForUpdates => 'Buscando actualizaciones…';

  @override
  String updateAvailableVersion(String version) {
    return 'Actualización disponible: $version';
  }

  @override
  String get updateUpToDate => 'Ya tienes la última versión';

  @override
  String get updateCheckFailed =>
      'No se pudieron buscar actualizaciones. Inténtalo más tarde';

  @override
  String updateAvailableTitle(String version) {
    return 'La versión $version está disponible';
  }

  @override
  String updateAvailableBody(String currentVersion, String latestVersion) {
    return 'Tienes la versión $currentVersion. La versión $latestVersion está lista. La descarga se verificará con el hash de GitHub antes de abrirse.';
  }

  @override
  String get downloadAndInstallUpdate => 'Actualizar';

  @override
  String get viewRelease => 'Ver versión';

  @override
  String downloadingUpdate(int progress) {
    return 'Descargando $progress%';
  }

  @override
  String get updateInstallerOpened =>
      'La actualización verificada está lista en el instalador del sistema';

  @override
  String get updateInstallFailed =>
      'No se pudo abrir el instalador. Inténtalo más tarde';

  @override
  String get aboutWhisper => 'Acerca de Whisper';

  @override
  String get aboutWhisperDescription =>
      'Una aplicación de colaboración en red local para tus dispositivos';

  @override
  String get officialWebsite => 'Sitio web oficial';

  @override
  String get sourceCode => 'Código fuente en GitHub';

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
  String pairingNewDeviceCompareCode(String device) {
    return '$device quiere conectarse. Confirma que los números coincidan';
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
  String pairingNotificationBody(String device, String code) {
    return 'Código $code · Compáralo con $device';
  }

  @override
  String pairingInitiatorNotificationBody(String device, String code) {
    return 'Código $code · Esperando a $device';
  }

  @override
  String pairingIdentityChangedNotificationBody(String device, String code) {
    return 'Código $code · La identidad de $device cambió; abre Whisper para ver los detalles';
  }

  @override
  String pairingCodeSemantics(String code) {
    return 'Código de emparejamiento $code';
  }

  @override
  String get pairingReject => 'Rechazar';

  @override
  String get pairingApprove => 'Los códigos coinciden';

  @override
  String get pairingViewDetails => 'Ver detalles';

  @override
  String get pairingUpgradeRequired =>
      'El otro dispositivo está desactualizado. Actualiza Whisper e inténtalo de nuevo';

  @override
  String get pairingExpired => 'La solicitud de emparejamiento ha caducado';

  @override
  String get pairingRejectedByPeer =>
      'El otro dispositivo rechazó la solicitud de conexión';

  @override
  String get pairingEncryptionNotice =>
      'Tras emparejar, el texto, los archivos, el portapapeles y los datos de control se cifran de extremo a extremo';

  @override
  String get e2eeTrustedConnection =>
      'Cifrado de extremo a extremo · Dispositivo de confianza';

  @override
  String get e2eeEncryptedConnection => 'Conexión cifrada de extremo a extremo';

  @override
  String get transferAssistantTitle => 'Asistente de transferencias';

  @override
  String get transferAssistantSearchHint => 'Buscar mensajes de texto';

  @override
  String get transferAssistantClearSearch => 'Borrar búsqueda';

  @override
  String get transferAssistantSearchResults => 'Resultados de búsqueda';

  @override
  String get transferAssistantFavorites => 'Textos favoritos';

  @override
  String get transferAssistantRecent => 'Textos recientes';

  @override
  String get transferAssistantNoResults =>
      'No se encontró ningún texto coincidente';

  @override
  String get transferAssistantNoFavorites => 'Aún no hay textos favoritos';

  @override
  String get transferAssistantNoRecent => 'Aún no hay mensajes de texto';

  @override
  String get transferAssistantIncoming => 'Recibido';

  @override
  String get transferAssistantOutgoing => 'Enviado';

  @override
  String get transferAssistantCopy => 'Copiar texto';

  @override
  String get transferAssistantFavorite => 'Añadir a favoritos';

  @override
  String get transferAssistantUnfavorite => 'Quitar de favoritos';

  @override
  String get transferAssistantLoadFailed =>
      'No se pudieron cargar los mensajes de texto';

  @override
  String get transferAssistantCopied => 'Texto copiado';

  @override
  String get transferAssistantCopyFailed => 'No se pudo copiar el texto';

  @override
  String get transferAssistantFavoriteFailed =>
      'No se pudieron actualizar los favoritos. Inténtalo de nuevo';

  @override
  String get qrPairingTitle => 'Conectar con código QR';

  @override
  String get qrMyCode => 'Mi código QR';

  @override
  String get qrScanCode => 'Escanear para conectar';

  @override
  String get qrShowCodeHint =>
      'Haz que el otro dispositivo escanee este código para verificar la dirección y la identidad';

  @override
  String qrFingerprint(String fingerprint) {
    return 'Huella de identidad $fingerprint';
  }

  @override
  String get qrWifiUnavailable =>
      'No se encontró una dirección LAN válida. Conéctate a Wi-Fi y actualiza el código';

  @override
  String get qrCopyLink => 'Copiar datos de conexión';

  @override
  String get qrLinkCopied => 'Datos de conexión copiados';

  @override
  String get qrScanHint =>
      'Escanea el código que muestra Whisper en el otro dispositivo';

  @override
  String get qrCameraUnavailable =>
      'La cámara no está disponible. Permite que Whisper use la cámara en los ajustes del sistema';

  @override
  String get qrToggleTorch => 'Alternar linterna';

  @override
  String get qrSwitchCamera => 'Cambiar cámara';

  @override
  String get qrCannotPairSelf =>
      'Este es el dispositivo actual. Escanea el código de otro dispositivo';

  @override
  String get qrInvalidCode =>
      'No es un código válido de Whisper. Pide al otro dispositivo que muestre uno nuevo';

  @override
  String get connectionDiagnosticTitle => 'Diagnóstico de conexión';

  @override
  String get connectionDiagnosticWifi =>
      'No se puede alcanzar el dispositivo. Confirma que ambos usan la misma red Wi-Fi y desactiva el aislamiento de invitados o AP.';

  @override
  String get connectionDiagnosticAddress =>
      'La dirección LAN del código QR no es válida o cambió. Pide al otro dispositivo que vuelva a abrir el código y escanéalo de nuevo.';

  @override
  String get connectionDiagnosticService =>
      'Se encontró la dirección, pero Whisper no respondió. Abre Whisper en el otro dispositivo y confirma que su servicio LAN esté activo.';

  @override
  String get connectionDiagnosticFirewall =>
      'La conexión agotó el tiempo. Permite Whisper en el cortafuegos del sistema de ambos dispositivos y vuelve a intentarlo.';

  @override
  String get connectionDiagnosticIdentity =>
      'La identidad no coincide con el código QR y Whisper detuvo la conexión. Pide un código nuevo; no omitas esta comprobación.';

  @override
  String get connectionDiagnosticVersion =>
      'Los dispositivos usan versiones de protocolo incompatibles. Actualiza Whisper a la misma versión reciente y vuelve a intentarlo.';

  @override
  String get connectionDiagnosticPairing =>
      'El emparejamiento no terminó. Mantén Whisper abierto en ambos dispositivos y compara de nuevo el código.';

  @override
  String get androidSystemShareTitle => 'Enviar contenido compartido';

  @override
  String get androidSystemShareChooseTrustedDevice =>
      'Elige un dispositivo de confianza. No se enviará nada hasta que confirmes';

  @override
  String get androidSystemShareOnline => 'En línea';

  @override
  String get androidSystemShareOffline => 'Sin conexión';

  @override
  String get androidSystemShareNoTrustedDevices =>
      'No hay dispositivos de confianza disponibles. Empareja uno y confirma primero su identidad';

  @override
  String get androidSystemShareConfirmTarget => 'Confirmar destino';

  @override
  String androidSystemShareWaitingForDevice(String device) {
    return 'Esperando a $device; el envío comenzará cuando se conecte';
  }

  @override
  String androidSystemShareSendingTo(String device) {
    return 'Enviando a $device';
  }

  @override
  String androidSystemShareSentTo(String device) {
    return 'Enviado a $device';
  }

  @override
  String get androidSystemShareFailedRetained =>
      'El envío falló. El contenido compartido se conservó';

  @override
  String get androidSystemShareStillPending =>
      'El contenido compartido sigue esperando un dispositivo';

  @override
  String get androidSystemShareQueueFull =>
      'La cola está llena. Procesa los elementos existentes antes de añadir más';

  @override
  String get androidSystemShareRejected =>
      'El contenido superó un límite o no se pudo leer por completo, por lo que no se añadió';

  @override
  String get androidSystemShareTargetNeedsReselection =>
      'La identidad del dispositivo cambió o ya no es de confianza. Vuelve a elegirlo';

  @override
  String get androidSystemShareChooseAction => 'Elegir dispositivo';

  @override
  String androidSystemShareMoreFiles(int count) {
    return '$count archivos más';
  }

  @override
  String get desktopQuickSendTitle => 'Envío rápido';

  @override
  String desktopQuickSendSummary(int textCount, int fileCount) {
    return '$textCount textos · $fileCount archivos';
  }

  @override
  String desktopQuickSendMore(int count) {
    return '$count elementos más';
  }

  @override
  String desktopQuickSendFiles(int count) {
    return '$count archivos';
  }

  @override
  String get desktopQuickSendChooseDevice =>
      'Enviar a un dispositivo de confianza';

  @override
  String get desktopQuickSendNoTrustedDevices =>
      'No hay dispositivos de confianza. Empareja uno primero.';

  @override
  String get desktopQuickSendDeviceOffline =>
      'Sin conexión; el contenido seguirá pendiente';

  @override
  String get desktopQuickSendLater => 'Más tarde';

  @override
  String get desktopQuickSendSend => 'Enviar';

  @override
  String get desktopQuickSendSent =>
      'Añadido a la cola de transferencia cifrada';

  @override
  String get desktopQuickSendFailedRetained =>
      'El envío no terminó; el contenido se ha conservado';

  @override
  String get desktopQuickSendEmptyClipboard =>
      'El portapapeles no tiene contenido compatible';

  @override
  String get desktopQuickSendShortcutUnavailable =>
      'El atajo global de envío ya está en uso';

  @override
  String get desktopQuickSendDraftLimit =>
      'El envío rápido está lleno. Procesa el contenido existente antes de añadir más';

  @override
  String get desktopQuickSendFileLimit =>
      'Se seleccionaron demasiados archivos, por lo que no se añadió el contenido nuevo';

  @override
  String get desktopQuickSendTextLimit =>
      'El texto es demasiado largo, por lo que no se añadió';

  @override
  String get desktopQuickSendInvalidPath =>
      'Una ruta no es válida o es demasiado larga, por lo que no se añadió el contenido nuevo';

  @override
  String get desktopQuickSendClipboardSnapshotUnavailable =>
      'No se pudo leer el portapapeles de inmediato, por lo que no se añadió contenido que pudiera haber cambiado';

  @override
  String get desktopQuickSendTargetConflict =>
      'Parte del contenido ya se envió a otro dispositivo. Selecciona el dispositivo original para continuar';

  @override
  String get desktopQuickSendTargetNeedsReselection =>
      'La identidad cambió o ya no es de confianza. El contenido se conservó; vuelve a seleccionar un dispositivo';

  @override
  String chatTimestampYesterday(String time) {
    return 'Ayer $time';
  }

  @override
  String get messageLinkOpenFailed => 'No se pudo abrir este enlace';
}
