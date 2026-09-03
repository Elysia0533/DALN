import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:online_story_reader/models/plugin_info.dart';
import 'package:online_story_reader/services/extension_service.dart';
import 'package:online_story_reader/services/plugin/plugin_loader.dart';
import 'package:online_story_reader/services/plugin/vbook_engine_channel.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const crossProcessPhase = String.fromEnvironment('PLUGIN_RECOVERY_PHASE');
  if (crossProcessPhase == 'prepare') {
    _registerCrossProcessPreparationTest();
    return;
  }
  if (crossProcessPhase == 'recover') {
    _registerCrossProcessRecoveryTest();
    return;
  }

  const installedPluginsKey = 'installed_plugins';
  late Directory sandbox;
  late Directory pluginsRoot;
  late SharedPreferences prefs;
  String? originalInstalledPlugins;

  setUp(() async {
    PluginLoader.forgetActiveTransactionsForTesting();
    prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    originalInstalledPlugins = prefs.getString(installedPluginsKey);
    await prefs.remove(installedPluginsKey);

    final temporaryRoot = await getTemporaryDirectory();
    sandbox = await temporaryRoot.createTemp('vbook-plugin-integration-');
    pluginsRoot = Directory(p.join(sandbox.path, 'plugins'));
    await pluginsRoot.create(recursive: true);
  });

  tearDown(() async {
    PluginLoader.forgetActiveTransactionsForTesting();
    for (final pluginId in const <String>[
      'integration.restart.plugin',
      'integration.final-load.plugin',
    ]) {
      await VBookEngineChannel.closeSource(pluginId);
    }
    if (originalInstalledPlugins == null) {
      await prefs.remove(installedPluginsKey);
    } else {
      await prefs.setString(installedPluginsKey, originalInstalledPlugins!);
    }
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  testWidgets('Android filesystem recovery restores a committed backup', (
    tester,
  ) async {
    const pluginId = 'integration.restart.plugin';
    final oldPlugin = _pluginInfo(pluginId, version: 1);
    final newPlugin = _pluginInfo(pluginId, version: 2);
    await prefs.setString(
      installedPluginsKey,
      jsonEncode(<Map<String, dynamic>>[oldPlugin.toJson()]),
    );
    final target = Directory(p.join(pluginsRoot.path, pluginId));
    await _writePluginDirectory(target, pluginId, version: 1);
    final zip = await _writePluginZip(
      sandbox,
      pluginId,
      version: 2,
      name: 'restart-update.zip',
    );

    final prepared = await PluginLoader.prepareInstallFromZipFile(
      zip,
      pluginsRoot: pluginsRoot,
    );
    await prepared.recordExpectedInstalledPlugin(newPlugin.toJson());
    await prepared.commit();
    expect(await File(p.join(target.path, 'version-2.txt')).exists(), isTrue);

    PluginLoader.forgetActiveTransactionsForTesting();
    final installed = await ExtensionService.getInstalledPlugins(
      pluginsRoot: pluginsRoot,
    );

    expect(installed.single.version, 1);
    expect(await File(p.join(target.path, 'version-1.txt')).exists(), isTrue);
    expect(await File(p.join(target.path, 'version-2.txt')).exists(), isFalse);
    expect(_transactionArtifacts(pluginsRoot), isEmpty);
  });

  testWidgets(
    'native staging load and injected final failure restore old source',
    (tester) async {
      const pluginId = 'integration.final-load.plugin';
      final oldPlugin = _pluginInfo(pluginId, version: 1);
      await prefs.setString(
        installedPluginsKey,
        jsonEncode(<Map<String, dynamic>>[oldPlugin.toJson()]),
      );
      final target = Directory(p.join(pluginsRoot.path, pluginId));
      await _writePluginDirectory(target, pluginId, version: 1);
      final zip = await _writePluginZip(
        sandbox,
        pluginId,
        version: 2,
        name: 'final-load-update.zip',
      );

      var stagingLoadedByNativeEngine = false;
      var finalLoadAttempts = 0;
      var previousSourceReloaded = false;
      Future<bool> loadWithOneFinalFailure(String id, String path) async {
        if (id.startsWith('vbook_install_validation_')) {
          final loaded = await VBookEngineChannel.loadSource(id, path);
          stagingLoadedByNativeEngine = loaded;
          return loaded;
        }
        if (id == pluginId) {
          finalLoadAttempts++;
          if (finalLoadAttempts == 1) {
            return false;
          }
          final loaded = await VBookEngineChannel.loadSource(id, path);
          previousSourceReloaded = loaded;
          return loaded;
        }
        return VBookEngineChannel.loadSource(id, path);
      }

      await expectLater(
        ExtensionService.installFromZipFile(
          zip,
          pluginsRoot: pluginsRoot,
          engineLoader: loadWithOneFinalFailure,
          engineCloser: VBookEngineChannel.closeSource,
        ),
        throwsA(isA<Exception>()),
      );

      expect(stagingLoadedByNativeEngine, isTrue);
      expect(finalLoadAttempts, 2);
      expect(previousSourceReloaded, isTrue);
      expect(await File(p.join(target.path, 'version-1.txt')).exists(), isTrue);
      expect(
        await File(p.join(target.path, 'version-2.txt')).exists(),
        isFalse,
      );
      final installed = await ExtensionService.getInstalledPlugins(
        pluginsRoot: pluginsRoot,
      );
      expect(installed.single.version, 1);
      expect(_transactionArtifacts(pluginsRoot), isEmpty);
    },
  );
}

const _installedPluginsKey = 'installed_plugins';
const _crossProcessFixtureActiveKey =
    'integration_plugin_recovery_fixture_active';
const _crossProcessHadOriginalKey = 'integration_plugin_recovery_had_original';
const _crossProcessOriginalValueKey =
    'integration_plugin_recovery_original_value';
const _crossProcessPreparePidKey = 'integration_plugin_recovery_prepare_pid';
const _crossProcessPluginId = 'integration.process-restart.plugin';

void _registerCrossProcessPreparationTest() {
  testWidgets('leaves a committed update for a new process to recover', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final sandbox = await _crossProcessSandbox();
    if (prefs.getBool(_crossProcessFixtureActiveKey) == true) {
      await _restoreCrossProcessPreferences(prefs);
      if (await sandbox.exists()) {
        await sandbox.delete(recursive: true);
      }
    }

    final originalValue = prefs.getString(_installedPluginsKey);
    await prefs.setBool(_crossProcessHadOriginalKey, originalValue != null);
    if (originalValue == null) {
      await prefs.remove(_crossProcessOriginalValueKey);
    } else {
      await prefs.setString(_crossProcessOriginalValueKey, originalValue);
    }
    await prefs.setInt(_crossProcessPreparePidKey, pid);
    await prefs.setBool(_crossProcessFixtureActiveKey, true);

    final oldPlugin = _pluginInfo(_crossProcessPluginId, version: 1);
    final newPlugin = _pluginInfo(_crossProcessPluginId, version: 2);
    await prefs.setString(
      _installedPluginsKey,
      jsonEncode(<Map<String, dynamic>>[oldPlugin.toJson()]),
    );
    await sandbox.create(recursive: true);
    final pluginsRoot = Directory(p.join(sandbox.path, 'plugins'));
    await pluginsRoot.create(recursive: true);
    final target = Directory(p.join(pluginsRoot.path, _crossProcessPluginId));
    await _writePluginDirectory(target, _crossProcessPluginId, version: 1);
    final zip = await _writePluginZip(
      sandbox,
      _crossProcessPluginId,
      version: 2,
      name: 'process-interruption.zip',
    );

    final prepared = await PluginLoader.prepareInstallFromZipFile(
      zip,
      pluginsRoot: pluginsRoot,
    );
    await prepared.recordExpectedInstalledPlugin(newPlugin.toJson());
    await prepared.commit();

    expect(await File(p.join(target.path, 'version-2.txt')).exists(), isTrue);
    expect(
      _transactionArtifacts(
        pluginsRoot,
      ).any((name) => name.startsWith('.transaction-')),
      isTrue,
    );
    expect(
      _transactionArtifacts(
        pluginsRoot,
      ).any((name) => name.startsWith('.backup-')),
      isTrue,
    );
  });
}

