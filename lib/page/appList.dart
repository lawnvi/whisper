import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:installed_apps/app_info.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:whisper/helper/local.dart';

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

  void loadApps() async {
    setState(() {
      isLoading = true;
    });
    List<AppInfo> installedApps = await InstalledApps.getInstalledApps(
      excludeSystemApps: true,
      withIcon: true,
    );
    Map<String, int> appMap = await LocalSetting().listenAppNotifyList();
    installedApps.sort(
        (a, b) => (appMap[b.packageName] ?? 0) - (appMap[a.packageName] ?? 0));

    var checked = <String, bool>{};
    for (var item in appMap.keys) {
      checked[item] = true;
    }

    setState(() {
      apps = installedApps;
      filteredApps = installedApps;
      isLoading = false;
      checkedApps = checked;
    });
  }

  void filterApps(String query) async {
    List<AppInfo> filtered = apps.where((app) {
      return app.name.toLowerCase().contains(query.toLowerCase());
    }).toList();
    setState(() {
      filteredApps = filtered;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return CupertinoPageScaffold(
      // backgroundColor: isDark?Colors.black87:Colors.white,
      navigationBar: CupertinoNavigationBar(
        middle: Text(AppLocalizations.of(context)?.selectNotifyApp ?? '监听APP通知', style: TextStyle(color: isDark?Colors.grey:Colors.black87)),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          child: Text(AppLocalizations.of(context)?.back ?? 'Back', style: TextStyle(color: isDark?Colors.grey:Colors.black87)),
          onPressed: () {
            // Handle back button press
            Navigator.pop(context);
          },
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          child: Text(AppLocalizations.of(context)?.selectAll ?? '全选', style: TextStyle(color: isDark?Colors.grey:Colors.black87)),
          onPressed: () {
            bool selectAll = checkedApps.length < apps.length ||
                checkedApps.values.contains(false);

            var appArr = [];
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
              child: isLoading
                  ? const Center(
                      child: CupertinoActivityIndicator(),
                    )
                  : ListView.builder(
                      itemCount: filteredApps.length,
                      itemBuilder: (context, index) {
                        AppInfo app = filteredApps[index];
                        bool isChecked = checkedApps[app.packageName] ?? false;
                        return AppListTile(
                          app: app,
                          isChecked: isChecked,
                          isDark: isDark,
                          onChanged: (bool value) {
                            LocalSetting().modifyListenNotifyApp(
                                packages: [app.packageName], add: value);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppListTile extends StatelessWidget {
  final AppInfo app;
  final ValueNotifier<bool> isCheckedNotifier;
  final ValueChanged<bool> onChanged;
  final bool isDark;

  AppListTile({
    super.key,
    required this.app,
    required bool isChecked,
    required this.isDark,
    required this.onChanged,
  }) : isCheckedNotifier = ValueNotifier<bool>(isChecked);

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
                Text(app.name, style: TextStyle(fontSize: 14, color: isDark?Colors.white70: Colors.black87, decoration: TextDecoration.none)),
                const SizedBox(height: 4),
                Text(app.versionName,
                  style: const TextStyle(fontSize: 12, color: CupertinoColors.systemGrey, decoration: TextDecoration.none),
                ),
              ],
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: isCheckedNotifier,
            builder: (context, isChecked, child) {
              return CupertinoSwitch(
                value: isChecked,
                onChanged: (bool value) {
                  isCheckedNotifier.value = value;
                  onChanged(value);
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class AppIcon extends StatelessWidget {
  final Uint8List icon;

  const AppIcon({super.key, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Image.memory(icon, width: 40, height: 40);
  }
}
