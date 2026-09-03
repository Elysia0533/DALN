import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/plugin_info.dart';
import 'plugin/plugin_loader.dart';
import 'plugin/vbook_engine_channel.dart';

class ExtensionUrlValidationResult {
  final String url;
  final Uri? uri;
  final String? errorMessage;

  const ExtensionUrlValidationResult._({
    required this.url,
    required this.uri,
    required this.errorMessage,
  });

  bool get isValid => errorMessage == null;
  bool get isCleartext => uri?.scheme.toLowerCase() == 'http';
  String get host => uri?.host ?? '';
}

typedef PluginEngineLoader = Future<bool> Function(String id, String dirPath);
typedef PluginEngineCloser = Future<void> Function(String id);

/// Service quản lý extension/plugin nguồn truyện online
class ExtensionService {
  static const String _defaultRegistryUrl =
      'https://raw.githubusercontent.com/dat-bi/ext-vbook/main/plugin.json';
  static const String _darkraiRegistryUrl =
      'https://raw.githubusercontent.com/Darkrai9x/vbook-extensions/master/plugin.json';
  static const String _prefsKeyInstalled = 'installed_plugins';
  static const String _prefsKeyRegistries = 'plugin_registries';
  static int _installValidationSequence = 0;

  /// Các registry được tích hợp sẵn (luôn có, không thể xóa)
  static const List<String> _builtinRegistries = [
    _defaultRegistryUrl,
    _darkraiRegistryUrl,
  ];

