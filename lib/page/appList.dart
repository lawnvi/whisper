import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:installed_apps/app_info.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_empty_state.dart';
import 'package:whisper/widget/app_interactive_tile.dart';

typedef AppListLoader = Future<AppListPresentation> Function();

typedef AppSelectionWriter = Future<void> Function({
  required List<String> packages,
  required bool add,
  bool clear,
});

@immutable
class AppListPresentation {
  const AppListPresentation({
    required this.apps,
    required this.selectedPackages,
  });

  final List<AppInfo> apps;
  final Set<String> selectedPackages;
}

class AppListScreen extends StatefulWidget {
  const AppListScreen({
    super.key,
    this.loader,
    this.selectionWriter,
  });

  final AppListLoader? loader;
  final AppSelectionWriter? selectionWriter;

  @override
  State<AppListScreen> createState() => _AppListScreenState();
}

class _AppListScreenState extends State<AppListScreen> {
  final TextEditingController searchController = TextEditingController();

  List<AppInfo> apps = <AppInfo>[];
  List<AppInfo> filteredApps = <AppInfo>[];
  Map<String, bool> checkedApps = <String, bool>{};
  bool isLoading = true;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    loadApps();
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  Future<List<AppInfo>> _loadVisibleApps() async {
    final results = await Future.wait<List<AppInfo>>(<Future<List<AppInfo>>>[
      InstalledApps.getInstalledApps(
        excludeSystemApps: true,
        withIcon: true,
      ),
      InstalledApps.getInstalledApps(
        excludeSystemApps: false,
        withIcon: false,
      ),
    ]);
    final userApps = results[0];
    final allAppsWithoutIcons = results[1];
    final installedAppsByPackage = <String, AppInfo>{
      for (final app in userApps) app.packageName: app,
    };
    final allAppsByPackage = <String, AppInfo>{
      for (final app in allAppsWithoutIcons) app.packageName: app,
    };
    final systemSmsPackages = allAppsWithoutIcons
        .where(
          (app) =>
              app.isSystemApp &&
              isVerificationCodeNotificationPackage(app.packageName) &&
              !installedAppsByPackage.containsKey(app.packageName),
        )
        .map((app) => app.packageName)
        .toSet();
    final systemSmsApps = await Future.wait<AppInfo?>(
      systemSmsPackages.map((packageName) async {
        final app = await InstalledApps.getAppInfo(packageName);
        return app ?? allAppsByPackage[packageName];
      }),
    );
    for (final app in systemSmsApps) {
      if (app != null) {
        installedAppsByPackage[app.packageName] = app;
      }
    }
    return installedAppsByPackage.values.toList(growable: false);
  }

  Future<AppListPresentation> _loadDefaultPresentation() async {
    final results = await Future.wait<dynamic>(<Future<dynamic>>[
      _loadVisibleApps(),
      LocalSetting().listenAppNotifyList(),
    ]);
    final installedApps = results[0] as List<AppInfo>;
    final appMap = results[1] as Map<String, int>;
    installedApps.sort(
      (a, b) => (appMap[b.packageName] ?? 0) - (appMap[a.packageName] ?? 0),
    );
    return AppListPresentation(
      apps: List<AppInfo>.unmodifiable(installedApps),
      selectedPackages: Set<String>.unmodifiable(appMap.keys),
    );
  }

