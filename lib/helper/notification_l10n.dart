import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/l10n/app_localizations_en.dart';

AppLocalizations resolveNotificationL10n({
  List<Locale>? localesOverride,
}) {
  try {
    final locale = basicLocaleListResolution(
      localesOverride ?? PlatformDispatcher.instance.locales,
      AppLocalizations.supportedLocales,
    );
    return lookupAppLocalizations(locale);
  } catch (_) {
    return AppLocalizationsEn();
  }
}
