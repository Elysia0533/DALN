import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/plugin_info.dart';
import 'plugin/plugin_loader.dart';
import 'plugin/vbook_engine_channel.dart';

/// Service quản lý extension/plugin nguồn truyện online
class ExtensionService {
  static const String _defaultRegistryUrl =
      'https://raw.githubusercontent.com/dat-bi/ext-vbook/main/plugin.json';
  static const String _darkraiRegistryUrl =
      'https://raw.githubusercontent.com/Darkrai9x/vbook-extensions/master/plugin.json';
  static const String _prefsKeyInstalled = 'installed_plugins';
  static const String _prefsKeyRegistries = 'plugin_registries';

  /// Các registry được tích hợp sẵn (luôn có, không thể xóa)
  static const List<String> _builtinRegistries = [
    _defaultRegistryUrl,
    _darkraiRegistryUrl,
  ];

  // ── Fetch danh sách extension từ registry URL ──
  static Future<List<PluginInfo>> fetchRegistry({String? url}) async {
    final registryUrl = url ?? _defaultRegistryUrl;
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
        final plugin = PluginInfo.fromRegistryJson(item as Map<String, dynamic>, registryUrl: registryUrl);
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
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_prefsKeyRegistries) ?? [];
    if (!saved.contains(url) && !_builtinRegistries.contains(url)) {
      saved.add(url);
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
    final installed = await getInstalledPlugins();
    final idx = installed.indexWhere((p) => p.id == plugin.id);

    final zipUrl = plugin.downloadUrl.isNotEmpty ? plugin.downloadUrl : plugin.source;
    if (zipUrl.isEmpty || (!zipUrl.startsWith('http://') && !zipUrl.startsWith('https://'))) {
      throw Exception('URL tải extension không hợp lệ: "$zipUrl"');
    }

    debugPrint('[ExtensionService] installPlugin: downloading $zipUrl for plugin ${plugin.id}');
    final dirPath = await PluginLoader.installPlugin(zipUrl, plugin.id);
    if (dirPath == null) {
      throw Exception('Không thể tải hoặc giải nén extension');
    }

    // Verify plugin.json exists after extraction (basic sanity check)
    final pluginJsonFile = File('$dirPath/plugin.json');
    final srcDir = Directory('$dirPath/src');
    if (!pluginJsonFile.existsSync()) {
      // Check one level deeper (some zips have a single subfolder)
      final subDirs = Directory(dirPath).listSync().whereType<Directory>().toList();
      bool foundInSub = false;
      if (subDirs.length == 1) {
        final subPluginJson = File('${subDirs.first.path}/plugin.json');
        foundInSub = subPluginJson.existsSync();
      }
      if (!foundInSub) {
        debugPrint('[ExtensionService] plugin.json not found in $dirPath');
        // Don't throw - many valid extensions may have different structures
        // The native JsLoader handles various structures
      }
    }

    // Try loading into engine (non-blocking - will be retried when browsing)
    try {
      await VBookEngineChannel.loadSource(plugin.id.hashCode, dirPath);
    } catch (e) {
      debugPrint('[ExtensionService] Engine pre-load warning (non-fatal): $e');
    }

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

    if (idx >= 0) {
      installed[idx] = updatedPlugin;
    } else {
      installed.add(updatedPlugin);
    }

    await _saveInstalledPlugins(installed);
  }

  // ── Cài đặt plugin từ file ZIP cục bộ ──
  static Future<PluginInfo> installFromZipFile(File zipFile) async {
    final result = await PluginLoader.extractZipFile(zipFile);
    if (result == null) {
      throw Exception('Không thể giải nén file ZIP extension.');
    }

    final pluginId = result['pluginId'] as String;
    final dirPath = result['dirPath'] as String;
    final jsonMap = result['jsonMap'] as Map<String, dynamic>?;

    PluginInfo plugin;
    if (jsonMap != null) {
      plugin = PluginInfo.fromRegistryJson(jsonMap);
    } else {
      plugin = PluginInfo(
        id: pluginId,
        name: pluginId,
        author: 'Local',
        source: 'local_file',
        iconUrl: '',
        description: 'Extension cài thủ công từ file ZIP',
        type: 'novel',
        locale: 'vi',
        version: 1,
        downloadUrl: '',
        isNsfw: false,
        scripts: const {},
      );
    }

    // Try loading into engine (non-blocking)
    try {
      await VBookEngineChannel.loadSource(pluginId.hashCode, dirPath);
    } catch (e) {
      debugPrint('[ExtensionService] Engine pre-load warning (non-fatal): $e');
    }

    final installed = await getInstalledPlugins();
    plugin.isInstalled = true;
    plugin.installedVersion = plugin.version;

    installed.removeWhere((p) => p.id == pluginId);
    installed.add(plugin);
    await _saveInstalledPlugins(installed);

    return plugin;
  }

  // ── Cài đặt plugin từ URL file ZIP trực tiếp ──
  static Future<PluginInfo> installFromZipUrl(String zipUrl) async {
    final response = await http.get(Uri.parse(zipUrl)).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw Exception('Không thể tải file ZIP từ URL (HTTP ${response.statusCode})');
    }
    final tempDirPath = await PluginLoader.getPluginDir('_temp_download');
    final tempDir = Directory(tempDirPath);
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }
    final tempFile = File('${tempDir.path}/temp_plugin.zip');
    await tempFile.writeAsBytes(response.bodyBytes);
    final plugin = await installFromZipFile(tempFile);
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
    return plugin;
  }

  // ── Uninstall plugin ──
  static Future<void> uninstallPlugin(String pluginId) async {
    final installed = await getInstalledPlugins();
    installed.removeWhere((p) => p.id == pluginId);
    await _saveInstalledPlugins(installed);
  }

  // ── Get installed plugins ──
  static Future<List<PluginInfo>> getInstalledPlugins() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKeyInstalled);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((item) => PluginInfo.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  static Future<void> _saveInstalledPlugins(List<PluginInfo> plugins) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(plugins.map((p) => p.toJson()).toList());
    await prefs.setString(_prefsKeyInstalled, jsonStr);
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
        debugPrint('[ExtensionService] Error fetching $url: $e');
      }
    }

    return results;
  }
}