void _registerCrossProcessRecoveryTest() {
  testWidgets('a new Android process restores the interrupted update', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final sandbox = await _crossProcessSandbox();
    try {
      expect(prefs.getBool(_crossProcessFixtureActiveKey), isTrue);
      expect(prefs.getInt(_crossProcessPreparePidKey), isNot(pid));
      final pluginsRoot = Directory(p.join(sandbox.path, 'plugins'));
      final target = Directory(p.join(pluginsRoot.path, _crossProcessPluginId));

      final installed = await ExtensionService.getInstalledPlugins(
        pluginsRoot: pluginsRoot,
      );

      expect(installed.single.version, 1);
      expect(await File(p.join(target.path, 'version-1.txt')).exists(), isTrue);
      expect(
        await File(p.join(target.path, 'version-2.txt')).exists(),
        isFalse,
      );
      expect(_transactionArtifacts(pluginsRoot), isEmpty);
    } finally {
      await _restoreCrossProcessPreferences(prefs);
      if (await sandbox.exists()) {
        await sandbox.delete(recursive: true);
      }
    }
  });
}

Future<Directory> _crossProcessSandbox() async {
  final documents = await getApplicationDocumentsDirectory();
  return Directory(p.join(documents.path, 'plugin_recovery_integration'));
}

