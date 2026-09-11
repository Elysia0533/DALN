import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/models/plugin_info.dart';
import 'package:online_story_reader/services/extension_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pluginsRoot;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    pluginsRoot = await Directory.systemTemp.createTemp(
      'vbook_search_metadata_',
    );
  });

  tearDown(() async {
    if (await pluginsRoot.exists()) {
      await pluginsRoot.delete(recursive: true);
    }
  });

  test('legacy installed record is hydrated from its local manifest', () async {
    const pluginId = 'legacy.search';
    final legacyJson = _installedPlugin(pluginId).toJson()
      ..remove('searchCapabilities')
      ..['scripts'] = <String, String>{};
    SharedPreferences.setMockInitialValues(<String, Object>{
      'installed_plugins': jsonEncode(<Map<String, dynamic>>[legacyJson]),
    });
    final pluginDirectory = await Directory(
      '${pluginsRoot.path}${Platform.pathSeparator}$pluginId',
    ).create();
    await File(
      '${pluginDirectory.path}${Platform.pathSeparator}plugin.json',
    ).writeAsString(
      jsonEncode(<String, dynamic>{
        'metadata': <String, dynamic>{'name': 'Legacy search'},
        'script': <String, dynamic>{'search': 'search.js', 'genre': 'genre.js'},
      }),
    );

    final installed = await ExtensionService.getInstalledPlugins(
      pluginsRoot: pluginsRoot,
    );

    expect(installed, hasLength(1));
    expect(installed.single.scripts['search'], 'search.js');
    expect(installed.single.searchCapabilities.supportsKeyword, isTrue);
    expect(installed.single.searchCapabilities.supportsPagination, isTrue);
    expect(installed.single.searchCapabilities.supportsGenre, isFalse);

    final prefs = await SharedPreferences.getInstance();
    final persisted =
        jsonDecode(prefs.getString('installed_plugins')!) as List<dynamic>;
    expect(persisted.single['searchCapabilities'], isA<Map>());
    expect(persisted.single['searchCapabilities']['supportsKeyword'], isTrue);
  });

  test(
    'malformed local manifest keeps installed state without crashing',
    () async {
      const pluginId = 'broken.manifest';
      final storedPlugin = _installedPlugin(
        pluginId,
        scripts: const <String, String>{'search': 'search.js'},
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        'installed_plugins': jsonEncode(<Map<String, dynamic>>[
          storedPlugin.toJson(),
        ]),
      });
      final pluginDirectory = await Directory(
        '${pluginsRoot.path}${Platform.pathSeparator}$pluginId',
      ).create();
      await File(
        '${pluginDirectory.path}${Platform.pathSeparator}plugin.json',
      ).writeAsString('{invalid json');

      final installed = await ExtensionService.getInstalledPlugins(
        pluginsRoot: pluginsRoot,
      );

      expect(installed, hasLength(1));
      expect(installed.single.id, pluginId);
      expect(installed.single.searchCapabilities.supportsKeyword, isTrue);
    },
  );
}

PluginInfo _installedPlugin(
  String id, {
  Map<String, String> scripts = const <String, String>{},
}) {
  return PluginInfo(
    id: id,
    name: 'Installed source',
    author: 'Author',
    source: 'https://example.com',
    iconUrl: '',
    description: '',
    type: 'novel',
    locale: 'vi',
    version: 1,
    downloadUrl: 'https://example.com/plugin.zip',
    scripts: scripts,
    isInstalled: true,
    installedVersion: 1,
  );
}
