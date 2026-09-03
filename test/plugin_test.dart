import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/services/plugin/plugin_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('getInstalledPluginPaths returns visible plugin directories', () async {
    final pluginsRoot = await Directory.systemTemp.createTemp(
      'vbook_plugin_paths_',
    );
    addTearDown(() async {
      if (await pluginsRoot.exists()) {
        await pluginsRoot.delete(recursive: true);
      }
    });

    final installedPlugin = await Directory(
      '${pluginsRoot.path}${Platform.pathSeparator}sample-plugin',
    ).create();
    await Directory(
      '${pluginsRoot.path}${Platform.pathSeparator}.transaction-pending',
    ).create();

    final paths = await PluginLoader.getInstalledPluginPaths(
      pluginsRoot: pluginsRoot,
    );

    expect(paths, [installedPlugin.path]);
  });
}