Future<void> _restoreCrossProcessPreferences(SharedPreferences prefs) async {
  if (prefs.getBool(_crossProcessFixtureActiveKey) != true) {
    return;
  }
  final hadOriginal = prefs.getBool(_crossProcessHadOriginalKey) == true;
  final originalValue = prefs.getString(_crossProcessOriginalValueKey);
  if (hadOriginal && originalValue != null) {
    await prefs.setString(_installedPluginsKey, originalValue);
  } else {
    await prefs.remove(_installedPluginsKey);
  }
  await prefs.remove(_crossProcessFixtureActiveKey);
  await prefs.remove(_crossProcessHadOriginalKey);
  await prefs.remove(_crossProcessOriginalValueKey);
  await prefs.remove(_crossProcessPreparePidKey);
}

PluginInfo _pluginInfo(String id, {required int version}) {
  return PluginInfo(
    id: id,
    name: id,
    author: 'Integration',
    source: 'https://example.com',
    iconUrl: '',
    description: 'Version $version',
    type: 'novel',
    locale: 'vi',
    version: version,
    downloadUrl: '',
    scripts: const <String, String>{
      'home': 'home.js',
      'toc': 'toc.js',
      'chap': 'chap.js',
    },
    isInstalled: true,
    installedVersion: version,
  );
}

Future<void> _writePluginDirectory(
  Directory directory,
  String pluginId, {
  required int version,
}) async {
  final src = Directory(p.join(directory.path, 'src'));
  await src.create(recursive: true);
  await File(
    p.join(directory.path, 'plugin.json'),
  ).writeAsString(jsonEncode(_manifest(pluginId, version)), flush: true);
  for (final script in const <String>['home', 'toc', 'chap']) {
    await File(
      p.join(src.path, '$script.js'),
    ).writeAsString('function execute() { return []; }', flush: true);
  }
  await File(
    p.join(directory.path, 'version-$version.txt'),
  ).writeAsString('version $version', flush: true);
}

Future<File> _writePluginZip(
  Directory directory,
  String pluginId, {
  required int version,
  required String name,
}) async {
  final entries = <String, List<int>>{
    'plugin.json': utf8.encode(jsonEncode(_manifest(pluginId, version))),
    'src/home.js': utf8.encode('function execute() { return []; }'),
    'src/toc.js': utf8.encode('function execute() { return []; }'),
    'src/chap.js': utf8.encode('function execute() { return []; }'),
    'version-$version.txt': utf8.encode('version $version'),
  };
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  final zip = File(p.join(directory.path, name));
  await zip.writeAsBytes(ZipEncoder().encode(archive)!, flush: true);
  return zip;
}

Map<String, dynamic> _manifest(String pluginId, int version) {
  return <String, dynamic>{
    'metadata': <String, dynamic>{
      'id': pluginId,
      'name': pluginId,
      'author': 'Integration',
      'version': version,
      'source': 'https://example.com',
      'description': 'Version $version',
      'locale': 'vi',
      'type': 'novel',
    },
    'script': <String, String>{
      'home': 'home.js',
      'toc': 'toc.js',
      'chap': 'chap.js',
    },
  };
}

List<String> _transactionArtifacts(Directory root) {
  return root
      .listSync(followLinks: false)
      .map((entity) => p.basename(entity.path))
      .where(
        (name) =>
            name.startsWith('.install-') ||
            name.startsWith('.backup-') ||
            name.startsWith('.transaction-'),
      )
      .toList();
}
