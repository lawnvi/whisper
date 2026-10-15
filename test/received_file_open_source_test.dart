import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/android_document_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows opens a received file without a command interpreter', () {
    final source = File('lib/helper/file.dart').readAsStringSync();
    final openFile = source.substring(
      source.indexOf('void openFile(String path) async {'),
      source.indexOf('Future<void> openDir('),
    );
    final windowsBranch = openFile.indexOf('if (Platform.isWindows) {');
    final plugin = openFile.indexOf('OpenFilex.open(path)');

    // open_filex runs `cmd /c start "" <path>` on Windows. With no space in
    // the path cmd takes `&` in the file name as the start of a command,
    // and the name comes from whoever sent the file.
    expect(windowsBranch, greaterThan(0));
    expect(plugin, greaterThan(windowsBranch));
    final branch = openFile.substring(windowsBranch, plugin);
    expect(branch, contains('openWithWindowsShell(path)'));
    expect(branch, contains('return;'));

    final helper = File(
      'lib/helper/windows_shell_open.dart',
    ).readAsStringSync();
    expect(helper, contains("'ShellExecuteW'"));
    expect(helper, isNot(contains('Process.')));
  });

  test('Android opens a local file through its own file provider', () {
    final source = File('lib/helper/file.dart').readAsStringSync();
    final openFile = source.substring(
      source.indexOf('void openFile(String path) async {'),
      source.indexOf('Future<void> openDir('),
    );
    final androidBranch = openFile.indexOf('if (Platform.isAndroid) {');
    final provider = openFile.indexOf(
      'AndroidDocumentPicker.shared.openFile(path)',
    );
    final plugin = openFile.indexOf('OpenFilex.open(path)');

    // open_filex wants READ_MEDIA_* (READ_EXTERNAL_STORAGE before Android 13)
    // for a file outside the app's folders and doesn't count all files
    // access. The manifest removes those, so received media never opened.
    expect(androidBranch, greaterThan(0));
    expect(provider, greaterThan(androidBranch));
    expect(plugin, greaterThan(provider));

    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('android:name=".LocalFileProvider"'));
    expect(
      manifest,
      contains(r'android:authorities="${applicationId}.local_files"'),
    );
    expect(manifest, contains('@xml/android_local_file_paths'));
    expect(
      manifest,
      contains(
        '<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" tools:node="remove" />',
      ),
    );
    final paths = File(
      'android/app/src/main/res/xml/android_local_file_paths.xml',
    ).readAsStringSync();
    expect(paths, contains('<external-path'));

    final picker = File(
      'android/app/src/main/kotlin/com/vireen/whisper/AndroidDocumentPickerPlugin.kt',
    ).readAsStringSync();
    expect(picker, contains('"openFile" -> openFile(call, result)'));
    final open = picker.substring(
      picker.indexOf('private fun openFile('),
      picker.indexOf('private fun view('),
    );
    expect(
      open,
      contains(
        r'FileProvider.getUriForFile(context, "${context.packageName}.local_files", file)',
      ),
    );
    expect(open, contains('result.success(view(uri))'));
    // The chosen app gets this one file, read only, for as long as it shows it.
    final view = picker.substring(
      picker.indexOf('private fun view('),
      picker.indexOf('private fun readDocumentRange('),
    );
    expect(view, contains('Intent.FLAG_GRANT_READ_URI_PERMISSION'));
    expect(view, isNot(contains('FLAG_GRANT_WRITE_URI_PERMISSION')));
    expect(view, isNot(contains('grantUriPermission(')));
  });

  test('openFile asks the Android picker channel with the file path', () async {
    const channel = MethodChannel('com.vireen.whisper/android_document_picker');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final opened = await AndroidDocumentPicker().openFile(
      '/storage/emulated/0/Download/whisper/clip.mp4',
    );

    expect(opened, isTrue);
    expect(calls.single.method, 'openFile');
    expect(calls.single.arguments, <String, Object?>{
      'path': '/storage/emulated/0/Download/whisper/clip.mp4',
    });
  });
}