  // ── Fetch danh sách extension từ registry URL ──
  static ExtensionUrlValidationResult validateUserProvidedUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return const ExtensionUrlValidationResult._(
        url: '',
        uri: null,
        errorMessage: 'URL khong duoc de trong.',
      );
    }

    if (RegExp(r'\s').hasMatch(trimmed)) {
      return ExtensionUrlValidationResult._(
        url: trimmed,
        uri: null,
        errorMessage: 'URL khong hop le. Hay encode khoang trang neu can.',
      );
    }

    final Uri uri;
    try {
      uri = Uri.parse(trimmed);
    } on FormatException {
      return ExtensionUrlValidationResult._(
        url: trimmed,
        uri: null,
        errorMessage: 'URL khong dung dinh dang.',
      );
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return ExtensionUrlValidationResult._(
        url: trimmed,
        uri: uri,
        errorMessage: 'Chi ho tro URL http:// hoac https://.',
      );
    }

    if (!uri.hasAuthority || uri.host.isEmpty) {
      return ExtensionUrlValidationResult._(
        url: trimmed,
        uri: uri,
        errorMessage: 'URL phai co host hop le.',
      );
    }

    if (uri.userInfo.isNotEmpty) {
      return ExtensionUrlValidationResult._(
        url: trimmed,
        uri: uri,
        errorMessage: 'Khong duoc nhap URL co username hoac password.',
      );
    }

    return ExtensionUrlValidationResult._(
      url: trimmed,
      uri: uri,
      errorMessage: null,
    );
  }

  static String _validatedUrlOrThrow(String input) {
    final validation = validateUserProvidedUrl(input);
    if (!validation.isValid) {
      throw Exception(validation.errorMessage);
    }
    return validation.url;
  }

  static Future<List<PluginInfo>> fetchRegistry({String? url}) async {
    final registryUrl = _validatedUrlOrThrow(url ?? _defaultRegistryUrl);
    try {
      final response = await http
          .get(Uri.parse(registryUrl))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;

      // Registry vBook dùng cấu trúc {"metadata": {...}, "data": [...]}
      final List<dynamic> dataList;
      if (json.containsKey('data')) {
        dataList = json['data'] as List<dynamic>;
      } else if (json.containsKey('plugins')) {
        dataList = json['plugins'] as List<dynamic>;
      } else {
        throw Exception('Định dạng registry không hợp lệ');
      }

      final installedPlugins = await getInstalledPlugins();
      final installedMap = {for (final p in installedPlugins) p.id: p};

      return dataList.map((item) {
        final plugin = PluginInfo.fromRegistryJson(
          item as Map<String, dynamic>,
          registryUrl: registryUrl,
        );
        final installed = installedMap[plugin.id];
        if (installed != null) {
          plugin.isInstalled = true;
          plugin.installedVersion = installed.installedVersion;
        }
        return plugin;
      }).toList();
    } catch (e) {
      debugPrint('[ExtensionService] fetchRegistry error: $e');
      rethrow;
    }
  }

  // ── Lưu danh sách registry URL ──
  static Future<List<String>> getRegistryUrls() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_prefsKeyRegistries) ?? [];
    // Luôn đảm bảo các built-in registry có mặt trong danh sách
    final merged = <String>{..._builtinRegistries, ...saved}.toList();
    return merged;
  }

  static Future<void> addRegistryUrl(String url) async {
    final registryUrl = _validatedUrlOrThrow(url);
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_prefsKeyRegistries) ?? [];
    if (!saved.contains(registryUrl) &&
        !_builtinRegistries.contains(registryUrl)) {
      saved.add(registryUrl);
      await prefs.setStringList(_prefsKeyRegistries, saved);
    }
  }

  static Future<void> removeRegistryUrl(String url) async {
    if (_builtinRegistries.contains(url)) return; // Không xóa built-in
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_prefsKeyRegistries) ?? [];
    saved.remove(url);
    await prefs.setStringList(_prefsKeyRegistries, saved);
  }

  // ── Install plugin ──
  static Future<void> installPlugin(PluginInfo plugin) async {
    PluginLoader.validatePluginId(plugin.id);
    final installed = await getInstalledPlugins();

    final zipUrl = _validatedUrlOrThrow(
      plugin.downloadUrl.isNotEmpty ? plugin.downloadUrl : plugin.source,
    );

    debugPrint(
      '[ExtensionService] installPlugin: downloading plugin ${plugin.id}',
    );
    final prepared = await PluginLoader.prepareInstallFromUrl(
      zipUrl,
      customId: plugin.id,
    );

    final updatedPlugin = PluginInfo(
      id: plugin.id,
      name: plugin.name,
      author: plugin.author,
      source: plugin.source,
      iconUrl: plugin.iconUrl,
      description: plugin.description,
      type: plugin.type,
      locale: plugin.locale,
      version: plugin.version,
      isNsfw: plugin.isNsfw,
      downloadUrl: plugin.downloadUrl,
      scripts: plugin.scripts,
      isInstalled: true,
      installedVersion: plugin.version,
    );
    await _installPreparedPlugin(
      prepared: prepared,
      plugin: updatedPlugin,
      installedPlugins: installed,
    );
  }

  // ── Cài đặt plugin từ file ZIP cục bộ ──
  static Future<PluginInfo> installFromZipFile(
    File zipFile, {
    Directory? pluginsRoot,
    PluginArchiveLimits limits = PluginLoader.defaultArchiveLimits,
    PluginEngineLoader? engineLoader,
    PluginEngineCloser? engineCloser,
  }) async {
    final installed = await getInstalledPlugins(pluginsRoot: pluginsRoot);
    final prepared = await PluginLoader.prepareInstallFromZipFile(
      zipFile,
      pluginsRoot: pluginsRoot,
      limits: limits,
    );
    return _installPreparedLocalPlugin(
      prepared,
      installedPlugins: installed,
      engineLoader: engineLoader,
      engineCloser: engineCloser,
    );
  }

  // ── Cài đặt plugin từ URL file ZIP trực tiếp ──
  static Future<PluginInfo> installFromZipUrl(
    String zipUrl, {
    Directory? pluginsRoot,
    Directory? temporaryRoot,
    PluginArchiveLimits limits = PluginLoader.defaultArchiveLimits,
    PluginEngineLoader? engineLoader,
    PluginEngineCloser? engineCloser,
    http.Client? client,
  }) async {
    final validatedZipUrl = _validatedUrlOrThrow(zipUrl);
    final installed = await getInstalledPlugins(pluginsRoot: pluginsRoot);
    final prepared = await PluginLoader.prepareInstallFromUrl(
      validatedZipUrl,
      pluginsRoot: pluginsRoot,
      temporaryRoot: temporaryRoot,
      limits: limits,
      client: client,
    );
    return _installPreparedLocalPlugin(
      prepared,
      installedPlugins: installed,
      engineLoader: engineLoader,
      engineCloser: engineCloser,
    );
  }

  static Future<PluginInfo> _installPreparedLocalPlugin(
    PreparedPluginInstall prepared, {
    required List<PluginInfo> installedPlugins,
    PluginEngineLoader? engineLoader,
    PluginEngineCloser? engineCloser,
  }) async {
    try {
      final parsed = PluginInfo.fromRegistryJson(prepared.pluginJson);
      final plugin = PluginInfo(
        id: prepared.pluginId,
        name: parsed.name.isEmpty ? prepared.pluginId : parsed.name,
        author: parsed.author,
        source: parsed.source.isEmpty ? 'local_file' : parsed.source,
        iconUrl: parsed.iconUrl,
        description: parsed.description.isEmpty
            ? 'Extension cài thủ công từ file ZIP'
            : parsed.description,
        type: parsed.type,
        locale: parsed.locale,
        version: parsed.version,
        downloadUrl: parsed.downloadUrl,
        isNsfw: parsed.isNsfw,
        scripts: parsed.scripts,
        isInstalled: true,
        installedVersion: parsed.version,
      );
      await _installPreparedPlugin(
        prepared: prepared,
        plugin: plugin,
        installedPlugins: installedPlugins,
        engineLoader: engineLoader,
        engineCloser: engineCloser,
      );
      return plugin;
    } catch (_) {
      if (!prepared.isCompleted) {
        await prepared.rollback();
      }
      rethrow;
    }
  }

  static Future<void> _installPreparedPlugin({
    required PreparedPluginInstall prepared,
    required PluginInfo plugin,
    required List<PluginInfo> installedPlugins,
    PluginEngineLoader? engineLoader,
    PluginEngineCloser? engineCloser,
  }) async {
    if (prepared.pluginId != plugin.id) {
      await prepared.rollback();
      throw const PluginInstallException(
        PluginInstallFailure.invalidPluginId,
        'ID extension trong giao dịch cài đặt không khớp.',
      );
    }

    final loadSource = engineLoader ?? VBookEngineChannel.loadSource;
    final closeSource = engineCloser ?? VBookEngineChannel.closeSource;
    final validationId =
        'vbook_install_validation_${DateTime.now().microsecondsSinceEpoch}_${_installValidationSequence++}';

    try {
      await prepared.recordExpectedInstalledPlugin(plugin.toJson());
      final stagingLoaded = await loadSource(
        validationId,
        prepared.stagingDirectoryPath,
      );
      if (!stagingLoaded) {
        throw Exception(
          'Không thể xác thực extension engine cho "${plugin.name}".',
        );
      }
    } catch (error) {
      await prepared.rollback();
      throw Exception(
        'Không thể xác thực extension engine cho "${plugin.name}": ${_cleanError(error)}',
      );
    } finally {
      await closeSource(validationId);
    }

    var finalLoadAttempted = false;
    try {
      await prepared.commit();
      finalLoadAttempted = true;
      final loaded = await loadSource(plugin.id, prepared.targetDirectoryPath);
      if (!loaded) {
        throw Exception(
          'Không thể khởi tạo extension engine cho "${plugin.name}".',
        );
      }

      final nextInstalled = List<PluginInfo>.from(installedPlugins);
      final existingIndex = nextInstalled.indexWhere(
        (installed) => installed.id == plugin.id,
      );
      if (existingIndex >= 0) {
        nextInstalled[existingIndex] = plugin;
      } else {
        nextInstalled.add(plugin);
      }
      await _saveInstalledPlugins(nextInstalled);
    } catch (error) {
      if (finalLoadAttempted) {
        await closeSource(plugin.id);
      }

      Object? rollbackError;
      try {
        await prepared.rollback();
      } catch (caughtRollbackError) {
        rollbackError = caughtRollbackError;
      }

      if (prepared.hadExistingPlugin &&
          await Directory(prepared.targetDirectoryPath).exists()) {
        try {
          await loadSource(plugin.id, prepared.targetDirectoryPath);
        } catch (restoreError) {
          debugPrint(
            '[ExtensionService] Could not reload previous plugin ${plugin.id}: ${_cleanError(restoreError)}',
          );
        }
      }

      final rollbackMessage = rollbackError == null
          ? ''
          : ' Không thể rollback hoàn toàn: ${_cleanError(rollbackError)}';
      throw Exception('${_cleanError(error)}$rollbackMessage');
    }

    try {
      await prepared.complete();
    } catch (error) {
      debugPrint(
        '[ExtensionService] Installed ${plugin.id}, but backup cleanup failed: ${_cleanError(error)}',
      );
    }
  }

  static String _cleanError(Object error) {
    return error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
  }

  // ── Uninstall plugin ──
  static Future<void> uninstallPlugin(
    String pluginId, {
    Directory? pluginsRoot,
    PluginEngineCloser? engineCloser,
  }) async {
    final safePluginId = PluginLoader.validatePluginId(pluginId);
    final installed = await getInstalledPlugins(pluginsRoot: pluginsRoot);
    final closeSource = engineCloser ?? VBookEngineChannel.closeSource;

    await closeSource(safePluginId);
    await PluginLoader.deletePlugin(safePluginId, pluginsRoot: pluginsRoot);
    installed.removeWhere((p) => p.id == safePluginId);
    await _saveInstalledPlugins(installed);
  }

  // ── Get installed plugins ──
  static Future<List<PluginInfo>> getInstalledPlugins({
    Directory? pluginsRoot,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKeyInstalled);
    var installed = <PluginInfo>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        installed = list
            .map((item) => PluginInfo.fromJson(item as Map<String, dynamic>))
            .toList();
      } catch (_) {
        installed = <PluginInfo>[];
      }
    }

    try {
      final recovery = await PluginLoader.recoverInterruptedInstalls(
        pluginsRoot: pluginsRoot,
        installedPluginStates: {
          for (final plugin in installed) plugin.id: plugin.toJson(),
        },
      );
      if (recovery.hasFailures) {
        debugPrint(
          '[ExtensionService] ${recovery.failedTransactions} interrupted '
          'extension transaction(s) still require attention.',
        );
      }
    } catch (error) {
      debugPrint(
        '[ExtensionService] Extension recovery could not start '
        '(${error.runtimeType}).',
      );
    }
    return installed;
  }

  static Future<void> _saveInstalledPlugins(List<PluginInfo> plugins) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(plugins.map((p) => p.toJson()).toList());
    final saved = await prefs.setString(_prefsKeyInstalled, jsonStr);
    if (!saved) {
      throw Exception('Không thể lưu trạng thái extension đã cài đặt.');
    }
  }

  // ── Fetch tất cả registry (multi-source) ──
  static Future<List<PluginInfo>> fetchAllRegistries() async {
    final urls = await getRegistryUrls();
    final results = <PluginInfo>[];
    final seen = <String>{};

    for (final url in urls) {
      try {
        final plugins = await fetchRegistry(url: url);
        for (final p in plugins) {
          if (!seen.contains(p.id)) {
            seen.add(p.id);
            results.add(p);
          }
        }
      } catch (e) {
        debugPrint('[ExtensionService] Error fetching registry: $e');
      }
    }

    return results;
  }
}
