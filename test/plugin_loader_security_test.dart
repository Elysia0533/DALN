import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/models/plugin_info.dart';
import 'package:online_story_reader/services/extension_service.dart';
import 'package:online_story_reader/services/plugin/plugin_loader.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory sandbox;
  late Directory pluginsRoot;
  late Directory zipRoot;

  setUp(() async {
    PluginLoader.forgetActiveTransactionsForTesting();
    sandbox = await Directory.systemTemp.createTemp('vbook-plugin-security-');
    pluginsRoot = Directory(p.join(sandbox.path, 'plugins'));
    zipRoot = Directory(p.join(sandbox.path, 'zips'));
    await pluginsRoot.create(recursive: true);
    await zipRoot.create(recursive: true);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    PluginLoader.forgetActiveTransactionsForTesting();
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  group('plugin ID validation', () {
    test('accepts a bounded filesystem-safe ID', () {
      expect(
        PluginLoader.validatePluginId('com.example-reader_1'),
        'com.example-reader_1',
      );
    });

    test('rejects traversal, separators, absolute paths, and invalid IDs', () {
      final invalidIds = <String>[
        '',
        '.',
        '..',
        '../evil',
        'nested/plugin',
        r'nested\plugin',
        '/absolute',
        r'C:\absolute',
        'bad id',
        'trailing.',
        'CON',
      ];

      for (final pluginId in invalidIds) {
        expect(
          () => PluginLoader.validatePluginId(pluginId),
          throwsA(_failure(PluginInstallFailure.invalidPluginId)),
          reason: pluginId,
        );
      }
    });
  });

  group('ZIP preflight and extraction', () {
    test(
      'installs a valid nested ZIP and ignores files outside its root',
      () async {
        final zip = await _writeZip(zipRoot, 'valid.zip', {
          'repository-main/plugin.json': _manifestBytes('valid.plugin'),
          'repository-main/src/home.js': utf8.encode('function execute() {}'),
          'third-party/dependency/plugin.json': _manifestBytes(
            'dependency.plugin',
          ),
          'README.md': utf8.encode('outside package root'),
        });

        final prepared = await PluginLoader.prepareInstallFromZipFile(
          zip,
          pluginsRoot: pluginsRoot,
        );

        expect(prepared.pluginId, 'valid.plugin');
        expect(
          await File(
            p.join(prepared.stagingDirectoryPath, 'plugin.json'),
          ).exists(),
          isTrue,
        );
        expect(
          await File(
            p.join(prepared.stagingDirectoryPath, 'README.md'),
          ).exists(),
          isFalse,
        );

        await prepared.commit();
        await prepared.complete();

        expect(
          await File(
            p.join(prepared.targetDirectoryPath, 'src', 'home.js'),
          ).exists(),
          isTrue,
        );
        expect(_transactionArtifacts(pluginsRoot), isEmpty);
      },
    );

    for (final entryPath in <String>[
      '../evil.js',
      'src/../../evil.js',
      '/absolute/evil.js',
      r'C:\absolute\evil.js',
    ]) {
      test('rejects unsafe entry path: $entryPath', () async {
        final zip = await _writeZip(zipRoot, 'unsafe.zip', {
          'plugin.json': _manifestBytes('safe.plugin'),
          entryPath: utf8.encode('malicious'),
        });

        await expectLater(
          PluginLoader.prepareInstallFromZipFile(zip, pluginsRoot: pluginsRoot),
          throwsA(_failure(PluginInstallFailure.unsafeEntryPath)),
        );

        expect(await File(p.join(sandbox.path, 'evil.js')).exists(), isFalse);
        expect(_transactionArtifacts(pluginsRoot), isEmpty);
      });
    }

    test('rejects an oversized ZIP before decoding it', () async {
      final zip = File(p.join(zipRoot.path, 'oversized.zip'));
      await zip.writeAsBytes(List<int>.filled(65, 1));

      await expectLater(
        PluginLoader.prepareInstallFromZipFile(
          zip,
          pluginsRoot: pluginsRoot,
          limits: const PluginArchiveLimits(maxZipBytes: 64),
        ),
        throwsA(_failure(PluginInstallFailure.archiveTooLarge)),
      );
    });

    test('rejects an archive with too many entries', () async {
      final zip = await _writeZip(zipRoot, 'entries.zip', {
        'plugin.json': _manifestBytes('entry.plugin'),
        'src/a.js': utf8.encode('a'),
        'src/b.js': utf8.encode('b'),
      });

      await expectLater(
        PluginLoader.prepareInstallFromZipFile(
          zip,
          pluginsRoot: pluginsRoot,
          limits: const PluginArchiveLimits(maxEntries: 2),
        ),
        throwsA(_failure(PluginInstallFailure.tooManyEntries)),
      );
    });

    test('rejects oversized individual and total expanded data', () async {
      final manifest = _manifestBytes('size.plugin');
      final zip = await _writeZip(zipRoot, 'expanded.zip', {
        'plugin.json': manifest,
        'src/large.js': List<int>.filled(200, 65),
      });

      await expectLater(
        PluginLoader.prepareInstallFromZipFile(
          zip,
          pluginsRoot: pluginsRoot,
          limits: const PluginArchiveLimits(maxEntryBytes: 150),
        ),
        throwsA(_failure(PluginInstallFailure.entryTooLarge)),
      );

      await expectLater(
        PluginLoader.prepareInstallFromZipFile(
          zip,
          pluginsRoot: pluginsRoot,
          limits: PluginArchiveLimits(
            maxEntryBytes: 1024,
            maxTotalUncompressedBytes: manifest.length + 100,
          ),
        ),
        throwsA(_failure(PluginInstallFailure.expandedArchiveTooLarge)),
      );
    });

    test('rejects a suspicious ZIP compression ratio', () async {
      final zip = await _writeZip(zipRoot, 'ratio.zip', {
        'plugin.json': _manifestBytes('ratio.plugin'),
        'src/repeated.js': List<int>.filled(8192, 65),
      });

      await expectLater(
        PluginLoader.prepareInstallFromZipFile(
          zip,
          pluginsRoot: pluginsRoot,
          limits: const PluginArchiveLimits(maxCompressionRatio: 2),
        ),
        throwsA(_failure(PluginInstallFailure.suspiciousCompressionRatio)),
      );
    });

    test('rejects a ZIP symbolic link entry', () async {
      final encoded = _encodeZip({
        'plugin.json': _manifestBytes('link.plugin'),
        'link': utf8.encode('../outside'),
      });
      _markCentralDirectoryEntryAsSymlink(encoded, 'link');
      final zip = File(p.join(zipRoot.path, 'symlink.zip'));
      await zip.writeAsBytes(encoded);

      await expectLater(
        PluginLoader.prepareInstallFromZipFile(zip, pluginsRoot: pluginsRoot),
        throwsA(_failure(PluginInstallFailure.symbolicLink)),
      );
    });
  });

  group('atomic installation transaction', () {
    test(
      'rollback restores an existing plugin and removes transaction dirs',
      () async {
        final existing = Directory(p.join(pluginsRoot.path, 'stable.plugin'));
        await existing.create(recursive: true);
        await File(p.join(existing.path, 'old.txt')).writeAsString('old');
        final zip = await _writeZip(zipRoot, 'update.zip', {
          'plugin.json': _manifestBytes('stable.plugin'),
          'new.txt': utf8.encode('new'),
        });

        final prepared = await PluginLoader.prepareInstallFromZipFile(
          zip,
          pluginsRoot: pluginsRoot,
        );
        expect(await File(p.join(existing.path, 'old.txt')).exists(), isTrue);

        await prepared.commit();
        expect(await File(p.join(existing.path, 'new.txt')).exists(), isTrue);
        expect(await File(p.join(existing.path, 'old.txt')).exists(), isFalse);

        await prepared.rollback();
        expect(await File(p.join(existing.path, 'old.txt')).exists(), isTrue);
        expect(await File(p.join(existing.path, 'new.txt')).exists(), isFalse);
        expect(_transactionArtifacts(pluginsRoot), isEmpty);
      },
    );

    test('restart removes an interrupted prepared staging directory', () async {
      const pluginId = 'prepared.plugin';
      final oldPlugin = _plugin(pluginId, version: 1);
      final newPlugin = _plugin(pluginId, version: 2);
      final existing = Directory(p.join(pluginsRoot.path, pluginId));
      await existing.create(recursive: true);
      await File(p.join(existing.path, 'old.txt')).writeAsString('old');
      final zip = await _writeZip(zipRoot, 'prepared-interruption.zip', {
        'plugin.json': _manifestBytes(pluginId, version: 2),
        'new.txt': utf8.encode('new'),
      });

      final prepared = await PluginLoader.prepareInstallFromZipFile(
        zip,
        pluginsRoot: pluginsRoot,
      );
      await prepared.recordExpectedInstalledPlugin(newPlugin.toJson());
      PluginLoader.forgetActiveTransactionsForTesting();

      final recovery = await PluginLoader.recoverInterruptedInstalls(
        pluginsRoot: pluginsRoot,
        installedPluginStates: {pluginId: oldPlugin.toJson()},
      );

      expect(recovery.finalizedTransactions, 0);
      expect(recovery.rolledBackTransactions, 1);
      expect(recovery.failedTransactions, 0);
      expect(await File(p.join(existing.path, 'old.txt')).exists(), isTrue);
      expect(await File(p.join(existing.path, 'new.txt')).exists(), isFalse);
      expect(await Directory(prepared.stagingDirectoryPath).exists(), isFalse);
      expect(_transactionArtifacts(pluginsRoot), isEmpty);
    });

    test(
      'restart restores backup when preferences still describe old plugin',
      () async {
        const pluginId = 'rollback-after-restart.plugin';
        final oldPlugin = _plugin(pluginId, version: 1);
        final newPlugin = _plugin(pluginId, version: 2);
        SharedPreferences.setMockInitialValues({
          'installed_plugins': jsonEncode([oldPlugin.toJson()]),
        });
        final existing = Directory(p.join(pluginsRoot.path, pluginId));
        await existing.create(recursive: true);
        await File(p.join(existing.path, 'old.txt')).writeAsString('old');
        final zip = await _writeZip(zipRoot, 'committed-old-prefs.zip', {
          'plugin.json': _manifestBytes(pluginId, version: 2),
          'new.txt': utf8.encode('new'),
        });

        final prepared = await PluginLoader.prepareInstallFromZipFile(
          zip,
          pluginsRoot: pluginsRoot,
        );
        await prepared.recordExpectedInstalledPlugin(newPlugin.toJson());
        await prepared.commit();
        PluginLoader.forgetActiveTransactionsForTesting();

        final installed = await ExtensionService.getInstalledPlugins(
          pluginsRoot: pluginsRoot,
        );

        expect(installed.single.version, 1);
        expect(await File(p.join(existing.path, 'old.txt')).exists(), isTrue);
        expect(await File(p.join(existing.path, 'new.txt')).exists(), isFalse);
        expect(_transactionArtifacts(pluginsRoot), isEmpty);
      },
    );

    test(
      'restart finalizes committed files when new preferences were saved',
      () async {
        const pluginId = 'finalize-after-restart.plugin';
        final newPlugin = _plugin(pluginId, version: 2);
        SharedPreferences.setMockInitialValues({
          'installed_plugins': jsonEncode([newPlugin.toJson()]),
        });
        final existing = Directory(p.join(pluginsRoot.path, pluginId));
        await existing.create(recursive: true);
        await File(p.join(existing.path, 'old.txt')).writeAsString('old');
        final zip = await _writeZip(zipRoot, 'committed-new-prefs.zip', {
          'plugin.json': _manifestBytes(pluginId, version: 2),
          'new.txt': utf8.encode('new'),
        });

        final prepared = await PluginLoader.prepareInstallFromZipFile(
          zip,
          pluginsRoot: pluginsRoot,
        );
        await prepared.recordExpectedInstalledPlugin(newPlugin.toJson());
        await prepared.commit();
        PluginLoader.forgetActiveTransactionsForTesting();

        final installed = await ExtensionService.getInstalledPlugins(
          pluginsRoot: pluginsRoot,
        );

        expect(installed.single.version, 2);
        expect(await File(p.join(existing.path, 'new.txt')).exists(), isTrue);
        expect(await File(p.join(existing.path, 'old.txt')).exists(), isFalse);
        expect(_transactionArtifacts(pluginsRoot), isEmpty);
      },
    );

    test('failed final engine load keeps old files and preferences', () async {
      const pluginId = 'stable.plugin';
      final oldPlugin = _plugin(pluginId, version: 1);
      final oldPrefs = jsonEncode([oldPlugin.toJson()]);
      SharedPreferences.setMockInitialValues({'installed_plugins': oldPrefs});
      final existing = Directory(p.join(pluginsRoot.path, pluginId));
      await existing.create(recursive: true);
      await File(p.join(existing.path, 'old.txt')).writeAsString('old');
      final zip = await _writeZip(zipRoot, 'engine-failure.zip', {
        'plugin.json': _manifestBytes(pluginId, version: 2),
        'new.txt': utf8.encode('new'),
      });
      final closedIds = <String>[];

      await expectLater(
        ExtensionService.installFromZipFile(
          zip,
          pluginsRoot: pluginsRoot,
          engineLoader: (id, _) async =>
              id.startsWith('vbook_install_validation_'),
          engineCloser: (id) async => closedIds.add(id),
        ),
        throwsA(isA<Exception>()),
      );

      expect(await File(p.join(existing.path, 'old.txt')).exists(), isTrue);
      expect(await File(p.join(existing.path, 'new.txt')).exists(), isFalse);
      expect(_transactionArtifacts(pluginsRoot), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('installed_plugins'), oldPrefs);
      expect(
        closedIds.any((id) => id.startsWith('vbook_install_validation_')),
        isTrue,
      );
      expect(closedIds, contains(pluginId));
    });

    test(
      'successful install commits before marking preferences installed',
      () async {
        final zip = await _writeZip(zipRoot, 'success.zip', {
          'plugin.json': _manifestBytes('success.plugin'),
          'src/home.js': utf8.encode('function execute() {}'),
        });

        final plugin = await ExtensionService.installFromZipFile(
          zip,
          pluginsRoot: pluginsRoot,
          engineLoader: (_, path) async =>
              File(p.join(path, 'plugin.json')).exists(),
          engineCloser: (_) async {},
        );

        expect(plugin.id, 'success.plugin');
        expect(
          await File(
            p.join(pluginsRoot.path, 'success.plugin', 'plugin.json'),
          ).exists(),
          isTrue,
        );
        final prefs = await SharedPreferences.getInstance();
        final installed =
            jsonDecode(prefs.getString('installed_plugins')!) as List<dynamic>;
        expect(installed.single['id'], 'success.plugin');
        expect(installed.single['isInstalled'], isTrue);
        expect(_transactionArtifacts(pluginsRoot), isEmpty);
      },
    );

    test('direct ZIP uses nested manifest metadata and a stable ID', () async {
      final zip = await _writeZip(zipRoot, 'nested-manifest.zip', {
        'plugin.json': _nestedManifestBytes('123ds'),
        'src/home.js': utf8.encode('function execute() {}'),
      });

      final plugin = await ExtensionService.installFromZipFile(
        zip,
        pluginsRoot: pluginsRoot,
        engineLoader: (_, path) async =>
            File(p.join(path, 'plugin.json')).exists(),
        engineCloser: (_) async {},
      );

      expect(plugin.id, '123ds');
      expect(plugin.name, '123ds');
      expect(plugin.author, 'B');
      expect(plugin.source, 'https://www.123duw.com');
      expect(plugin.description, contains('123duw.com'));
      expect(plugin.type, 'chinese_novel');
      expect(plugin.locale, 'zh_CN');
      expect(plugin.version, 3);
      expect(plugin.scripts['home'], 'home.js');
      expect(
        await File(p.join(pluginsRoot.path, '123ds', 'plugin.json')).exists(),
        isTrue,
      );
      expect(_transactionArtifacts(pluginsRoot), isEmpty);
    });

    test(
      'uninstall closes the engine, deletes files, then clears state',
      () async {
        const pluginId = 'remove.plugin';
        final plugin = _plugin(pluginId, version: 1);
        SharedPreferences.setMockInitialValues({
          'installed_plugins': jsonEncode([plugin.toJson()]),
        });
        final pluginDirectory = Directory(p.join(pluginsRoot.path, pluginId));
        await pluginDirectory.create(recursive: true);
        await File(
          p.join(pluginDirectory.path, 'plugin.json'),
        ).writeAsString('{}');
        final closedIds = <String>[];

        await ExtensionService.uninstallPlugin(
          pluginId,
          pluginsRoot: pluginsRoot,
          engineCloser: (id) async => closedIds.add(id),
        );

        expect(closedIds, [pluginId]);
        expect(await pluginDirectory.exists(), isFalse);
        final prefs = await SharedPreferences.getInstance();
        expect(jsonDecode(prefs.getString('installed_plugins')!), isEmpty);
      },
    );
  });
}

Matcher _failure(PluginInstallFailure failure) {
  return isA<PluginInstallException>().having(
    (error) => error.failure,
    'failure',
    failure,
  );
}

Future<File> _writeZip(
  Directory root,
  String name,
  Map<String, List<int>> entries,
) async {
  final file = File(p.join(root.path, name));
  await file.writeAsBytes(_encodeZip(entries));
  return file;
}

List<int> _encodeZip(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive)!;
}

