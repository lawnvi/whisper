// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get mobileControlSpace => 'Espacio';

  @override
  String get mobileControlEnter => 'Intro';

  @override
  String get mobileControlSymbols => 'Números y símbolos';

  @override
  String get mobileControlMoreSymbols => 'Más símbolos';

  @override
  String get mobileControlDirectKeys => 'Teclas directas';

  @override
  String get mobileControlReturnKeys => 'Volver a las teclas';

  @override
  String get mobileControlDraftHint => 'Texto, emojis o un mensaje corto…';

  @override
  String get mobileControlScrollShort => 'Desplazar';

  @override
  String get mobileControlLeftShort => 'Izquierdo';

  @override
  String get mobileControlRightShort => 'Derecho';

  @override
  String get mobileControlStopShort => 'Parar';

  @override
  String get mobileControlPermission =>
      'Permite Whisper en Ajustes del Sistema → Privacidad y seguridad → Accesibilidad en el Mac y vuelve a iniciar.';

  @override
  String get mobileControlTitle => 'Controlar ordenador';

  @override
  String get mobileControlStart => 'Iniciar control';

  @override
  String get mobileControlStop => 'Detener control';

  @override
  String get mobileControlReady => 'Listo';

  @override
  String get mobileControlActive => 'Controlando';

  @override
  String get remoteInputPeerControlling => 'Controlando este dispositivo';

  @override
  String get remoteInputPeerReceiving => 'Controlando este equipo';

  @override
  String get remoteInputPeerReady => 'Listo, esperando la entrada';

  @override
  String get remoteInputManualSessionTitle => 'Control desde el móvil';

  @override
  String get remoteInputManualSessionHint =>
      'El control desde el móvil es independiente del espacio de trabajo de abajo.';

  @override
  String get mobileControlPreparing => 'Preparando control';

  @override
  String get mobileControlAir => 'Ratón por movimiento';

  @override
  String get mobileControlTouchpad => 'Panel táctil';

  @override
  String get mobileControlHoldMove =>
      'Mantén pulsado y gira la muñeca para mover';

  @override
  String get mobileControlTouchHint =>
      'Un dedo: mover y tocar para hacer clic\nDos dedos: tocar para clic derecho, deslizar para desplazar';

  @override
  String get mobileControlHoldScroll =>
      'Mantén pulsado e inclina para desplazar';

  @override
  String get mobileControlScroll => 'Desliza para desplazar';

  @override
  String get mobileControlLeft => 'Clic izquierdo';

  @override
  String get mobileControlRight => 'Clic derecho';

  @override
  String get mobileControlKeyboard => 'Teclado virtual';

  @override
  String get mobileControlText => 'Entrada de texto';

  @override
  String get mobileControlMainKeys => 'Teclas principales';

  @override
  String get mobileControlFunctionKeys => 'Teclas de función y navegación';

  @override
  String get mobileControlSendText => 'Enviar texto';

  @override
  String get mobileControlTextHint =>
      'Selecciona un campo en el ordenador, escribe y envía.';

  @override
  String get mobileControlTextTooLong => 'Envía hasta 4 KiB de texto cada vez.';

  @override
  String get mobileControlTextUnconfirmed =>
      'Entrada sin confirmar. Borrador conservado; revisa el ordenador antes de reenviar.';

  @override
  String get mobileControlTextSent =>
      'Texto entregado al sistema. Revisa la aplicación de destino.';

  @override
  String get mobileControlSensorUnavailable =>
      'Movimiento no disponible. Se ha activado el panel táctil.';

  @override
  String get mobileControlSensitivity => 'Velocidad del puntero por movimiento';

  @override
  String get mobileControlCalibrate => 'Calibrar';

  @override
  String get mobileControlCalibrating =>
      'Mantén el teléfono quieto un momento…';

  @override
  String get mobileControlCalibrationDone => 'Calibración completada';

  @override
  String get mobileControlIdleHint =>
      'Inicia para controlar el ratón y el teclado. Al salir se detiene el control.';

  @override
  String mobileControlReceiving(String name) {
    return 'Este equipo está siendo controlado por $name';
  }

  @override
  String get mobileControlShortcutHint =>
      'Selecciona modificadores y una tecla. Se desactivan después de cada combinación.';

  @override
  String get screenshotCapture => 'Capturar región';

  @override
  String get screenshotSelectionHint =>
      'Clic en una ventana · Arrastra un área · Esc para cancelar';

  @override
  String get screenshotAdjustHint =>
      'Arrastra para mover · Ajusta los bordes · Enter para copiar · Esc para cancelar';

  @override
  String get screenshotConfirm => 'Copiar';

  @override
  String get screenshotCopied => 'Captura copiada. Pégala donde quieras.';

  @override
  String get screenshotPermissionDenied =>
      'Permite a Whisper grabar la pantalla en Ajustes del Sistema → Privacidad y seguridad y reinicia Whisper.';

  @override
  String get screenshotUnavailable =>
      'La captura de regiones no está disponible. En Linux, comprueba que el portal de capturas esté instalado y activo.';

  @override
  String get screenshotFailed =>
      'No se pudo capturar o copiar al portapapeles. Inténtalo de nuevo.';

  @override
  String get screenshotShortcutTitle => 'Atajo de captura';

  @override
  String get screenshotShortcutDesc =>
      'Selecciona una región sin ocultar Whisper y cópiala al portapapeles para pegarla manualmente.';

  @override
  String get screenshotShortcutEnabled => 'Activar atajo global';

  @override
  String get screenshotShortcutDisabled =>
      'Desactivado · el botón de captura sigue disponible';

  @override
  String get screenshotShortcutUnavailable =>
      'Atajo no registrado · pulsa para configurarlo';

  @override
  String get screenshotShortcutRecord =>
      'Pulsa aquí y presiona una combinación de teclas';

  @override
  String get screenshotShortcutHint =>
      'Usa Ctrl, Alt o Command/Super con una letra, número o F1–F12. Esc cancela la captura. En Wayland, confirma el atajo en el diálogo del sistema.';

  @override
  String get screenshotShortcutReset => 'Restaurar atajo predeterminado';

  @override
  String get screenshotShortcutInvalid =>
      'Usa una combinación válida distinta del atajo de envío rápido.';

  @override
  String get screenshotShortcutFailed =>
      'No se pudo guardar el atajo. Puede estar ocupado, cancelado o no ser compatible. Prueba otra combinación.';

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
      'Sincroniza con el dispositivo de confianza actual o con los dispositivos conectados del espacio de teclado y ratón';

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
      'Se eliminarán los mensajes seleccionados. No se puede deshacer.';

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
  String get windowsLockScreenInput =>
      'Teclado y ratón en la pantalla de bloqueo y UAC';

  @override
  String get windowsLockScreenInputHint =>
      'Escribe en la pantalla de bloqueo. El interruptor añade los avisos de UAC';

  @override
  String get windowsLockScreenInputDesc =>
      'Se instalará un servicio del sistema para que los dispositivos de confianza puedan escribir en la pantalla de bloqueo de este PC. Requiere aprobación de administrador.';

  @override
  String get windowsLockScreenInputUninstallDesc =>
      'Tras desinstalarlo, ya no se podrán controlar la pantalla de bloqueo ni los avisos de UAC de este PC. Requiere aprobación de administrador.';

  @override
  String get windowsLockScreenInputNotInstalled => 'No instalado';

  @override
  String get windowsLockScreenInputRunning => 'En ejecución';

  @override
  String get windowsLockScreenInputStopped => 'Detenido';

  @override
  String get windowsLockScreenInputOutdated => 'Requiere actualización';

  @override
  String get windowsLockScreenInputInstall => 'Instalar';

  @override
  String get windowsLockScreenInputRepair => 'Reparar';

  @override
  String get windowsLockScreenInputUninstall => 'Desinstalar';

  @override
  String get windowsLockScreenInputWorking =>
      'Esperando al servicio del sistema…';

  @override
  String get windowsLockScreenInputFailed =>
      'No se pudo cambiar el servicio de entrada de la pantalla de bloqueo';

  @override
  String get windowsElevatedInput => 'Responder a avisos de UAC';

  @override
  String get windowsElevatedInputEnableDesc =>
      'Los dispositivos de confianza podrán responder a los avisos de UAC, pero cualquier programa que se ejecute como tú en este PC podrá saltarse UAC del mismo modo. Requiere aprobación de administrador.';

  @override
  String get windowsElevatedInputDisableDesc =>
      'Los dispositivos de confianza ya no podrán responder a los avisos de UAC. La pantalla de bloqueo no cambia. Requiere aprobación de administrador.';

  @override
  String get windowsElevatedInputEnable => 'Activar';

  @override
  String get windowsElevatedInputDisable => 'Desactivar';

  @override
  String get windowsElevatedInputFailed =>
      'No se pudo cambiar el control de UAC';

  @override
  String get launchAtStartup => 'Iniciar al arrancar';

  @override
  String get launchAtStartupDesc =>
      'Inicia Whisper automaticamente al iniciar sesion para reconectar dispositivos de confianza';

  @override
  String get launchAtStartupFailed =>
      'No se pudo actualizar el inicio automatico';

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
  String get fileTransferFailedNotice => 'No se pudo transferir el archivo';

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
  String get remoteInputWorkspaceNoTargetsHint =>
      'Los equipos conectados y de confianza compatibles con teclado y mouse aparecerán aquí';

  @override
  String get remoteInputWorkspaceSelectTargets => 'Equipos controlados';

  @override
  String get remoteInputWorkspaceCanvasTitle => 'Distribucion de pantalla';

  @override
  String get remoteInputWorkspaceCanvasHint =>
      'Arrastra una pantalla remota hasta un borde de este equipo';

  @override
  String remoteInputWorkspaceExitShortcut(String shortcut) {
    return 'Pulsa $shortcut para dejar de compartir';
  }

  @override
  String get remoteInputWorkspaceSelectTargetHint =>
      'Selecciona al menos un equipo controlado a la izquierda';

  @override
  String get remoteInputWorkspaceLocalBadge => 'Este equipo';

  @override
  String get remoteInputWorkspaceRemoteBadge => 'Remoto';

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
  String get remoteInputWorkspaceResolution => 'Resolución';

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
  String get transferAssistantTitle => 'Buscar en el historial';

  @override
  String get transferAssistantSearchHint => 'Buscar mensajes de texto';

  @override
  String get transferAssistantClearSearch => 'Borrar búsqueda';

  @override
  String get transferAssistantSearchResults => 'Resultados de búsqueda';

  @override
  String get transferAssistantFavorites => 'Favoritos';

  @override
  String get transferAssistantRecent => 'Mensajes recientes';

  @override
  String get transferAssistantAllMessages => 'Todos los mensajes';

  @override
  String get transferAssistantExpandMessage => 'Expandir mensaje';

  @override
  String get transferAssistantCollapseMessage => 'Contraer mensaje';

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
  String get quickSendTitle => 'Envío rápido';

  @override
  String get quickSendTargets => 'Enviar a';

  @override
  String get quickSendNoConnectedDevices =>
      'Aún no hay ningún dispositivo conectado. Conecta uno para enviar.';

  @override
  String quickSendMoreFiles(int count) {
    return '$count archivos más';
  }

  @override
  String get quickSendLater => 'Más tarde';

  @override
  String get quickSendSend => 'Enviar';

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

  @override
  String get connectFirstDevice => 'Conecta tu primer dispositivo';

  @override
  String get deviceConnectionGuide =>
      'Abre Whisper en otro dispositivo conectado a la misma red Wi-Fi o local. Los dispositivos cercanos aparecen automáticamente en la lista.';

  @override
  String get manualConnectAction => 'Introducir dirección';

  @override
  String get deviceDiscoveryHelp =>
      '¿No aparecen dispositivos? Prueba el enlace por QR o permite el acceso a la red local en los ajustes del sistema de ambos dispositivos.';

  @override
  String get deviceOffline => 'Dispositivos sin conexión';

  @override
  String serverPortInUse(int port) {
    return 'El puerto $port está ocupado. Cierra otras instancias de Whisper o elige otro puerto en Ajustes e inténtalo de nuevo.';
  }

  @override
  String get serverPermissionDenied =>
      'El sistema denegó la escucha de red. Permite el acceso de Whisper a la red local, revisa el cortafuegos e inténtalo de nuevo.';

  @override
  String get serverUnavailableHelp =>
      'No se pueden recibir conexiones. Revisa la conexión de red, el permiso de red local y el cortafuegos e inténtalo de nuevo.';

  @override
  String updatePackageSaved(String path) {
    return 'El instalador se guardó en:\n$path\nPuedes volver a instalarlo más tarde.';
  }

  @override
  String get updateInstalledRestart =>
      'Actualización instalada. Vuelve a abrir Whisper para usar la nueva versión.';

  @override
  String get castReceiverTitle => 'Transmisión a TV';

  @override
  String get castReceiverHint =>
      'Activa esta opción y elige el nombre de este dispositivo en una app de vídeo de la misma red local.';

  @override
  String get castReceiverStarting => 'Iniciando…';

  @override
  String get castReceiverNoLan =>
      'No hay una dirección de red local. Conéctate a la red y vuelve a activar la transmisión.';

  @override
  String get castReceiverStartupFailed =>
      'No se pudo iniciar la transmisión. Desactívala y vuelve a activarla.';

  @override
  String get castPlay => 'Reproducir';

  @override
  String get castPause => 'Pausar';

  @override
  String get castMute => 'Silenciar';

  @override
  String get castUnmute => 'Activar sonido';

  @override
  String get castFullscreen => 'Pantalla completa';

  @override
  String get videoPlaybackFailed =>
      'No se pudo reproducir el vídeo. Reintenta o ábrelo con otra aplicación.';

  @override
  String get castPlaybackFailed =>
      'No se pudo reproducir el vídeo. Reintenta o vuelve a transmitir desde el teléfono.';

  @override
  String get castControlFailed =>
      'No se pudo aplicar el control. Inténtalo de nuevo.';

  @override
  String get castRequestTitle => '¿Permitir la transmisión?';

  @override
  String castRequestMessage(String address) {
    return 'Un dispositivo en $address quiere reproducir un vídeo aquí.';
  }

  @override
  String castRequestCountdown(int seconds) {
    return 'Se permitirá en $seconds segundos. Puedes rechazarla.';
  }

  @override
  String get castRequestDeny => 'Rechazar';

  @override
  String get castRequestAllow => 'Permitir';

  @override
  String get castExitFullscreen => 'Salir de pantalla completa';

  @override
  String get castSeek => 'Posición de reproducción';

  @override
  String get castVolume => 'Volumen';

  @override
  String get mobileControlPointer => 'Ratón';

  @override
  String get mobileControlKeysTab => 'Teclado';

  @override
  String get mobileControlTextTab => 'Texto';

  @override
  String get mobileControlSettings => 'Ajustes del puntero';

  @override
  String get mobileControlLiftHint =>
      'Levanta el dedo para pausar y recolocar.';

  @override
  String get mobileControlDragHint =>
      'Mantén el botón izquierdo para arrastrar.';

  @override
  String get mobileControlPrecisionHint =>
      'Mueve despacio para mayor precisión. Gira más rápido para recorrer más distancia.';

  @override
  String get mobileControlCalibrationRetry =>
      'Mantén el teléfono quieto y vuelve a calibrar.';

  @override
  String get mobileControlStartShort => 'Iniciar';

  @override
  String get mobileControlMotionStart => 'Activar movimiento';

  @override
  String get mobileControlMotionPause => 'Pausar movimiento';

  @override
  String get mobileControlMotionOnHint =>
      'Gira la muñeca para mover. Toca aquí para pausar.';

  @override
  String get mobileControlMotionOffHint =>
      'Toca una vez y mueve sin mantener pulsada la pantalla.';

  @override
  String get mobileControlTarget => 'Equipo a controlar';

  @override
  String get mobileControlTargetHint => 'Vuelve a iniciar al cambiar.';

  @override
  String get mobileControlPointerSpeed =>
      'Velocidad del puntero del panel táctil';

  @override
  String get mobileControlScrollSpeed => 'Velocidad de desplazamiento';

  @override
  String get mobileControlScrollRail => 'Desliza\npara desplazar';

  @override
  String get mobileControlPermissionDesktop =>
      'Permite el control remoto en el equipo y vuelve a iniciar. En Linux, acepta la solicitud de control remoto del sistema.';

  @override
  String get mobileControlLinuxTextHint =>
      'Linux solo puede enviar caracteres disponibles en la distribución de teclado del equipo. Para chino y emoji, usa el teclado virtual con el método de entrada del equipo. El texto no compatible se conserva en el borrador.';

  @override
  String get manualConnectAddressInvalid =>
      'Introduce una IP de red local o dirección .local válida';

  @override
  String get manualConnectPortInvalid => 'Usa un puerto entre 1 y 65535';

  @override
  String get transferStorageHelp =>
      'No se puede guardar. Revisa el espacio y los permisos de la carpeta del receptor.';

  @override
  String get transferSourceHelp =>
      'No se puede leer el archivo de origen. Selecciónalo de nuevo.';

  @override
  String get transferIntegrityHelp =>
      'Falló la verificación del archivo. Reintenta la transferencia.';

  @override
  String get transferQueueHelp =>
      'El receptor está ocupado. Inténtalo de nuevo en un momento.';

  @override
  String get transferTrustHelp =>
      'Confirma de nuevo la confianza del dispositivo antes de enviar.';

  @override
  String get transferRetryHelp =>
      'Transferencia incompleta. Conecta los dispositivos y vuelve a intentarlo.';

  @override
  String get mobileControlTransportHelp =>
      'Se interrumpió la conexión de control. Abre Whisper en el ordenador y vuelve a iniciar.';

  @override
  String get mobileControlInjectionHelp =>
      'El ordenador no pudo procesar la entrada. Revisa los permisos de control y vuelve a iniciar.';

  @override
  String get clipboardAutoSyncAndroidDesc =>
      'Sincroniza el texto copiado con el dispositivo de confianza actual al volver a Whisper';

  @override
  String get historyLoadFailed =>
      'No se pudo cargar el historial. Toca para reintentar.';

  @override
  String get deleteReceivedFilesDesc =>
      'También se eliminarán los archivos recibidos. Se conservarán los originales enviados.';

  @override
  String get keepReceivedFiles => 'Conservar archivos recibidos';

  @override
  String get messageDeleteFailed =>
      'No se pudo completar la eliminación. Inténtalo de nuevo.';

  @override
  String get connectionQrTab => 'Código QR';

  @override
  String get connectionScanTab => 'Escanear';

  @override
  String get connectionAddressTab => 'IP / puerto';

  @override
  String get connectionAddressLabel => 'Dirección IP o nombre de host';

  @override
  String get connectionDetailsTab => 'Este equipo';

  @override
  String get connectionAddressHint =>
      'Consulta la dirección y el puerto en la pantalla principal de Whisper del otro dispositivo. Ambos deben estar en la misma red local.';

  @override
  String get qrCopyFailed => 'No se pudo copiar. Inténtalo de nuevo.';

  @override
  String get attachFile => 'Archivo';

  @override
  String get attachFolder => 'Carpeta';

  @override
  String folderFileCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString archivos',
      one: '1 archivo',
      zero: 'Carpeta vacía',
    );
    return '$_temp0';
  }

  @override
  String folderSkippedCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString sin transferir';
  }

  @override
  String get folderSkippedTitle => 'Elementos no transferidos';

  @override
  String folderSkippedMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Los detalles de $countString más están en el otro dispositivo';
  }

  @override
  String get folderSkipSymlink => 'Los enlaces no se envían';

  @override
  String get folderSkipSpecial => 'No es un archivo normal';

  @override
  String get folderSkipInvalidName =>
      'El nombre no es válido en otros sistemas';

  @override
  String get folderSkipPathTooLong => 'La ruta es demasiado larga o profunda';

  @override
  String get folderSkipTooLarge => 'El archivo es demasiado grande';

  @override
  String get folderSkipUnreadable => 'No se pudo leer';

  @override
  String get folderSkipSourceUnavailable =>
      'Se movió, cambió o no se pudo leer al enviar';

  @override
  String get folderSkipWriteFailed => 'No se pudo guardar en este dispositivo';

  @override
  String get folderSkipNameCollision =>
      'Solo se diferencia de otro elemento por mayúsculas';

  @override
  String get folderSkipIntegrity => 'No superó la verificación';

  @override
  String get folderSendFailed => 'No se pudo enviar esta carpeta';

  @override
  String get folderSendUnsupported =>
      'El Whisper del otro dispositivo es demasiado antiguo para recibir carpetas. Actualízalo primero';

  @override
  String get folderSendInvalidName =>
      'El nombre de esta carpeta no es válido en otros sistemas. Cámbialo e inténtalo de nuevo';

  @override
  String get folderSendUnreadable => 'No se pudo leer esta carpeta';

  @override
  String folderSendTooManyEntries(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'Esta carpeta tiene más de $limitString elementos. Envíala por partes';
  }

  @override
  String get folderSendTooLarge =>
      'Esta carpeta supera 1 TB y no se puede enviar';

  @override
  String folderFileProgress(int done, int total) {
    final intl.NumberFormat doneNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String doneString = doneNumberFormat.format(done);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$doneString de $totalString archivos';
  }

  @override
  String get windowStreamTitle => 'Apps del teléfono';

  @override
  String get windowStreamConnecting => 'Conectando…';

  @override
  String get windowStreamPaused => 'En pausa. Haz clic para reanudar';

  @override
  String get windowStreamReconnecting => 'Reconectando…';

  @override
  String get windowStreamDisplaced =>
      'Ha vuelto al teléfono. Haz clic para traerla aquí';

  @override
  String get windowStreamSecureBlocked =>
      'Esta app no permite compartir pantalla';

  @override
  String get windowStreamAppExited => 'La app se ha cerrado';

  @override
  String get windowStreamDisconnected =>
      'Desconectado. Puedes cerrar esta ventana';

  @override
  String get windowStreamNoDevice => 'No se encontró ningún teléfono';

  @override
  String get windowStreamNoDeviceHint =>
      'Conecta el teléfono con un cable o activa la depuración inalámbrica en las opciones de desarrollador.';

  @override
  String get windowStreamUnauthorized =>
      'Permite la depuración desde este ordenador en tu teléfono';

  @override
  String get windowStreamDeviceOffline =>
      'El teléfono no responde. Vuelve a conectar el cable o reinicia la depuración inalámbrica';

  @override
  String get windowStreamAdbMissing =>
      'No se encontró adb. Instala primero Android Platform Tools';

  @override
  String get windowStreamAdbFailed => 'No se pudo iniciar el servidor adb';

  @override
  String get windowStreamUnsupported =>
      'Las ventanas de apps del teléfono aún no están disponibles en este ordenador';

  @override
  String get windowStreamRunningApps => 'En ejecución';

  @override
  String get windowStreamAllApps => 'Todas las apps';

  @override
  String get windowStreamSearchApps => 'Buscar apps';

  @override
  String get windowStreamLoadingApps => 'Cargando apps…';

  @override
  String get windowStreamOnDesktop => 'En el escritorio';

  @override
  String get windowStreamShowSystemApps => 'Mostrar apps del sistema';

  @override
  String get windowStreamRetry => 'Reintentar';

  @override
  String get windowStreamInjectDenied =>
      'En los teléfonos Xiaomi, activa también “Depuración USB (ajustes de seguridad)” en las opciones de desarrollador y reinicia el teléfono';

  @override
  String get windowStreamAndroidTooOld => 'Requiere Android 10 o posterior';

  @override
  String get windowStreamOpenFailed => 'No se pudo abrir esta app';

  @override
  String get windowStreamNoApps => 'No se encontraron apps';

  @override
  String get windowStreamSpaceTitle => 'Flujo';

  @override
  String get windowStreamRecents => 'Recientes';

  @override
  String get windowStreamWindows => 'Ventanas';

  @override
  String get windowStreamApps => 'Apps';

  @override
  String get windowStreamViaUsb => 'Conectado por USB';

  @override
  String get windowStreamViaWifi => 'Depuración inalámbrica';

  @override
  String get windowStreamViaWhisper => 'Conectado';

  @override
  String get windowStreamStatusLive => 'En vivo';

  @override
  String get windowStreamStatusPaused => 'En pausa';

  @override
  String get windowStreamStatusConnecting => 'Conectando';

  @override
  String get windowStreamStatusEnded => 'Desconectado';

  @override
  String get windowStreamPause => 'Pausar';

  @override
  String get windowStreamResume => 'Reanudar';

  @override
  String get windowStreamClose => 'Cerrar';

  @override
  String get windowStreamNoWindows => 'No hay ventanas abiertas';

  @override
  String get windowStreamNoWindowsHint =>
      'Abre una app o una tarea reciente y aparecerá aquí';

  @override
  String get windowStreamNoDevices => 'Aún no hay dispositivos';

  @override
  String get windowStreamNoDevicesHintDesktop =>
      'Conecta un teléfono Android con un cable o activa la depuración inalámbrica en sus opciones de desarrollador.';

  @override
  String get windowStreamNoDevicesHintMobile =>
      'Abre Whisper en tu Mac y confiad el uno en el otro; sus ventanas aparecerán aquí.';

  @override
  String get windowStreamLoadFailed =>
      'No se pudieron cargar las apps de este dispositivo';

  @override
  String get windowStreamBackToSpace => 'Volver a Flujo';

  @override
  String get windowStreamKeyboard => 'Teclado';

  @override
  String get windowStreamNoRecents =>
      'No hay nada en ejecución en este dispositivo';

  @override
  String get windowStreamSourceLocked =>
      'Este ordenador está bloqueado. Desbloquéalo para transmitir sus ventanas.';

  @override
  String get windowStreamCapturePermission =>
      'Este ordenador aún no permite que Whisper grabe su pantalla. Actívalo en Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla.';

  @override
  String get windowStreamUntrusted =>
      'Whisper en este teléfono aún no está vinculado con este dispositivo. Abre Whisper en el teléfono, conéctate a este dispositivo y confirma la vinculación para transmitir.';

  @override
  String get windowStreamWhisperMissing =>
      'Este teléfono no tiene un Whisper utilizable. Instala la última versión de Whisper y vincúlala con este dispositivo para transmitir.';

  @override
  String get windowStreamNotPaired => 'Sin vincular';

  @override
  String get windowStreamOpenHere => 'Abrir aquí';

  @override
  String windowStreamSendTo(String device) {
    return 'Enviar a $device';
  }

  @override
  String windowStreamSendHint(String device) {
    return 'Elige una ventana de este ordenador para enviarla a $device. Al abrirla allí sale de esta pantalla y vuelve cuando se cierra en $device.';
  }

  @override
  String windowStreamSent(String device) {
    return 'Enviada a $device. Toca el aviso allí para verla.';
  }

  @override
  String get windowStreamSendFailed =>
      'No se pudo enviar. Comprueba que ese dispositivo esté conectado a este.';

  @override
  String windowStreamSendUnavailable(String device) {
    return 'Whisper en $device debe estar conectado a este ordenador y actualizado para recibir ventanas.';
  }

  @override
  String get windowStreamNoLocalWindows =>
      'No hay ventanas en este ordenador para enviar';

  @override
  String windowStreamOfferTitle(String device) {
    return '$device te envió una ventana';
  }

  @override
  String get windowStreamOfferView => 'Ver';

  @override
  String windowStreamOfferFrom(String device) {
    return 'De $device';
  }

  @override
  String get remoteFilesTitle => 'Archivos';

  @override
  String remoteFilesOfDevice(String device) {
    return 'Archivos de $device';
  }

  @override
  String get remoteFilesThisDevice => 'Este dispositivo';

  @override
  String remoteFilesWaiting(String device) {
    return 'Esperando a que $device lo permita…';
  }

  @override
  String remoteFilesDenied(String device) {
    return '$device no permitió explorar sus archivos';
  }

  @override
  String remoteFilesOffline(String device) {
    return '$device no está conectado ahora';
  }

  @override
  String remoteFilesUnsupported(String device) {
    return 'Whisper en $device necesita actualizarse para explorar sus archivos';
  }

  @override
  String get remoteFilesEmptyFolder => 'Esta carpeta está vacía';

  @override
  String remoteFilesCopyTo(String target) {
    return 'Copiar a $target';
  }

  @override
  String get remoteFilesNewFolder => 'Nueva carpeta';

  @override
  String get remoteFilesFolderName => 'Nombre de la carpeta';

  @override
  String get remoteFilesRename => 'Cambiar nombre';

  @override
  String get remoteFilesMoveToTrash => 'Mover a la papelera';

  @override
  String get remoteFilesDelete => 'Eliminar';

  @override
  String remoteFilesDeleteForever(int count) {
    return '¿Eliminar estos $count elementos para siempre? Este dispositivo no tiene papelera y no se podrán recuperar.';
  }

  @override
  String remoteFilesCopyStarted(int count) {
    return 'Copiando $count elementos';
  }

  @override
  String get remoteFilesFailed => 'No se pudo completar';

  @override
  String get remoteFilesNameExists => 'Ya hay algo con ese nombre aquí';

  @override
  String get remoteFilesShowHidden => 'Mostrar archivos ocultos';

  @override
  String remoteFilesItemCount(int count) {
    return '$count elementos';
  }

  @override
  String remoteFilesSelected(int count) {
    return '$count seleccionados';
  }

  @override
  String get remoteFilesCreate => 'Crear';

  @override
  String get remoteFilesDone => 'Listo';

  @override
  String remoteFilesDropHint(String device) {
    return 'Suelta aquí para copiar a $device';
  }

  @override
  String get remoteFilesPlaceRoot => 'Inicio';

  @override
  String get remoteFilesPlaceStorage => 'Almacenamiento interno';

  @override
  String get remoteFilesPlaceDesktop => 'Escritorio';

  @override
  String get remoteFilesPlaceDocuments => 'Documentos';

  @override
  String get remoteFilesPlaceDownloads => 'Descargas';

  @override
  String get remoteFilesPlacePictures => 'Imágenes';

  @override
  String get remoteFilesPlaceCamera => 'Cámara';

  @override
  String get remoteFilesPlaceMovies => 'Películas';

  @override
  String get remoteFilesPlaceMusic => 'Música';

  @override
  String remoteFilesPromptTitle(String device) {
    return '$device quiere explorar tus archivos';
  }

  @override
  String get remoteFilesPromptBodyDesktop =>
      'Si lo permites, podrá ver tu carpeta de inicio y copiar, crear, renombrar y eliminar archivos allí. Lo eliminado irá a la papelera.';

  @override
  String get remoteFilesPromptBodyPhone =>
      'Si lo permites, podrá ver el almacenamiento interno de este teléfono y copiar, crear, renombrar y eliminar archivos allí. Antes de eliminar se vuelve a preguntar.';

  @override
  String get remoteFilesDeny => 'No permitir';

  @override
  String get remoteFilesAllowOnce => 'Permitir esta vez';

  @override
  String get remoteFilesAllowAlways => 'Permitir siempre';

  @override
  String windowStreamTouchBlockedTitle(String device) {
    return '$device no responde al tacto';
  }

  @override
  String windowStreamTouchBlockedBody(String app) {
    return 'Una página que $app dejó en segundo plano cubre la pantalla del teléfono y los toques no llegan. Cerrar esa página lo arregla; $app sigue instalada con su cuenta e historial.';
  }

  @override
  String get windowStreamTouchBlockedFix => 'Cerrar esa página';

  @override
  String get windowStreamTouchBlockedLater => 'Ahora no';

  @override
  String get windowStreamTouchBlockedFixed =>
      'Listo. El teléfono vuelve a responder.';

  @override
  String get remoteFilesFavorites => 'Favoritos';

  @override
  String get remoteFilesLocations => 'Ubicaciones';

  @override
  String get remoteFilesBrowse => 'Explorar';

  @override
  String remoteFilesWaitingAllow(String device) {
    return 'Toca «Permitir» en $device';
  }

  @override
  String get remoteFilesWaitingDetail =>
      'Whisper está preguntando allí si este dispositivo puede explorar sus archivos.';

  @override
  String get remoteFilesAskAgain => 'Volver a preguntar';

  @override
  String get remoteFilesColumnName => 'Nombre';

  @override
  String get remoteFilesColumnModified => 'Fecha de modificación';

  @override
  String get remoteFilesColumnSize => 'Tamaño';

  @override
  String get remoteFilesColumnKind => 'Tipo';

  @override
  String get remoteFilesKindFolder => 'Carpeta';

  @override
  String get remoteFilesKindImage => 'Imagen';

  @override
  String get remoteFilesKindVideo => 'Vídeo';

  @override
  String get remoteFilesKindAudio => 'Audio';

  @override
  String get remoteFilesKindDocument => 'Documento';

  @override
  String get remoteFilesKindArchive => 'Archivo comprimido';

  @override
  String get remoteFilesKindCode => 'Código fuente';

  @override
  String get remoteFilesKindApp => 'Aplicación';

  @override
  String get remoteFilesKindOther => 'Archivo';

  @override
  String remoteFilesKindNamed(String ext, String kind) {
    return '$kind $ext';
  }

  @override
  String get remoteFilesViewList => 'Lista';

  @override
  String get remoteFilesViewIcons => 'Iconos';

  @override
  String get remoteFilesSearch => 'Buscar';

  @override
  String remoteFilesNoResults(String query) {
    return 'Sin resultados para «$query»';
  }

  @override
  String get remoteFilesForward => 'Adelante';

  @override
  String get remoteFilesOpen => 'Abrir';

  @override
  String get remoteFilesCopy => 'Copiar';

  @override
  String remoteFilesPaste(int count) {
    return 'Pegar $count elementos';
  }

  @override
  String get remoteFilesRefresh => 'Actualizar';

  @override
  String remoteFilesStatusSelected(int selected, int count) {
    return '$selected de $count seleccionados';
  }

  @override
  String remoteFilesCopyProgress(int count, int percent) {
    return 'Copiando $count elementos · $percent %';
  }

  @override
  String remoteFilesCopyDone(int count) {
    return '$count elementos copiados';
  }

  @override
  String remoteFilesCopyPartly(int failed) {
    return '$failed elementos no se copiaron';
  }

  @override
  String get remoteFilesSameDevice => 'Ya está en este dispositivo';

  @override
  String get remoteFilesBetweenOthers =>
      'Solo se copia entre este dispositivo y otro';

  @override
  String remoteFilesOpenFirst(String device) {
    return 'Abre primero los archivos de $device';
  }

  @override
  String get remoteFilesUntitledFolder => 'carpeta sin título';

  @override
  String get remoteFilesSelect => 'Seleccionar';

  @override
  String get remoteFilesSelectAll => 'Seleccionar todo';

  @override
  String get remoteFilesCopyToMenu => 'Copiar en…';

  @override
  String get remoteFilesCopyHere => 'Copiar aquí';

  @override
  String get remoteFilesChooseDestination =>
      'Elige una carpeta y toca «Copiar aquí»';

  @override
  String remoteFilesToday(String time) {
    return 'Hoy, $time';
  }

  @override
  String remoteFilesYesterday(String time) {
    return 'Ayer, $time';
  }

  @override
  String get remoteFilesCopyToSubmenu => 'Copiar en';

  @override
  String remoteFilesPasteInto(String name) {
    return 'Pegar en «$name»';
  }

  @override
  String get remoteFilesPastePlain => 'Pegar';

  @override
  String get remoteFilesSortBy => 'Ordenar por';

  @override
  String get remoteFilesMore => 'Más';

  @override
  String get remoteFilesClose => 'Cerrar archivos';

  @override
  String get remoteFilesClipboardReady => 'Listo para pegar en otras apps';

  @override
  String get remoteFilesClipboardOnPaste =>
      'Copiado. Se transfiere al pegarlo en Whisper.';

  @override
  String remoteFilesClipboardOnPasteDrag(String app) {
    return 'Copiado. Se envía al pegarlo en Whisper; arrástralo para llevarlo a $app';
  }

  @override
  String get windowStreamTextSize => 'Tamaño del texto';

  @override
  String get macPermissionAccessibility => 'Accesibilidad';

  @override
  String get macPermissionAccessibilityDesc =>
      'Necesario para compartir teclado y ratón y usar ventanas transmitidas';

  @override
  String get macPermissionScreenRecording =>
      'Grabación de pantalla y audio del sistema';

  @override
  String get macPermissionScreenRecordingDesc =>
      'Necesario para transmitir ventanas, reproducir el sonido del Mac en otro sitio y hacer capturas; se aplica al volver a abrir Whisper';

  @override
  String get macPermissionAudioCapture => 'Solo grabación de audio del sistema';

  @override
  String get macPermissionAudioCaptureDesc =>
      'Opcional. Sin él el sonido también se envía; con él este Mac queda en silencio y también llega el sonido de los navegadores';

  @override
  String get macPermissionGranted => 'Permitido';

  @override
  String get macPermissionDenied => 'No permitido';

  @override
  String get macPermissionNotAsked => 'Sin configurar';

  @override
  String get macPermissionOptional => 'Opcional';

  @override
  String get windowStreamQuality => 'Calidad';

  @override
  String get windowStreamQualitySmooth => 'Fluida';

  @override
  String get windowStreamQualityStandard => 'Estándar';

  @override
  String get windowStreamQualityHigh => 'Alta';

  @override
  String get windowStreamQualityBest => 'Máxima';

  @override
  String get windowStreamQualityHint =>
      'Más nítida cuanto más alta, con más uso de red';

  @override
  String get windowStreamReceiveOnly => 'Solo recibe ventanas';

  @override
  String get windowStreamNotConnected => 'Sin conectar';

  @override
  String get windowStreamConnectFirst =>
      'Conéctate primero a este teléfono en Whisper para transmitir sus apps';

  @override
  String windowStreamOpenHereDetail(String device) {
    return 'Usa las apps de $device';
  }

  @override
  String windowStreamSendToDetail(String device) {
    return 'Mueve una ventana a $device';
  }

  @override
  String get toolbarMoreTools => 'Más funciones';

  @override
  String get toolbarFewerTools => 'Mostrar menos';

  @override
  String get windowStreamStreaming => 'Abierta aquí';

  @override
  String get windowStreamCloseWindow => 'Cerrar ventana';

  @override
  String get windowStreamCloseFailed => 'No se pudo cerrar la ventana';

  @override
  String get windowStreamOfferIgnore => 'Descartar';

  @override
  String get deviceDetailsTitle => 'Detalles del dispositivo';

  @override
  String get deviceFeaturesSection => 'Funciones';

  @override
  String get deviceFeatureFlowDetail =>
      'Usa sus apps y ventanas o envíale ventanas';

  @override
  String get deviceFeatureFilesDetail => 'Explora y copia sus archivos';

  @override
  String get deviceFeatureNeedsConnection => 'Disponible al conectar';

  @override
  String get windowStreamSwitcherRotate => 'Girar';

  @override
  String get remoteFilesCopyStarting => 'Preparando…';

  @override
  String remoteFilesCopyItems(int count) {
    return '$count elementos';
  }

  @override
  String remoteFilesCopyToDevice(String device, String folder) {
    return 'A «$folder» en $device';
  }

  @override
  String get remoteFilesFinder => 'Finder';

  @override
  String get remoteFilesExplorer => 'Explorador de archivos';

  @override
  String get remoteFilesFileManager => 'Archivos';

  @override
  String remoteFilesShowInApp(String app) {
    return 'Abrir en $app';
  }

  @override
  String get remoteFilesEject => 'Expulsar';

  @override
  String remoteFilesMountTooOld(String device, String app) {
    return 'Whisper en $device necesita actualizarse para abrir sus archivos en $app';
  }

  @override
  String remoteFilesMountDenied(String device) {
    return '$device no permitió el acceso a sus archivos';
  }

  @override
  String remoteFilesMountFailed(String app, String device) {
    return '$app no pudo abrir los archivos de $device';
  }

  @override
  String remoteFilesMountNeedsFuse(String app) {
    return 'Instala fuse3 para abrir los archivos de otros dispositivos en $app';
  }

  @override
  String remoteFilesCopyFromDevice(String device, String folder) {
    return 'De $device a «$folder»';
  }

  @override
  String remoteFilesCopyLeft(String time) {
    return 'Quedan $time';
  }

  @override
  String remoteFilesSeconds(int count) {
    return '$count s';
  }

  @override
  String remoteFilesMinutes(int count) {
    return '$count min';
  }

  @override
  String remoteFilesHours(int count) {
    return '$count h';
  }

  @override
  String remoteFilesCopyItemsDone(int done, int total) {
    return '$done de $total';
  }

  @override
  String remoteFilesCopyFilesMoved(int count) {
    return '$count archivos hasta ahora';
  }

  @override
  String remoteFilesCopyWaiting(String device) {
    return 'Esperando a que vuelva $device…';
  }

  @override
  String get remoteFilesCopyPaused => 'En pausa';

  @override
  String get remoteFilesCopyFailedShort => 'No se pudo copiar';

  @override
  String get remoteFilesCopyCanceledShort => 'Detenida';

  @override
  String get remoteFilesCopyDoneShort => 'Copiado';

  @override
  String get remoteFilesCopyResume => 'Reanudar';

  @override
  String get remoteFilesCopyRetry => 'Reintentar';

  @override
  String get remoteFilesCopyStop => 'Detener copia';

  @override
  String get remoteFilesCopyShowAll => 'Ver todas las transferencias';

  @override
  String remoteFilesCopyMore(int count) {
    return '$count copias más';
  }

  @override
  String get remoteFilesCopyAlready => 'Ya se están copiando aquí';

  @override
  String get remoteFilesTransfers => 'Transferencias';

  @override
  String get remoteFilesTransfersEmpty => 'Aún no hay copias';

  @override
  String get remoteFilesTransfersEmptyDetail =>
      'Los archivos copiados aquí muestran aquí su progreso y resultado';

  @override
  String get remoteFilesTransfersClear => 'Borrar terminadas';

  @override
  String get remoteFilesTransfersActive => 'En curso';

  @override
  String get remoteFilesTransfersRecent => 'Terminadas';

  @override
  String get remoteFilesCopyRemove => 'Quitar de la lista';

  @override
  String get remoteFilesCopyReveal => 'Mostrar en Archivos';

  @override
  String remoteFilesDeleteTitle(int count) {
    return '¿Eliminar $count elementos para siempre?';
  }

  @override
  String remoteFilesDeleteDetail(String device) {
    return '$device no tiene papelera: una vez eliminados, no se pueden recuperar.';
  }

  @override
  String remoteFilesAndMore(int count) {
    return 'y $count más';
  }

  @override
  String get remoteFilesCopyJustDone => 'Ya se copió hace un momento';

  @override
  String windowStreamHostLocked(String device) {
    return '$device está bloqueado. Desbloquéalo para mostrar aquí sus ventanas.';
  }

  @override
  String windowStreamHostPermissionMac(String device) {
    return '$device aún no permite que Whisper grabe la pantalla. En ese Mac, activa Whisper en Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y audio del sistema.';
  }

  @override
  String windowStreamHostPermission(String device) {
    return '$device no permite que Whisper grabe sus ventanas. Permite la grabación de pantalla para Whisper en los ajustes de privacidad de ese ordenador y vuelve a intentarlo.';
  }

  @override
  String windowStreamHostHelper(String device) {
    return 'Falta un paso en $device: cierra la sesión en ese ordenador y vuelve a iniciarla para poder mostrar aquí sus ventanas.';
  }

  @override
  String windowStreamHostDesktopUnsupported(String device) {
    return 'El escritorio de $device aún no puede compartir ventanas. Necesita GNOME con Wayland.';
  }

  @override
  String windowStreamHostElevated(String device) {
    return 'Esta ventana se ejecuta como administrador y Whisper no puede mostrarla. En $device, vuelve a abrir la app sin permisos de administrador.';
  }

  @override
  String get windowStreamHostProtected =>
      'Esta ventana bloquea la grabación de pantalla, así que no se puede mostrar aquí.';

  @override
  String windowStreamHostEncoder(String device) {
    return '$device no pudo empezar a codificar el vídeo. Vuelve a intentarlo en un momento.';
  }

  @override
  String windowStreamHostEncoderLinux(String device) {
    return '$device no tiene un codificador de vídeo H.264, así que no puede compartir sus ventanas. Instala FFmpeg en ese ordenador, junto con el codificador x264 u openh264.';
  }

  @override
  String windowStreamHostUnsupported(String device) {
    return '$device aún no puede compartir sus ventanas. Actualiza Whisper a la última versión en ese dispositivo.';
  }

  @override
  String windowStreamHostUnsupportedWindows(String device) {
    return '$device necesita Windows 10 versión 1903 o posterior para compartir sus ventanas.';
  }

  @override
  String windowStreamHostUnsupportedMac(String device) {
    return '$device necesita macOS 12.3 o posterior para compartir sus ventanas.';
  }

  @override
  String get windowStreamThatDevice => 'ese dispositivo';

  @override
  String remoteFilesPlaceDrive(String name, String drive) {
    return '$name ($drive:)';
  }

  @override
  String remoteFilesPlaceLocalDisk(String drive) {
    return 'Disco local ($drive:)';
  }

  @override
  String remoteFilesPlaceRemovableDisk(String drive) {
    return 'Unidad USB ($drive:)';
  }

  @override
  String get remoteFilesPlaceAppFolder => 'Carpeta de Whisper';

  @override
  String islandTransferTo(String device) {
    return 'Para $device';
  }

  @override
  String islandTransferFrom(String device) {
    return 'De $device';
  }

  @override
  String get islandTransferMixed => 'Enviando y recibiendo';

  @override
  String islandTransferFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count archivos',
      one: '1 archivo',
    );
    return '$_temp0';
  }

  @override
  String get islandTransferSent => 'Enviado';

  @override
  String get islandTransferReceived => 'Recibido';

  @override
  String get islandTransferFailed => 'No se completó';

  @override
  String get islandTransferStop => 'Detener transferencia';

  @override
  String get islandAudioPaused => 'Reproducción en pausa';

  @override
  String get islandAudioStarting => 'Conectando…';

  @override
  String get islandAudioEnded => 'Desconectado';

  @override
  String islandStreamedTitle(String device) {
    return 'Transmitiendo a $device';
  }

  @override
  String islandStreamedWindows(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count ventanas se muestran en ese dispositivo y se pueden usar allí',
      one: '1 ventana se muestra en ese dispositivo y se puede usar allí',
    );
    return '$_temp0';
  }

  @override
  String get islandStreamedStop => 'Detener transmisión';

  @override
  String get islandStreamedStopping => 'Deteniendo…';

  @override
  String get islandStreamedEnded => 'Transmisión finalizada';

  @override
  String get islandStreamedOtherDevice => 'otro dispositivo';

  @override
  String islandMore(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count más',
      one: '1 más',
    );
    return '$_temp0';
  }

  @override
  String get islandHint =>
      'Toca para ampliar, desliza hacia arriba para ocultar';

  @override
  String get shareLinkMenuCreate => 'Crear enlace para compartir…';

  @override
  String get shareLinkCreateTitle => 'Crear enlace para compartir';

  @override
  String get shareLinkCreateDetail =>
      'Los dispositivos de la misma red pueden abrir el enlace en un navegador para descargar. No necesitan Whisper.';

  @override
  String shareLinkDefaultName(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count elementos',
      one: '1 elemento',
    );
    return '$_temp0';
  }

  @override
  String get shareLinkRoute => 'Ruta';

  @override
  String get shareLinkRouteHelp =>
      'Déjalo vacío para usar la ruta aleatoria que se muestra';

  @override
  String get shareLinkShortRoute => 'Ruta corta';

  @override
  String get shareLinkShortRouteDetail =>
      '4 caracteres, fácil de decir en voz alta';

  @override
  String get shareLinkPassword => 'Contraseña';

  @override
  String get shareLinkPasswordOptional => 'Opcional';

  @override
  String get shareLinkShowPassword => 'Mostrar contraseña';

  @override
  String get shareLinkHidePassword => 'Ocultar contraseña';

  @override
  String get shareLinkCreate => 'Crear enlace';

  @override
  String get shareLinkRouteTaken => 'Otro enlace ya usa esta ruta';

  @override
  String get shareLinkRouteInvalid =>
      'Usa de 2 a 32 caracteres: minúsculas, números, - o _';

  @override
  String get shareLinkRouteReserved =>
      'Esta ruta está reservada. Prueba con otra.';

  @override
  String get shareLinkItemsMissing =>
      'Los elementos que querías compartir ya no están';

  @override
  String get shareLinkCreateFailed => 'No se pudo crear el enlace';

  @override
  String get shareLinkReady => 'Enlace listo';

  @override
  String get shareLinkCopy => 'Copiar enlace';

  @override
  String get shareLinkCopied => 'Copiado';

  @override
  String get shareLinkScanHint => 'O escanéalo con la cámara de un teléfono';

  @override
  String get shareLinkAddressPicker => 'Elegir dirección de red';

  @override
  String get shareLinkServiceOffNote =>
      'El servidor de archivos está desactivado. Actívalo para que se pueda abrir el enlace.';

  @override
  String get shareLinkNoNetwork =>
      'Sin conexión a una red local: otros dispositivos aún no pueden abrirlo';

  @override
  String get shareLinkPasswordProtected => 'Protegido con contraseña';

  @override
  String get shareLinksTitle => 'Enlaces compartidos';

  @override
  String shareLinksActiveCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count enlaces activos',
      one: '1 enlace activo',
    );
    return '$_temp0';
  }

  @override
  String get shareLinksService => 'Servidor de archivos';

  @override
  String shareLinksServiceRunning(String port) {
    return 'En funcionamiento en el puerto $port';
  }

  @override
  String get shareLinksServiceIdle =>
      'No hay enlaces activos, así que el puerto está cerrado';

  @override
  String get shareLinksServiceOff =>
      'Desactivado. Los enlaces se conservan, pero no se pueden abrir.';

  @override
  String get shareLinksServiceStarting => 'Iniciando…';

  @override
  String shareLinksServicePortsBusy(String from, String to) {
    return 'Los puertos $from–$to están ocupados';
  }

  @override
  String get shareLinksServiceFailed => 'No se pudo iniciar';

  @override
  String get shareLinkStatusOn => 'Activado';

  @override
  String get shareLinkStatusOff => 'Desactivado';

  @override
  String get shareLinkStatusMissing => 'Faltan archivos';

  @override
  String get shareLinkStatusPartlyMissing => 'Faltan algunos archivos';

  @override
  String shareLinkVisits(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count visitas',
      one: '1 visita',
    );
    return '$_temp0';
  }

  @override
  String shareLinkDownloads(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count descargas',
      one: '1 descarga',
    );
    return '$_temp0';
  }

  @override
  String shareLinkLastVisit(String time) {
    return 'Última visita: $time';
  }

  @override
  String get shareLinkNeverVisited => 'Aún no se ha abierto';

  @override
  String shareLinkBytesServed(String size) {
    return '$size enviados';
  }

  @override
  String get shareLinkQr => 'Código QR';

  @override
  String get shareLinkTurnOn => 'Activar enlace';

  @override
  String get shareLinkTurnOff => 'Desactivar enlace';

  @override
  String get shareLinkDelete => 'Eliminar enlace';

  @override
  String get shareLinkDeleteTitle => '¿Eliminar este enlace?';

  @override
  String get shareLinkDeleteDetail =>
      'La dirección dejará de funcionar de inmediato. Los archivos de este dispositivo no se verán afectados.';

  @override
  String get shareLinksEmpty => 'No hay enlaces compartidos';

  @override
  String get shareLinksEmptyDetailDesktop =>
      'Haz clic derecho en un archivo o una carpeta de este dispositivo y elige “Crear enlace para compartir…”. Puedes seleccionar varios antes.';

  @override
  String get shareLinksEmptyDetailPhone =>
      'Mantén pulsado un archivo o una carpeta de este dispositivo y elige “Crear enlace para compartir…”, o selecciona varios y usa la barra inferior.';

  @override
  String get shareWebDownload => 'Descargar';

  @override
  String get shareWebOpen => 'Abrir en el navegador';

  @override
  String get shareWebDownloadAll => 'Descargar todo (.zip)';

  @override
  String get shareWebDownloadZip => 'Descargar como .zip';

  @override
  String shareWebItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count elementos',
      one: '1 elemento',
    );
    return '$_temp0';
  }

  @override
  String get shareWebEmptyFolder => 'Esta carpeta está vacía';

  @override
  String shareWebModified(String date) {
    return 'Modificado: $date';
  }

  @override
  String shareWebFooter(String device) {
    return 'Compartido desde $device con Whisper';
  }

  @override
  String get shareWebNotFoundTitle => 'Este enlace no está disponible';

  @override
  String get shareWebNotFoundDetail =>
      'Puede que se haya desactivado o que la dirección esté mal escrita. Consúltalo con quien lo compartió.';

  @override
  String get shareWebMissingTitle => 'Archivo no encontrado';

  @override
  String get shareWebMissingDetail =>
      'Puede que se haya movido, renombrado o eliminado.';

  @override
  String get shareWebBack => 'Volver a lo compartido';

  @override
  String get shareWebPasswordTitle => 'Se requiere contraseña';

  @override
  String get shareWebPasswordDetail =>
      'Este enlace está protegido con contraseña.';

  @override
  String get shareWebContinue => 'Continuar';

  @override
  String get shareWebPasswordWrong =>
      'Contraseña incorrecta. Inténtalo de nuevo.';

  @override
  String get shareWebTooManyTitle => 'Demasiados intentos';

  @override
  String get shareWebTooManyDetail => 'Espera un minuto y vuelve a intentarlo.';

  @override
  String get shareWebErrorTitle => 'Algo salió mal';

  @override
  String get shareWebErrorDetail => 'Inténtalo de nuevo en un momento.';

  @override
  String get windowStreamDecoderMissing =>
      'No se puede mostrar la ventana: falta el decodificador de vídeo de FFmpeg en este equipo';

  @override
  String get windowStreamVolume => 'Volumen';

  @override
  String get windowStreamMute => 'Silenciar';

  @override
  String get windowStreamUnmute => 'Activar sonido';

  @override
  String get windowStreamMovedAway =>
      'Esta ventana se abrió en otro dispositivo';

  @override
  String flowTaskOpenOn(String device) {
    return 'Se muestra en $device';
  }

  @override
  String get shareLinkBarAction => 'Compartir enlace';

  @override
  String get windowStreamSourceErrorDesktopUnsupported =>
      'Este PC no puede compartir ventanas';

  @override
  String get windowStreamSourceErrorElevated =>
      'Esta ventana se ejecuta como administrador y no se puede compartir';

  @override
  String windowStreamSourceNoteStagedInPlace(String app) {
    return '$app no puede ejecutarse en segundo plano, compartiéndola donde está';
  }

  @override
  String get gnomeHelperTitle => 'Complemento para compartir ventanas';

  @override
  String get gnomeHelperHint =>
      'Para mostrar las ventanas de este ordenador en tus otros dispositivos hace falta un pequeño componente de GNOME y cerrar sesión una vez';

  @override
  String get gnomeHelperWorking => 'Instalando…';

  @override
  String get gnomeHelperReady => 'Listo';

  @override
  String get gnomeHelperNotInstalled => 'No instalado';

  @override
  String get gnomeHelperNeedsRelogin => 'Cierra sesión para terminar';

  @override
  String get gnomeHelperOutdated => 'Necesita actualizarse';

  @override
  String get gnomeHelperDisabled => 'Desactivado';

  @override
  String get gnomeHelperExtensionsOff => 'Extensiones desactivadas';

  @override
  String get gnomeHelperInstallDesc =>
      'Whisper añade una pequeña extensión de GNOME Shell que mantiene las ventanas compartidas en segundo plano y les pasa el teclado y el ratón. Solo Whisper puede usarla. Después de instalarla, cierra sesión y vuelve a entrar una vez.';

  @override
  String get gnomeHelperUpdateDesc =>
      'Esta versión de Whisper trae un complemento más reciente. Después de actualizarlo, cierra sesión y vuelve a entrar una vez.';

  @override
  String get gnomeHelperReloginDesc =>
      'El complemento ya está instalado. GNOME lo carga cuando vuelves a iniciar sesión. Guarda tu trabajo en otras apps antes de cerrar sesión.';

  @override
  String get gnomeHelperDisabledDesc =>
      'El complemento se desactivó en Extensiones de GNOME. Vuelve a activarlo para que tus otros dispositivos puedan mostrar las ventanas de este ordenador.';

  @override
  String get gnomeHelperExtensionsOffDesc =>
      'Las extensiones de GNOME están desactivadas. El complemento solo funciona con ellas activadas (también se activarán las demás extensiones instaladas).';

  @override
  String get gnomeHelperReadyDesc =>
      'El complemento está funcionando. Tus otros dispositivos pueden mostrar las ventanas de este ordenador mientras siguen abiertas aquí en segundo plano.';

  @override
  String get gnomeHelperInstall => 'Instalar';

  @override
  String get gnomeHelperUpdate => 'Actualizar';

  @override
  String get gnomeHelperLogOut => 'Cerrar sesión…';

  @override
  String get gnomeHelperLater => 'Más tarde';

  @override
  String get gnomeHelperTurnOn => 'Activar';

  @override
  String get gnomeHelperTurnOnExtensions => 'Activar extensiones';

  @override
  String get gnomeHelperDone => 'Aceptar';

  @override
  String get gnomeHelperInstalled =>
      'Instalado. Cierra sesión y vuelve a entrar para terminar.';

  @override
  String get gnomeHelperFailed => 'No se pudo instalar el complemento';

  @override
  String get windowStreamShareSetting =>
      'Compartir las ventanas de este ordenador';

  @override
  String get windowStreamShareSettingDesc =>
      'Los dispositivos de confianza pueden abrir y usar las ventanas de este ordenador en sus pantallas';

  @override
  String get deviceFilesAlwaysAllowed =>
      'Permitir siempre explorar mis archivos';

  @override
  String get deviceMountHere => 'Montar en este equipo';

  @override
  String windowStreamCloseStillOpen(String app) {
    return '“$app” sigue abierta; puede que esté preguntando si quieres guardar.';
  }

  @override
  String get windowStreamCloseShow => 'Mostrar ventana';

  @override
  String get windowStreamClosing => 'Cerrando';

  @override
  String shareWebFrom(String device) {
    return 'Desde $device';
  }

  @override
  String get shareWebFooterLan =>
      'Los archivos llegan directamente desde este dispositivo por tu red local, sin pasar por la nube.';

  @override
  String shareWebPreviewTruncated(String size) {
    return 'Se muestran los primeros $size. Descarga el archivo para verlo completo.';
  }

  @override
  String get shareWebPrevious => 'Anterior';

  @override
  String get shareWebNext => 'Siguiente';

  @override
  String get shareLinkAllowAccess => 'Permitir acceso';

  @override
  String get shareLinkAddress => 'Dirección';

  @override
  String get shareLinksServiceFooter =>
      'Los dispositivos de la misma red pueden abrir un enlace en cualquier navegador. El servidor solo funciona mientras haya un enlace activo.';

  @override
  String get shareLinkVisitsLabel => 'Visitas';

  @override
  String get shareLinkDownloadsLabel => 'Descargas';

  @override
  String get shareLinkLastVisitLabel => 'Última visita';

  @override
  String get shareLinkSentLabel => 'Datos enviados';

  @override
  String get shareLinkNever => 'Nunca';

  @override
  String get androidWindowServiceTitle => 'Servicio de flujo de ventanas';

  @override
  String get androidWindowServiceRunning => 'Activado';

  @override
  String get androidWindowServiceRunningHint =>
      'Tus ordenadores de confianza ya pueden ver este teléfono en su flujo de ventanas y abrir sus apps';

  @override
  String get androidWindowServiceStopped => 'No está en marcha';

  @override
  String get androidWindowServiceStoppedHint =>
      'Activa la depuración inalámbrica y vuelve a iniciarlo aquí sin ordenador';

  @override
  String get androidWindowServiceNeedsSetup => 'Sin configurar';

  @override
  String get androidWindowServiceNeedsSetupHint =>
      'Una vez activado, las apps de este teléfono pueden fluir a tus ordenadores de confianza para verlas y controlarlas, mientras el teléfono permanece en segundo plano';

  @override
  String get androidWindowServiceStart => 'Activar';

  @override
  String get androidWindowServiceStop => 'Desactivar';

  @override
  String get androidWindowServiceSetup => 'Configurar';

  @override
  String get androidWindowServiceHowTitle => 'Configuración única';

  @override
  String get androidWindowServiceStep1 =>
      'Activa las opciones de desarrollador';

  @override
  String get androidWindowServiceStep1Hint =>
      'Toca Número de compilación 7 veces en Acerca del teléfono';

  @override
  String get androidWindowServiceStep1Action => 'Abrir Acerca del teléfono';

  @override
  String get androidWindowServiceStep2 => 'Activa la depuración inalámbrica';

  @override
  String get androidWindowServiceStep2Hint =>
      'En Opciones de desarrollador, activa la depuración inalámbrica y abre ‘Vincular dispositivo con código’';

  @override
  String get androidWindowServiceStep2Action =>
      'Abrir Opciones de desarrollador';

  @override
  String get androidWindowServiceStep3 => 'Introduce el código de vinculación';

  @override
  String get androidWindowServiceStep3Hint =>
      'Escribe el código de 6 dígitos que muestra el sistema; Whisper se vincula con este teléfono e inicia el servicio';

  @override
  String get androidWindowServicePairingCode => 'Código de vinculación';

  @override
  String get androidWindowServicePair => 'Vincular y activar';

  @override
  String get androidWindowServicePairing => 'Vinculando…';

  @override
  String get androidWindowServiceStarting => 'Iniciando…';

  @override
  String get androidWindowServiceAutoStart =>
      'Iniciar automáticamente tras reiniciar';

  @override
  String get androidWindowServiceAutoStartHint =>
      'Necesita un permiso del sistema para que Whisper reactive la depuración inalámbrica; solo tus ordenadores de confianza pueden conectarse y puedes desactivarlo aquí cuando quieras';

  @override
  String get androidWindowServiceStarted =>
      'El servicio de flujo de ventanas está activado';

  @override
  String get androidWindowServiceStopped2 =>
      'El servicio de flujo de ventanas se detuvo';

  @override
  String get androidWindowServiceStartFailed =>
      'No se pudo iniciar. Comprueba que la depuración inalámbrica esté activada e inténtalo de nuevo';

  @override
  String get androidWindowServicePairFailed =>
      'La vinculación falló. Comprueba el código e inténtalo de nuevo';

  @override
  String get androidWindowServiceEntryTitle => 'Servicio de flujo de ventanas';

  @override
  String get androidWindowServiceEntryHint =>
      'Permite que otros dispositivos abran las apps de este teléfono';

  @override
  String get androidWindowServiceComputerHint =>
      'Conecta este teléfono una vez a un ordenador con Whisper y el flujo de ventanas activado; después todos los ordenadores podrán usarlo';

  @override
  String windowStreamPhoneServiceOff(String device) {
    return 'Abre Whisper en $device y activa Ajustes → Servicio de flujo de ventanas.';
  }

  @override
  String remoteFilesNoAnswer(String device) {
    return '$device no respondió';
  }

  @override
  String get remoteFilesNoAnswerDetail =>
      'La pregunta en ese dispositivo caducó. Asegúrate de que haya alguien allí e inténtalo de nuevo.';

  @override
  String remoteFilesNotAsked(String device) {
    return '$device debe permitir explorar sus archivos';
  }
}