  List<AppInfo> _filterApps(List<AppInfo> source, String query) {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) {
      return source;
    }
    return source.where((app) {
      return app.name.toLowerCase().contains(normalizedQuery) ||
          app.packageName.toLowerCase().contains(normalizedQuery);
    }).toList(growable: false);
  }

  Future<void> loadApps() async {
    setState(() {
      isLoading = true;
      _loadFailed = false;
    });
    try {
      final presentation =
          await (widget.loader ?? _loadDefaultPresentation).call();
      if (!mounted) {
        return;
      }
      setState(() {
        apps = List<AppInfo>.of(presentation.apps);
        filteredApps = _filterApps(apps, searchController.text);
        checkedApps = <String, bool>{
          for (final package in presentation.selectedPackages) package: true,
        };
        isLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        isLoading = false;
        _loadFailed = true;
      });
    }
  }

  void filterApps(String query) {
    setState(() {
      filteredApps = _filterApps(apps, query);
    });
  }

  void _clearSearch() {
    searchController.clear();
    filterApps('');
  }

  Future<void> _writeSelection({
    required List<String> packages,
    required bool add,
    bool clear = false,
  }) async {
    final writer = widget.selectionWriter;
    if (writer != null) {
      await writer(packages: packages, add: add, clear: clear);
      return;
    }
    await LocalSetting().modifyListenNotifyApp(
      packages: packages,
      add: add,
      clear: clear,
    );
  }

  Future<void> _updateAppChecked(String packageName, bool value) async {
    setState(() {
      checkedApps[packageName] = value;
    });
    await _writeSelection(packages: <String>[packageName], add: value);
  }

  Future<void> _toggleAll() async {
    final selectAll = apps.any((app) => checkedApps[app.packageName] != true);
    final packages = apps.map((app) => app.packageName).toList(growable: false);
    setState(() {
      checkedApps = <String, bool>{
        for (final package in packages) package: selectAll,
      };
    });
    await _writeSelection(
      add: selectAll,
      clear: !selectAll,
      packages: packages,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final palette = context.whisperPalette;
    final l10n = AppLocalizations.of(context)!;
    final allSelected = apps.isNotEmpty &&
        apps.every((app) => checkedApps[app.packageName] == true);

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        foregroundColor: colorScheme.onSurface,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: palette.borderSubtle),
        ),
        leading: const BackButton(),
        title: Text(
          l10n.selectNotifyApp,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[
          IconButton(
            tooltip: allSelected ? l10n.deselectAll : l10n.selectAll,
            onPressed: isLoading || apps.isEmpty ? null : _toggleAll,
            icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
          ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: WhisperUi.settingsMaxWidth,
            ),
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: TextField(
                    controller: searchController,
                    onChanged: filterApps,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: l10n.appListSearchPlaceholder,
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: searchController.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: l10n.appListClearSearch,
                              onPressed: _clearSearch,
                              icon: const Icon(Icons.clear),
                            ),
                    ),
                  ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: _buildBody(l10n),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    if (isLoading) {
      return const Center(
        key: ValueKey<String>('loading-app-list'),
        child: CupertinoActivityIndicator(radius: 14),
      );
    }
    if (_loadFailed) {
      return AppEmptyState(
        key: const ValueKey<String>('failed-app-list'),
        icon: Icons.error_outline,
        title: l10n.appListLoadFailedTitle,
        body: l10n.appListLoadFailedBody,
        actionLabel: l10n.retry,
        onAction: loadApps,
      );
    }
    if (apps.isEmpty) {
      return AppEmptyState(
        key: const ValueKey<String>('empty-app-list'),
        icon: Icons.apps_outlined,
        title: l10n.emptyAppsTitle,
        body: l10n.emptyAppsBody,
      );
    }
    if (filteredApps.isEmpty) {
      return AppEmptyState(
        key: const ValueKey<String>('empty-app-search'),
        icon: Icons.search_off,
        title: l10n.emptyAppsSearchTitle,
        body: l10n.emptyAppsSearchBody,
        actionLabel: l10n.appListClearSearch,
        onAction: _clearSearch,
      );
    }
    return ListView.builder(
      key: const ValueKey<String>('loaded-app-list'),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
      itemCount: filteredApps.length,
      itemBuilder: (context, index) {
        final app = filteredApps[index];
        final isChecked = checkedApps[app.packageName] ?? false;
        return AppListTile(
          app: app,
          isChecked: isChecked,
          onChanged: (value) => _updateAppChecked(app.packageName, value),
        );
      },
    );
  }
}

class AppListTile extends StatelessWidget {
  const AppListTile({
    super.key,
    required this.app,
    required this.isChecked,
    required this.onChanged,
  });

  final AppInfo app;
  final bool isChecked;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: AppInteractiveTile(
        semanticLabel: '${app.name}, ${app.packageName}',
        toggled: isChecked,
        onActivate: () => onChanged(!isChecked),
        leading: app.icon == null
            ? const SizedBox(
                width: 40,
                height: 40,
                child: Icon(Icons.apps_outlined),
              )
            : AppIcon(icon: app.icon!),
        title: Text(app.name),
        subtitle: Text(_appSubtitle(app)),
        trailing: ExcludeFocus(
          child: ExcludeSemantics(
            child: CupertinoSwitch(
              value: isChecked,
              onChanged: onChanged,
            ),
          ),
        ),
      ),
    );
  }
}

String _appSubtitle(AppInfo app) {
  return app.packageName;
}

class AppIcon extends StatelessWidget {
  const AppIcon({super.key, required this.icon});

  final Uint8List icon;

  @override
  Widget build(BuildContext context) {
    return Image.memory(
      icon,
      width: 40,
      height: 40,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => const SizedBox(
        width: 40,
        height: 40,
        child: Icon(Icons.apps_outlined),
      ),
    );
  }
}
