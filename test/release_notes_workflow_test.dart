import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('README keeps release history in GitHub Releases', () {
    final readme = File('README.md').readAsStringSync();
    final englishReadme = File('README_en.md').readAsStringSync();

    expect(readme, isNot(contains('## 最近更新')));
    expect(readme, contains('查看版本更新说明'));
    expect(englishReadme, isNot(contains('## Recent Updates')));
    expect(englishReadme, contains('View release notes'));
  });

  test('tagged releases generate notes without replacing notes on rebuild', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();
    final taggedRelease = workflow.substring(
      workflow.indexOf('      - name: Publish tagged release'),
      workflow.indexOf('      - name: Update manually rebuilt release asset'),
    );
    final manualRelease = workflow.substring(
      workflow.indexOf('      - name: Update manually rebuilt release asset'),
    );

    expect(workflow, contains('name: Check out release history'));
    expect(workflow, contains('fetch-depth: 0'));
    expect(workflow, contains('name: Generate release notes'));
    expect(workflow, contains('script/generate_release_notes.sh'));
    expect(taggedRelease, contains('body_path: release-notes.md'));
    expect(manualRelease, isNot(contains('body_path:')));
  });

  test('release notes group user-facing conventional commits', () {
    if (Platform.isWindows) return;

    final repository = Directory.systemTemp.createTempSync(
      'whisper-release-notes-',
    );
    addTearDown(() => repository.deleteSync(recursive: true));

    void runGit(List<String> arguments) {
      final result = Process.runSync(
        'git',
        arguments,
        workingDirectory: repository.path,
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }

    final history = File('${repository.path}/history.txt');
    runGit(<String>['init', '--quiet']);
    runGit(<String>['config', 'user.name', 'Whisper Tests']);
    runGit(<String>['config', 'user.email', 'tests@whisper.local']);

    void commit(String subject) {
      history.writeAsStringSync('$subject\n', mode: FileMode.append);
      runGit(<String>['add', 'history.txt']);
      runGit(<String>['commit', '--quiet', '-m', subject]);
    }

    commit('chore: 建立发布基线');
    runGit(<String>['tag', 'dev-v1.0.0']);
    commit('feat(remote-input): 支持跨设备路由');
    commit('perf(transfer): 提升文件传输速度');
    commit('fix(ui): 修复进度显示');
    commit('fix(ci): 修复发布环境');
    commit('docs(readme): 更新开发文档');
    runGit(<String>['tag', 'dev-v1.1.0']);

    final output = File('${repository.path}/release-notes.md');
    final script = File('script/generate_release_notes.sh').absolute.path;
    final result = Process.runSync(
      'bash',
      <String>[script, 'dev-v1.1.0', output.path],
      workingDirectory: repository.path,
      environment: <String, String>{
        ...Platform.environment,
        'WHISPER_RELEASE_REPOSITORY_URL': 'https://example.com/whisper',
      },
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final notes = output.readAsStringSync();
    expect(notes, contains('## 新功能'));
    expect(notes, contains('- 支持跨设备路由'));
    expect(notes, contains('## 性能优化'));
    expect(notes, contains('- 提升文件传输速度'));
    expect(notes, contains('## 修复与改进'));
    expect(notes, contains('- 修复进度显示'));
    expect(notes, isNot(contains('修复发布环境')));
    expect(notes, isNot(contains('更新开发文档')));
    expect(
      notes,
      contains('https://example.com/whisper/compare/dev-v1.0.0...dev-v1.1.0'),
    );
  });
}
