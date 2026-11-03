part of '../../page/settings.dart';

/// docs/design/surfaces.md「设置」: the same state and handlers as the old page,
/// laid out as the panel or the phone's page. What a row does lives in
/// _SettingsScreenState; here is only which rows there are, and where.
extension _RedesignedSettings on _SettingsScreenState {
  static const _panelWidth = 780.0, _panelHeight = 560.0;
  static const _navWidth = 224.0;

  bool get _isPage => widget.layout == SettingsLayout.page;

  ShareLinkStore get _shareLinks => widget.shareLinks ?? ShareLinkStore.shared;

  DesktopScreenshotController get _screenshot =>
      widget.screenshotController ?? DesktopScreenshotController.shared;

  void _say(String message) {
    final show = widget.showMessage;
    if (show != null) {
      show(message);
    } else {
      showAppToast(message, tone: AppToastTone.warning);
    }
  }

  Widget _buildRedesigned(BuildContext context) => SettingsScope(
    touch: _isPage || _isMobilePlatform,
    page: _isPage,
    child: _isPage ? _buildPage(context) : _buildPanel(context),
  );

  // ---------------------------------------------------------------- panel

  Widget _buildPanel(BuildContext context) {
    final c = context.wc;
    final l10n = AppLocalizations.of(context)!;
    final window = MediaQuery.sizeOf(context);
    final sections = _panelSections(l10n);
    final index = _panelSection.clamp(0, sections.length - 1);
    final section = sections[index];
    final type = WhisperType(touch: _isMobilePlatform);
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(WhisperRadius.l),
    );
    final titleStyle = TextStyle(
      fontSize: type.title,
      height: 1.4,
      fontWeight: FontWeight.w600,
      color: c.ink,
    );
    final nav = WhisperGlass(
      kind: GlassKind.sidebar,
      blur: false,
      shape: const RoundedRectangleBorder(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 24, 12, 16),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
            child: Text(l10n.setting, style: titleStyle),
          ),
          for (final (i, item) in sections.indexed)
            SettingsNavItem(
              title: item.title,
              glyph: item.glyph,
              color: item.color,
              selected: i == index,
              onTap: () => _update(() => _panelSection = i),
            ),
        ],
      ),
    );
    final body = _isLoading || _loadFailed
        ? _loadState(l10n)
        : ListView(
            key: PageStorageKey(section.title),
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 28),
            children: [
              Text(section.title, style: titleStyle),
              const SizedBox(height: 16),
              SettingsGroup(children: section.rows),
            ],
          );
    return Center(
      child: SizedBox(
        width: math.min(_panelWidth, window.width - 32),
        height: math.min(_panelHeight, window.height - WhisperWindow.sheetGap),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: c.canvas,
            shape: shape,
            shadows: WhisperShadow.e3(Theme.of(context).brightness),
          ),
          child: ClipPath(
            clipper: ShapeBorderClipper(shape: shape),
            child: Material(
              type: MaterialType.transparency,
              child: SettingsTextStyle(
                child: Stack(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: _navWidth,
                          // Inside its width: the content starts at exactly 224.
                          child: DecoratedBox(
                            position: DecorationPosition.foreground,
                            decoration: BoxDecoration(
                              border: Border(
                                right: BorderSide(
                                  color: c.sep,
                                  width:
                                      1 /
                                      MediaQuery.devicePixelRatioOf(context),
                                ),
                              ),
                            ),
                            child: nav,
                          ),
                        ),
                        Expanded(
                          // Not a page turn: no direction, up from just below.
                          child: SpringBuilder(
                            key: ValueKey(_isLoading ? -1 : index),
                            from: 0,
                            value: 1,
                            animateWhenReduced: true,
                            child: body,
                            builder: (context, t, child) => Opacity(
                              opacity: t.clamp(0.0, 1.0),
                              child: Transform.translate(
                                offset: MediaQuery.disableAnimationsOf(context)
                                    ? Offset.zero
                                    : Offset(0, 5 * (1 - t)),
                                child: child,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    // On the title's line, at the right edge of the groups.
                    Positioned(
                      top: 26,
                      right: 21,
                      child: SettingsCloseButton(
                        label: l10n.close,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Nothing while loading, which is over within a few frames. A way out if it
  /// fails.
  Widget _loadState(AppLocalizations l10n) {
    if (!_loadFailed) return const SizedBox.expand();
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.settingsLoadFailedTitle,
            style: TextStyle(
              fontSize: WhisperType(touch: _isPage).body,
              color: context.wc.ink,
            ),
          ),
          const SizedBox(height: 12),
          SettingsButton(
            label: l10n.retry,
            onTap: () => unawaited(_refreshDevice(showLoading: true)),
          ),
        ],
      ),
    );
  }

  List<_PanelSection> _panelSections(AppLocalizations l10n) {
    final c = context.wc;
    final desktop = _isDesktopPlatform;
    final android = _isAndroidPlatform;
    return [
      _PanelSection(
        title: l10n.shellSettingsGeneral,
        glyph: null,
        color: WhisperSettingsIcons.general,
        rows: [
          _nicknameRow(l10n),
          _appearanceRow(l10n),
          _languageRow(l10n),
          _saveToRow(l10n),
        ],
      ),
      _PanelSection(
        title: l10n.shellSettingsConnection,
        glyph: WhisperGlyph.globe,
        color: c.accent,
        rows: [
          _portRow(l10n),
          _autoConnectRow(l10n),
          if (desktop) _castRow(l10n),
          if (android) ..._androidConnectionRows(l10n),
        ],
      ),
      if (desktop)
        _PanelSection(
          title: l10n.shellSettingsSystem,
          glyph: WhisperGlyph.gear,
          color: WhisperSettingsIcons.system,
          rows: [
            SettingsSwitchRow(
              title: l10n.launchAtStartup,
              value: _launchAtStartup,
              onChanged: _setLaunchAtStartup,
            ),
            SettingsSwitchRow(
              title: l10n.close2tray,
              value: _close2tray,
              onChanged: _setClose2Tray,
            ),
            ..._screenshotRows(l10n),
            if (_windowsInputService.supported) _windowsServiceRow(l10n),
            GnomeHelperTile(
              controller: widget.gnomeHelper,
              builder: (context, helper) => _gnomeHelperRow(context, helper),
            ),
          ],
        ),
      _PanelSection(
        title: l10n.shellSettingsSharing,
        glyph: WhisperGlyph.link,
        color: WhisperSettingsIcons.sharing,
        rows: [
          if (_isMacPlatform) ..._macPermissionRows(l10n),
          if (desktop)
            SettingsSwitchRow(
              title: l10n.windowStreamShareSetting,
              value: WindowStreamHost.shared.sharingAllowed,
              onChanged: _setWindowSharing,
            ),
          _allowClipboardRow(l10n),
          _autoClipboardRow(l10n),
          _gainRow(l10n),
          if (desktop) _scrollSpeedRow(l10n),
        ],
      ),
      _PanelSection(
        title: l10n.shellSettingsNotifications,
        glyph: WhisperGlyph.bell,
        color: WhisperSettingsIcons.notifications,
        rows: [
          _ignoreNotificationsRow(l10n),
          _copyCodeRow(l10n),
          if (android) ..._pushNotificationRows(l10n),
        ],
      ),
      _PanelSection(
        title: l10n.shellSettingsAbout,
        glyph: WhisperGlyph.info,
        color: WhisperSettingsIcons.about,
        rows: [_versionRow(l10n), _aboutRow(l10n)],
      ),
    ];
  }

  // ----------------------------------------------------------------- page

  Widget _buildPage(BuildContext context) {
    final c = context.wc;
    final l10n = AppLocalizations.of(context)!;
    const type = WhisperType(touch: true);
    final android = _isAndroidPlatform;
    Widget group(String? label, List<Widget> rows) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null) SettingsGroupLabel(label),
        SettingsGroup(children: rows),
      ],
    );
    final list = _isLoading || _loadFailed
        ? _loadState(l10n)
        : ListView(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 52),
            children: [
              group(null, [_selfRow(l10n)]),
              // Share links do not exist on iOS.
              if (android) ...[
                const SizedBox(height: 18),
                group(null, [_shareLinksRow(l10n)]),
              ],
              const SizedBox(height: 18),
              group(l10n.shellSettingsGeneral, [
                _nicknameRow(l10n),
                _appearanceRow(l10n),
                _languageRow(l10n),
                _saveToRow(l10n),
                _gainRow(l10n),
              ]),
              const SizedBox(height: 18),
              group(l10n.shellSettingsConnection, [
                _portRow(l10n),
                _autoConnectRow(l10n),
                if (android) ..._androidConnectionRows(l10n),
              ]),
              const SizedBox(height: 18),
              group(l10n.shellSettingsClipboardNotifications, [
                _allowClipboardRow(l10n),
                _autoClipboardRow(l10n),
                if (android) ..._pushNotificationRows(l10n),
                _ignoreNotificationsRow(l10n),
                _copyCodeRow(l10n),
              ]),
              const SizedBox(height: 18),
              group(null, [_versionRow(l10n), _aboutRow(l10n)]),
            ],
          );
    return Scaffold(
      backgroundColor: c.canvas,
      body: SafeArea(
        bottom: false,
        child: SettingsTextStyle(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Over the content only once there is content under it.
              DecoratedBox(
                decoration: BoxDecoration(
                  border: _pageScrolled
                      ? Border(
                          bottom: BorderSide(
                            color: c.sep,
                            width: 1 / MediaQuery.devicePixelRatioOf(context),
                          ),
                        )
                      : null,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: SizedBox(
                    height: 50,
                    child: Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        // The arrow's target is 48 and its glyph small, so the
                        // title sits inside the target, next to the glyph.
                        Padding(
                          padding: EdgeInsets.only(
                            left: shellPageShowsBack(context) ? 46 : 16,
                          ),
                          child: Text(
                            l10n.setting,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: type.head,
                              height: 1.25,
                              fontWeight: FontWeight.w600,
                              color: c.ink,
                            ),
                          ),
                        ),
                        if (shellPageShowsBack(context))
                          Pressable(
                            radius: WhisperRadius.capsule,
                            label: l10n.back,
                            onTap: () => Navigator.of(context).maybePop(),
                            child: SizedBox.square(
                              dimension: 48,
                              child: Center(
                                child: WhisperIcon(
                                  WhisperGlyph.back,
                                  size: 20,
                                  weight: 2,
                                  color: c.ink,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: NotificationListener<ScrollMetricsNotification>(
                  onNotification: (n) {
                    _setPageScrolled(n.metrics.pixels > 0);
                    return false;
                  },
                  child: NotificationListener<ScrollUpdateNotification>(
                    onNotification: (n) {
                      _setPageScrolled(n.metrics.pixels > 0);
                      return false;
                    },
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(
                        context,
                      ).copyWith(scrollbars: false),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 620),
                          child: list,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _setPageScrolled(bool scrolled) {
    if (scrolled != _pageScrolled) _update(() => _pageScrolled = scrolled);
  }

  Widget _selfRow(AppLocalizations l10n) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    final self = device;
    return Pressable(
      scale: 1,
      radius: 0,
      onTap: widget.openPairing,
      child: SettingsHighlight(
        press: c.fill,
        child: SettingsRowFrame(
          minHeight: 64,
          child: Row(
            children: [
              SizedBox(
                width: 44,
                child: Center(
                  child: DeviceArt(
                    kind: deviceKindFor(self?.platform ?? 'android'),
                    os: deviceOsFor(self?.platform ?? ''),
                    wallpaper: DeviceWallpaper.self,
                    size: 44,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      self?.name ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: type.body,
                        height: 1.3,
                        color: c.ink,
                      ),
                    ),
                    Text(
                      l10n.shellSettingsQrAndAddress,
                      style: TextStyle(
                        fontSize: type.note,
                        height: 1.3,
                        color: c.ink2,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              const SettingsDisclosure(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shareLinksRow(AppLocalizations l10n) => ListenableBuilder(
    listenable: _shareLinks,
    builder: (context, _) => SettingsRow(
      title: l10n.shellShareLinks,
      onTap: widget.openShareLinks,
      trailing: SettingsDisclosure(
        value: l10n.shellSettingsLinksOn(
          _shareLinks.serviceOn ? _shareLinks.enabledCount : 0,
        ),
      ),
    ),
  );

  // ----------------------------------------------------------------- rows

  Widget _nicknameRow(AppLocalizations l10n) => SettingsFieldRow(
    title: l10n.nickname,
    value: device?.name ?? '',
    validate: (text) {
      if (text.trim().isEmpty) return l10n.validationNicknameRequired;
      if (text.trim().runes.length > 64) return l10n.validationNicknameTooLong;
      return null;
    },
    onCommit: _commitNickname,
    onInvalid: _say,
  );

  Widget _portRow(AppLocalizations l10n) => SettingsFieldRow(
    title: l10n.serverPortTitle,
    value: '${device?.port ?? 10002}',
    keyboardType: TextInputType.number,
    inputFormatters: [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(5),
    ],
    validate: (text) {
      final port = int.tryParse(text);
      return port == null || port < 1 || port > 65535
          ? l10n.manualConnectPortInvalid
          : null;
    },
    onCommit: (text) => _commitServerPort(int.parse(text)),
    onInvalid: _say,
  );

  Widget _appearanceRow(AppLocalizations l10n) => SettingsRow(
    title: l10n.shellSettingsAppearance,
    stackWhenTight: true,
    trailing: SettingsSegmented<ThemeMode>(
      segments: {
        ThemeMode.system: l10n.shellSettingsAppearanceAuto,
        ThemeMode.light: l10n.shellSettingsAppearanceLight,
        ThemeMode.dark: l10n.shellSettingsAppearanceDark,
      },
      selected: _themeMode,
      onChanged: (mode) => unawaited(_updateThemeMode(mode)),
    ),
  );

  Widget _languageRow(AppLocalizations l10n) => SettingsRow(
    title: l10n.shellSettingsLanguage,
    stackWhenTight: true,
    trailing: SettingsPopupButton<String?>(
      title: l10n.shellSettingsLanguage,
      selected: _pickedLanguage,
      items: [
        SettingsMenuItem(null, l10n.followSystem),
        for (final locale in _SettingsScreenState._supportedLocales)
          SettingsMenuItem(
            locale.languageCode,
            _localeLabel(context, locale.languageCode),
          ),
      ],
      onSelected: (code) => unawaited(_setLanguage(code)),
    ),
  );

  /// Null follows the system: nothing stored, the same as never having picked.
  /// That takes effect at once by picking what the system would.
  Future<void> _setLanguage(String? code) async {
    _update(() => _pickedLanguage = code);
    MyApp.setLocale(
      context,
      Locale(code ?? systemLanguageCode(PlatformDispatcher.instance.locales)),
    );
    await LocalSetting().setLocalization(code ?? '');
  }

  /// ~ for the home folder: it is the part nobody needs to read.
  String get _shownPath {
    final home =
        Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    if (home != null && home.isNotEmpty && _path.startsWith(home)) {
      return '~${_path.substring(home.length)}';
    }
    return _path;
  }

  /// A phone's storage root says nothing, and neither does most of a path.
  String _pagePath(AppLocalizations l10n) {
    final parts = _path
        .split(RegExp(r'[/\\]'))
        .where((part) => part.isNotEmpty)
        .toList();
    final last = parts.length <= 2 ? parts : parts.sublist(parts.length - 2);
    return last
        .map(
          (part) => part == 'Download' ? l10n.remoteFilesPlaceDownloads : part,
        )
        .join(' / ');
  }

  Widget _saveToRow(AppLocalizations l10n) {
    if (_isPage) {
      return SettingsRow(
        title: l10n.shellSettingsSaveTo,
        onTap: _pickSaveDir,
        onLongPress: _openSaveDirectory,
        trailing: SettingsDisclosure(value: _pagePath(l10n)),
      );
    }
    return SettingsRow(
      title: l10n.shellSettingsSaveTo,
      fillTrailing: true,
      trailing: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Flexible(
            child: Tooltip(
              message: _path,
              child: GestureDetector(
                onTap: () => unawaited(_openSaveDirectory()),
                child: SettingsPathText(_shownPath),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SettingsButton(
            label: l10n.shellSettingsChange,
            onTap: () => unawaited(_pickSaveDir()),
          ),
        ],
      ),
    );
  }

  Widget _autoConnectRow(AppLocalizations l10n) => SettingsSwitchRow(
    title: l10n.autoConnectTrustedDevices,
    value: _autoConnect,
    onChanged: _setAutoConnect,
  );

  Widget _castRow(AppLocalizations l10n) => AnimatedBuilder(
    animation: CastReceiverManager.shared,
    builder: (context, _) {
      final receiver = CastReceiverManager.shared;
      return SettingsSwitchRow(
        title: l10n.shellSettingsCast,
        subtitle: switch (receiver.status.issue) {
          CastReceiverIssue.noLanAddress => l10n.castReceiverNoLan,
          CastReceiverIssue.startupFailed => l10n.castReceiverStartupFailed,
          null =>
            receiver.busy ? l10n.castReceiverStarting : l10n.castReceiverHint,
        },
        value: receiver.enabled,
        onChanged: receiver.busy
            ? null
            : (value) => unawaited(receiver.setEnabled(value)),
      );
    },
  );

  List<Widget> _androidConnectionRows(AppLocalizations l10n) => [
    SettingsSwitchRow(
      title: l10n.shellSettingsKeepAlive,
      value: _androidBackgroundKeepAlive,
      onChanged: _setBackgroundKeepAlive,
    ),
    IslandOverlaySetting(
      read: widget.readIslandOverlay ?? AndroidPrivacyPermission.islandOverlay,
      builder: (context, allowed) => SettingsRow(
        title: l10n.islandOverlay,
        onTap: () => unawaited(AndroidPrivacyPermission.requestIslandOverlay()),
        trailing: SettingsDisclosure(
          value: allowed ? l10n.islandOverlayOn : l10n.islandOverlayOff,
        ),
      ),
    ),
    SettingsRow(
      title: l10n.androidBatteryOptimization,
      onTap: () => unawaited(openAndroidBatteryOptimizationSettings()),
      trailing: const SettingsDisclosure(),
    ),
    SettingsRow(
      title: l10n.androidWindowServiceEntryTitle,
      onTap: () => Navigator.of(context).push(
        WhisperPageRoute<void>(
          builder: (_) => const AndroidWindowServicePage(),
        ),
      ),
      trailing: const SettingsDisclosure(),
    ),
  ];

  /// The switch and the recorder. The recorder only with the switch on, and
  /// saying so when the system would not take the shortcut.
  List<Widget> _screenshotRows(AppLocalizations l10n) {
    final screenshot = _screenshot;
    return [
      AnimatedBuilder(
        animation: screenshot,
        builder: (context, _) => SettingsSwitchRow(
          title: l10n.shellSettingsScreenshotEnabled,
          value: screenshot.enabled,
          onChanged: screenshot.configuring
              ? null
              : (value) => unawaited(_setScreenshotEnabled(value, l10n)),
        ),
      ),
      AnimatedBuilder(
        animation: screenshot,
        builder: (context, _) => SettingsCollapse(
          visible: screenshot.enabled,
          child: SettingsRow(
            title: l10n.screenshotShortcutTitle,
            subtitle: screenshot.registered
                ? null
                : l10n.screenshotShortcutUnavailable,
            trailing: Align(
              alignment: Alignment.centerRight,
              widthFactor: 1,
              child: SettingsShortcutButton(
                controller: screenshot,
                title: l10n.screenshotShortcutTitle,
                onError: _say,
              ),
            ),
          ),
        ),
      ),
    ];
  }

  Future<void> _setScreenshotEnabled(
    bool enabled,
    AppLocalizations l10n,
  ) async {
    final screenshot = _screenshot;
    try {
      await screenshot.initialize(l10n.screenshotCapture);
      await screenshot.configure(screenshot.shortcut, enabled: enabled);
    } catch (_) {
      _say(l10n.screenshotShortcutFailed);
    }
  }

  Widget _windowsServiceRow(AppLocalizations l10n) => AnimatedBuilder(
    animation: _windowsInputService,
    builder: (context, _) {
      final service = _windowsInputService;
      final state = service.state;
      final running = state == WindowsInputServiceState.running;
      final installed = running || state == WindowsInputServiceState.stopped;
      return SettingsServiceRow(
        title: l10n.windowsLockScreenInput,
        hint: service.busy ? l10n.windowsLockScreenInputWorking : null,
        status: switch (state) {
          WindowsInputServiceState.running =>
            l10n.windowsLockScreenInputRunning,
          WindowsInputServiceState.stopped =>
            l10n.windowsLockScreenInputStopped,
          WindowsInputServiceState.outdated =>
            l10n.windowsLockScreenInputOutdated,
          _ => l10n.windowsLockScreenInputNotInstalled,
        },
        action: service.busy
            ? null
            : installed
            ? l10n.windowsLockScreenInputUninstall
            : state == WindowsInputServiceState.outdated
            ? l10n.windowsLockScreenInputRepair
            : l10n.windowsLockScreenInputInstall,
        onAction: () => unawaited(
          changeWindowsLockScreenInput(
            context,
            controller: service,
            remove: installed,
          ),
        ),
        // Whether the service also reaches UAC prompts. It can only while it
        // runs, and the hint says this switch is what controls that.
        extra: running
            ? Tooltip(
                message: l10n.windowsElevatedInput,
                child: WhisperSwitch(
                  value: service.elevatedAllowed,
                  label: l10n.windowsElevatedInput,
                  onChanged: service.busy
                      ? null
                      : (value) => unawaited(
                          changeWindowsElevatedInput(
                            context,
                            value,
                            controller: service,
                          ),
                        ),
                ),
              )
            : null,
      );
    },
  );

  Widget _gnomeHelperRow(
    BuildContext context,
    GnomeShellHelperController helper,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final state = helper.state;
    void open() =>
        unawaited(changeGnomeShellHelper(context, controller: helper));
    final action = switch (state) {
      GnomeShellHelperState.notInstalled => l10n.gnomeHelperInstall,
      GnomeShellHelperState.outdated => l10n.gnomeHelperUpdate,
      GnomeShellHelperState.needsRelogin => l10n.gnomeHelperLogOut,
      GnomeShellHelperState.disabled => l10n.gnomeHelperTurnOn,
      GnomeShellHelperState.extensionsOff => l10n.gnomeHelperTurnOnExtensions,
      _ => null,
    };
    return SettingsServiceRow(
      title: l10n.gnomeHelperTitle,
      hint: helper.busy ? l10n.gnomeHelperWorking : null,
      status: helper.checked ? gnomeHelperStateLabel(context, state) : '',
      action: helper.busy ? null : action,
      onAction: open,
      // Ready has nothing to press, but it can still say what it is doing.
      onTap: !helper.busy && state == GnomeShellHelperState.ready ? open : null,
    );
  }

  /// A permission macOS does not report has no row.
  List<Widget> _macPermissionRows(AppLocalizations l10n) {
    final permissions = widget.macPermissions ?? MacPermissions.shared;
    Widget row(MacPermission permission, String title) => AnimatedBuilder(
      animation: permissions,
      builder: (context, _) {
        final state = permissions.stateOf(permission);
        if (permission == MacPermission.audioCapture &&
            state == MacPermissionState.unknown) {
          return const SizedBox.shrink();
        }
        return SettingsRow(
          title: title,
          onTap: () => unawaited(permissions.request(permission)),
          trailing: SettingsDisclosure(
            value: switch (state) {
              MacPermissionState.granted => l10n.macPermissionGranted,
              MacPermissionState.unknown => null,
              _ => l10n.macPermissionDenied,
            },
          ),
        );
      },
    );
    return [
      row(MacPermission.accessibility, l10n.macPermissionAccessibility),
      row(MacPermission.screenRecording, l10n.macPermissionScreenRecording),
      row(MacPermission.audioCapture, l10n.macPermissionAudioCapture),
    ];
  }

  Widget _allowClipboardRow(AppLocalizations l10n) => SettingsSwitchRow(
    title: l10n.shellSettingsAllowClipboard,
    value: device?.clipboard ?? false,
    onChanged: _setClipboard,
  );

  Widget _autoClipboardRow(AppLocalizations l10n) => SettingsSwitchRow(
    title: l10n.shellSettingsAutoClipboard,
    value: _clipboardAutoSync,
    onChanged: _setClipboardAutoSync,
  );

  String _multiplier(AppLocalizations l10n, double value) =>
      l10n.shellSettingsMultiplier(value.toStringAsFixed(1));

  Widget _gainRow(AppLocalizations l10n) => SettingsSliderRow(
    title: l10n.shellSettingsPlaybackGain,
    valueLabel: _multiplier(l10n, _audioSharePlaybackGain),
    value: _audioSharePlaybackGain,
    min: 1,
    max: 3,
    divisions: 20,
    onChanged: (value) => _update(() => _audioSharePlaybackGain = value),
    onChangeEnd: (value) => unawaited(_commitPlaybackGain(value)),
  );

  Widget _scrollSpeedRow(AppLocalizations l10n) => SettingsSliderRow(
    title: l10n.remoteInputScrollMultiplierTitle,
    valueLabel: _multiplier(l10n, _remoteInputScrollMultiplier),
    value: _remoteInputScrollMultiplier,
    min: .5,
    max: 3,
    divisions: 25,
    onChanged: (value) => _update(() => _remoteInputScrollMultiplier = value),
    onChangeEnd: (value) => unawaited(_commitScrollMultiplier(value)),
  );

  Widget _ignoreNotificationsRow(AppLocalizations l10n) => SettingsSwitchRow(
    title: l10n.ignoreNotification,
    value: _ignoreAndroid,
    onChanged: _setIgnoreAndroid,
  );

  Widget _copyCodeRow(AppLocalizations l10n) => SettingsSwitchRow(
    title: l10n.shellSettingsCopyCode,
    value: _copyVerifyCode,
    onChanged: _setCopyVerifyCode,
  );

  List<Widget> _pushNotificationRows(AppLocalizations l10n) => [
    SettingsSwitchRow(
      title: l10n.pushNotification,
      value: _listenAndroid,
      onChanged: _notificationForwardingBusy
          ? null
          : _updateNotificationForwarding,
    ),
    if (_listenAndroid)
      SettingsRow(
        title: l10n.notificationApps,
        onTap: _notificationForwardingBusy ? null : _openNotificationApps,
        trailing: SettingsDisclosure(
          value: l10n.shellSettingsAppsSelected(_notificationAppCount),
        ),
      ),
  ];

  Widget _versionRow(AppLocalizations l10n) {
    final c = context.wc;
    final result = _updateResult;
    final release = result?.release;
    final available = result?.hasUpdate == true && release != null;
    final progress = _updateDownloadProgress.clamp(0.0, 1.0);
    final busy = _checkingForUpdates || _downloadingUpdate;
    final String value = _downloadingUpdate
        ? l10n.shellSettingsVersionDownloading((progress * 100).round())
        : _checkingForUpdates
        ? l10n.shellSettingsVersionChecking
        : available
        ? l10n.shellSettingsVersionAvailable(release.version)
        // Only after asking: a failed check does not make this the latest.
        : result != null
        ? l10n.shellSettingsVersionLatest(_version)
        : _version;
    return SettingsRow(
      title: l10n.shellSettingsVersion,
      onTap: busy ? null : () => unawaited(_handleUpdateTap()),
      trailing: SettingsValue(
        value,
        color: available && !busy ? c.accentText : null,
      ),
      below: _downloadingUpdate
          ? Padding(
              padding: EdgeInsets.fromLTRB(
                _isPage ? 12 : 14,
                0,
                _isPage ? 12 : 14,
                8,
              ),
              child: WhisperProgressBar(value: progress),
            )
          : null,
    );
  }

  Widget _aboutRow(AppLocalizations l10n) => SettingsRow(
    title: l10n.aboutWhisper,
    onTap: () => _showAbout(l10n, Localizations.localeOf(context)),
    trailing: const SettingsDisclosure(),
  );

  void _showAbout(AppLocalizations l10n, Locale locale) {
    final touch = _isPage || _isMobilePlatform;
    final page = _isPage;
    unawaited(
      Navigator.of(context, rootNavigator: true).push(
        WhisperModalRoute<void>(
          scrim: context.wc.scrim,
          barrierLabel: MaterialLocalizations.of(
            context,
          ).modalBarrierDismissLabel,
          style: page ? WhisperModalStyle.bottomSheet : WhisperModalStyle.sheet,
          builder: (sheetContext) => SettingsScope(
            touch: touch,
            page: page,
            child: SettingsAboutSheet(
              icon: _buildAboutIcon(64),
              name: 'Whisper',
              description: l10n.aboutWhisperDescription,
              version: l10n.shellSettingsAboutVersion(_version),
              doneLabel: l10n.shellDone,
              links: [
                (
                  l10n.officialWebsite,
                  () => unawaited(
                    _launchInBrowser(
                      Uri.https(
                        'whisper.127014.xyz',
                        '/${locale.languageCode}',
                      ),
                    ),
                  ),
                ),
                (
                  l10n.sourceCode,
                  () => unawaited(
                    _launchInBrowser(
                      Uri.https('github.com', '/lawnvi/whisper'),
                    ),
                  ),
                ),
                (
                  MaterialLocalizations.of(
                    sheetContext,
                  ).viewLicensesButtonLabel,
                  () => showLicensePage(
                    context: sheetContext,
                    applicationName: 'Whisper',
                    applicationVersion: l10n.shellSettingsAboutVersion(
                      _version,
                    ),
                    applicationIcon: _buildAboutIcon(48),
                    applicationLegalese: 'Copyright © 2026 lawnvi',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One entry of the panel's list and what it shows.
class _PanelSection {
  const _PanelSection({
    required this.title,
    required this.glyph,
    required this.color,
    required this.rows,
  });

  final String title;

  /// Null draws this computer: see [SettingsTile].
  final WhisperGlyph? glyph;
  final Color color;
  final List<Widget> rows;
}