List<int> _manifestBytes(String id, {int version = 1}) {
  return utf8.encode(
    jsonEncode({
      'id': id,
      'name': 'Test Plugin',
      'author': 'Test',
      'source': 'https://example.com',
      'type': 'novel',
      'locale': 'vi',
      'version': version,
    }),
  );
}

List<int> _nestedManifestBytes(String name) {
  return utf8.encode(
    jsonEncode({
      'metadata': {
        'name': name,
        'author': 'B',
        'version': 3,
        'source': 'https://www.123duw.com',
        'description': 'Đọc truyện trên trang https://www.123duw.com',
        'locale': 'zh_CN',
        'type': 'chinese_novel',
      },
      'script': {'home': 'home.js', 'detail': 'detail.js'},
    }),
  );
}

PluginInfo _plugin(String id, {required int version}) {
  return PluginInfo(
    id: id,
    name: 'Existing Plugin',
    author: 'Test',
    source: 'https://example.com',
    iconUrl: '',
    description: '',
    type: 'novel',
    locale: 'vi',
    version: version,
    downloadUrl: 'https://example.com/plugin.zip',
    isInstalled: true,
    installedVersion: version,
  );
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

void _markCentralDirectoryEntryAsSymlink(List<int> bytes, String filename) {
  const centralDirectorySignature = 0x02014b50;
  for (var offset = 0; offset <= bytes.length - 46; offset++) {
    final signature =
        bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
    if (signature != centralDirectorySignature) {
      continue;
    }

    final filenameLength = bytes[offset + 28] | (bytes[offset + 29] << 8);
    final entryName = utf8.decode(
      bytes.sublist(offset + 46, offset + 46 + filenameLength),
    );
    if (entryName != filename) {
      continue;
    }

    bytes[offset + 5] = 3;
    const symlinkMode = 0xA000 | 0x1FF;
    final externalAttributes = symlinkMode << 16;
    bytes[offset + 38] = externalAttributes & 0xFF;
    bytes[offset + 39] = (externalAttributes >> 8) & 0xFF;
    bytes[offset + 40] = (externalAttributes >> 16) & 0xFF;
    bytes[offset + 41] = (externalAttributes >> 24) & 0xFF;
    return;
  }
  throw StateError('Central directory entry not found: $filename');
}
