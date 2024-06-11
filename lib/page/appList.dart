import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:device_apps/device_apps.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:whisper/helper/local.dart';

class AppListScreen extends StatefulWidget {
  const AppListScreen({super.key});

  @override
  _AppListScreenState createState() => _AppListScreenState();
}

class _AppListScreenState extends State<AppListScreen> {
  List<Application> apps = [];
  List<Application> filteredApps = [];
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
    List<Application> installedApps = await DeviceApps.getInstalledApplications(
        includeSystemApps: true,
        includeAppIcons: true,
        onlyAppsWithLaunchIntent: true);
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

  void filterApps(String query) {
    List<Application> filtered = apps.where((app) {
      return app.appName.toLowerCase().contains(query.toLowerCase());
    }).toList();
    setState(() {
      filteredApps = filtered;
    });
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(AppLocalizations.of(context)?.selectNotifyApp ?? '通知APP'),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          child: Text(AppLocalizations.of(context)?.back ?? 'Back'),
          onPressed: () {
            // Handle back button press
            Navigator.pop(context);
          },
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          child: Text(AppLocalizations.of(context)?.selectAll ?? '全选'),
          onPressed: () {

            print(">>>>>>>>>>>>>>>>>$checkedApps");

            bool selectAll = checkedApps.length < apps.length || checkedApps.values.contains(false);

            var appArr = [];
            var checkedMap = <String, bool>{};
            for (var app in apps) {
              appArr.add(app.packageName);
              checkedMap[app.packageName] = selectAll;
            }
            setState(() {
              checkedApps = checkedMap;
            });

            LocalSetting().modifyListenNotifyApp(add: selectAll, clear: !selectAll, packages: appArr);
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
                        Application app = filteredApps[index];
                        bool isChecked = checkedApps[app.packageName] ?? false;
                        return AppListTile(
                          app: app,
                          isChecked: isChecked,
                          onChanged: (bool value) {
                            LocalSetting().modifyListenNotifyApp(packages: [app.packageName], add: value);
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
  final Application app;
  final ValueNotifier<bool> isCheckedNotifier;
  final ValueChanged<bool> onChanged;

  AppListTile({
    super.key,
    required this.app,
    required bool isChecked,
    required this.onChanged,
  }) : isCheckedNotifier = ValueNotifier<bool>(isChecked);

  @override
  Widget build(BuildContext context) {
    Application app = this.app;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
      child: Row(
        children: [
          if (app is ApplicationWithIcon) AppIcon(icon: app.icon),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(app.appName),
                Text(
                  'version: ${app.versionName}',
                  style: const TextStyle(
                      fontSize: 12, color: CupertinoColors.systemGrey),
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
