import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:installed_apps/app_info.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:whisper/helper/android_privacy_permission.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/theme/app_theme.dart';

typedef AppListLoader = Future<AppListPresentation> Function();
typedef AppListPermissionRequester = Future<bool> Function();

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
    this.permissionRequester,
  });

  final AppListLoader? loader;
  final AppSelectionWriter? selectionWriter;
  final AppListPermissionRequester? permissionRequester;

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
  bool _isSaving = false;

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
      final hasPermission = await (widget.permissionRequester ??
              AndroidPrivacyPermission.requestInstalledApps)
          .call();
      if (!hasPermission) {
        throw StateError('Installed apps permission was not granted');
      }
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

  Future<void> _commitSelection({
    required Map<String, bool> nextSelection,
    required List<String> packages,
    required bool add,
    bool clear = false,
  }) async {
    if (_isSaving) {
      return;
    }
    final previousSelection = Map<String, bool>.of(checkedApps);
    setState(() {
      checkedApps = nextSelection;
      _isSaving = true;
    });
    try {
      await _writeSelection(packages: packages, add: add, clear: clear);
      if (!mounted) {
        return;
      }
      setState(() {
        _isSaving = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        checkedApps = previousSelection;
        _isSaving = false;
      });
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(l10n.appListSaveFailed)),
        );
    }
  }

  Future<void> _updateAppChecked(String packageName, bool value) async {
    final nextSelection = Map<String, bool>.of(checkedApps)
      ..[packageName] = value;
    await _commitSelection(
      nextSelection: nextSelection,
      packages: <String>[packageName],
      add: value,
    );
  }

  Future<void> _toggleAll() async {
    final selectAll = apps.any((app) => checkedApps[app.packageName] != true);
    final packages = apps.map((app) => app.packageName).toList(growable: false);
    final nextSelection = selectAll
        ? (Map<String, bool>.of(checkedApps)
          ..addEntries(packages.map((package) => MapEntry(package, true))))
        : <String, bool>{};
    await _commitSelection(
      nextSelection: nextSelection,
      add: selectAll,
      clear: !selectAll,
      packages: packages,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;
    final palette = context.whisperPalette;
    final l10n = AppLocalizations.of(context)!;
    final navigationTextColor =
        isDark ? palette.textMuted : colorScheme.onSurface;

    return CupertinoPageScaffold(
      backgroundColor: colorScheme.surface,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: colorScheme.surface,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        border: Border(
          bottom: BorderSide(color: palette.borderSubtle),
        ),
        middle: Text(
          l10n.selectNotifyApp,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: navigationTextColor),
        ),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.pop(context),
          child: Text(
            l10n.back,
            style: TextStyle(color: navigationTextColor),
          ),
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: isLoading || apps.isEmpty || _isSaving ? null : _toggleAll,
          child: Text(
            l10n.selectAll,
            style: TextStyle(
              color: isLoading || apps.isEmpty || _isSaving
                  ? palette.textMuted
                  : navigationTextColor,
            ),
          ),
        ),
      ),
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        body: SafeArea(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 2),
                child: CupertinoSearchTextField(
                  controller: searchController,
                  onChanged: filterApps,
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
      return _buildStatus(
        key: const ValueKey<String>('failed-app-list'),
        title: l10n.appListLoadFailedTitle,
        actionLabel: l10n.retry,
        onPressed: loadApps,
      );
    }
    if (apps.isEmpty) {
      return _buildStatus(
        key: const ValueKey<String>('empty-app-list'),
        title: l10n.emptyAppsTitle,
      );
    }
    if (filteredApps.isEmpty) {
      return _buildStatus(
        key: const ValueKey<String>('empty-app-search'),
        title: l10n.emptyAppsSearchTitle,
        actionLabel: l10n.appListClearSearch,
        onPressed: _clearSearch,
      );
    }
    return ListView.builder(
      key: const ValueKey<String>('loaded-app-list'),
      itemCount: filteredApps.length,
      itemBuilder: (context, index) {
        final app = filteredApps[index];
        final isChecked = checkedApps[app.packageName] ?? false;
        return AppListTile(
          app: app,
          isChecked: isChecked,
          enabled: !_isSaving,
          onChanged: (value) => _updateAppChecked(app.packageName, value),
        );
      },
    );
  }

  Widget _buildStatus({
    required Key key,
    required String title,
    String? actionLabel,
    VoidCallback? onPressed,
  }) {
    return Center(
      key: key,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(title),
          if (actionLabel != null && onPressed != null)
            CupertinoButton(onPressed: onPressed, child: Text(actionLabel)),
        ],
      ),
    );
  }
}

class AppListTile extends StatelessWidget {
  const AppListTile({
    super.key,
    required this.app,
    required this.isChecked,
    this.enabled = true,
    required this.onChanged,
  });

  final AppInfo app;
  final bool isChecked;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      container: true,
      enabled: enabled,
      toggled: isChecked,
      label: '${app.name}, ${app.packageName}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onChanged(!isChecked) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: Row(
            children: <Widget>[
              if (app.icon != null) AppIcon(icon: app.icon!),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      app.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark ? Colors.white70 : Colors.black87,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _appSubtitle(app),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: CupertinoColors.systemGrey,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
              ExcludeFocus(
                child: ExcludeSemantics(
                  child: CupertinoSwitch(
                    value: isChecked,
                    onChanged: enabled ? onChanged : null,
                  ),
                ),
              ),
            ],
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
    return Image.memory(icon, width: 40, height: 40);
  }
}
