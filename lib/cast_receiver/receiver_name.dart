String castReceiverName({
  required String savedName,
  required String systemName,
  required String deviceId,
  required bool explicitlyNamed,
}) {
  // Older installs saved the generic Mac name as though it were a nickname.
  const oldDefaults = {
    'Mac',
    'MacBook',
    'MacBook Air',
    'MacBook Pro',
    'iMac',
    'iMac Pro',
    'Mac mini',
    'Mac Studio',
    'Mac Pro',
    'macOS',
    'Linux',
    'unknown',
  };
  final saved = savedName.trim();
  final system = systemName.trim();
  final name =
      saved.isEmpty || (!explicitlyNamed && oldDefaults.contains(saved))
      ? (system.isEmpty ? 'Whisper' : system)
      : saved;
  // The receiver name is shown directly in phone video apps.  Keep it
  // human-readable; the device id remains the stable UPnP identity.
  return name;
}
