import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:installed_apps/app_info.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/theme/app_theme.dart';

import '../l10n/app_localizations.dart';

class AppListScreen extends StatefulWidget {
  const AppListScreen({super.key});

  @override
  _AppListScreenState createState() => _AppListScreenState();
}

class _AppListScreenState extends State<AppListScreen> {
  List<AppInfo> apps = [];
  List<AppInfo> filteredApps = [];
  TextEditingController searchController = TextEditingController();
  Map<String, bool> checkedApps = {};
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    loadApps();
  }

  Future<List<AppInfo>> _loadVisibleApps() async {
    final results = await Future.wait<List<AppInfo>>([
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
        .where((app) =>
            app.isSystemApp &&
            isVerificationCodeNotificationPackage(app.packageName) &&
            !installedAppsByPackage.containsKey(app.packageName))
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
    return installedAppsByPackage.values.toList();
  }

  List<AppInfo> _filterApps(List<AppInfo> source, String query) {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) {
      return source;
    }
    return source.where((app) {
      return app.name.toLowerCase().contains(normalizedQuery) ||
          app.packageName.toLowerCase().contains(normalizedQuery);
    }).toList();
  }

  void loadApps() async {
    setState(() {
      isLoading = true;
    });
    final results = await Future.wait<dynamic>([
      _loadVisibleApps(),
      LocalSetting().listenAppNotifyList(),
    ]);
    if (!mounted) {
      return;
    }
    final installedApps = results[0] as List<AppInfo>;
    final appMap = results[1] as Map<String, int>;
    installedApps.sort(
        (a, b) => (appMap[b.packageName] ?? 0) - (appMap[a.packageName] ?? 0));

    var checked = <String, bool>{};
    for (var item in appMap.keys) {
      checked[item] = true;
    }

    setState(() {
      apps = installedApps;
      filteredApps = _filterApps(installedApps, searchController.text);
      isLoading = false;
      checkedApps = checked;
    });
  }

  void filterApps(String query) async {
    setState(() {
      filteredApps = _filterApps(apps, query);
    });
  }

  void _updateAppChecked(String packageName, bool value) {
    setState(() {
      checkedApps[packageName] = value;
    });
    LocalSetting().modifyListenNotifyApp(packages: [packageName], add: value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;
    final palette = context.whisperPalette;
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
        middle: Text(AppLocalizations.of(context)?.selectNotifyApp ?? '监听APP通知',
            style: TextStyle(color: navigationTextColor)),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          child: Text(AppLocalizations.of(context)?.back ?? 'Back',
              style: TextStyle(color: navigationTextColor)),
          onPressed: () {
            // Handle back button press
            Navigator.pop(context);
          },
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          child: Text(AppLocalizations.of(context)?.selectAll ?? '全选',
              style: TextStyle(color: navigationTextColor)),
          onPressed: () {
            bool selectAll = checkedApps.length < apps.length ||
                checkedApps.values.contains(false);

            var appArr = <String>[];
            var checkedMap = <String, bool>{};
            for (var app in apps) {
              appArr.add(app.packageName);
              checkedMap[app.packageName] = selectAll;
            }
            setState(() {
              checkedApps = checkedMap;
            });

            LocalSetting().modifyListenNotifyApp(
                add: selectAll, clear: !selectAll, packages: appArr);
          },
        ),
      ),
      child: ColoredBox(
        color: colorScheme.surface,
        child: SafeArea(
          child: Column(
            children: [
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
                  child: isLoading
                      ? const Center(
                          key: ValueKey('loading-app-list'),
                          child: CupertinoActivityIndicator(radius: 14),
                        )
                      : ListView.builder(
                          key: const ValueKey('loaded-app-list'),
                          itemCount: filteredApps.length,
                          itemBuilder: (context, index) {
                            AppInfo app = filteredApps[index];
                            bool isChecked =
                                checkedApps[app.packageName] ?? false;
                            return AppListTile(
                              app: app,
                              isChecked: isChecked,
                              isDark: isDark,
                              onChanged: (bool value) {
                                _updateAppChecked(app.packageName, value);
                              },
                            );
                          },
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

class AppListTile extends StatelessWidget {
  final AppInfo app;
  final bool isChecked;
  final ValueChanged<bool> onChanged;
  final bool isDark;

  const AppListTile({
    super.key,
    required this.app,
    required this.isChecked,
    required this.isDark,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    AppInfo app = this.app;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
      child: Row(
        children: [
          if (app.icon != null) AppIcon(icon: app.icon!),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(app.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        color: isDark ? Colors.white70 : Colors.black87,
                        decoration: TextDecoration.none)),
                const SizedBox(height: 4),
                Text(
                  _appSubtitle(app),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.systemGrey,
                      decoration: TextDecoration.none),
                ),
              ],
            ),
          ),
          CupertinoSwitch(
            value: isChecked,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

String _appSubtitle(AppInfo app) {
  return app.packageName;
}

class AppIcon extends StatelessWidget {
  final Uint8List icon;

  const AppIcon({super.key, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Image.memory(icon, width: 40, height: 40);
  }
}
