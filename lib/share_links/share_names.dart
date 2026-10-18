import '../l10n/app_localizations.dart';
import 'share_link.dart';

/// What a link is called: the name it was given, its one item's name, or
/// "3 items" in the reader's language for several unnamed items.
String shareLinkTitle(AppLocalizations text, ShareLink link) =>
    link.name.isNotEmpty
    ? link.name
    : link.items.length == 1
    ? link.items.first.name
    : text.shareLinkDefaultName(link.items.length);
