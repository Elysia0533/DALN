import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class PluginLoader {
  /// Downloads a plugin zip, extracts it, and returns the extracted directory path.
  static Future<String?> installPlugin(String url, String pluginId) async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final pluginsDir = Directory(p.join(docDir.path, 'vbook_plugins'));
      if (!await pluginsDir.exists()) {
        await pluginsDir.create(recursive: true);
      }

      final zipFile = File(p.join(pluginsDir.path, '$pluginId.zip'));

      print('Downloading plugin from: $url (ID: $pluginId)');
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      if (res.statusCode == 200) {
        await zipFile.writeAsBytes(res.bodyBytes);

        final result = await extractZipFile(zipFile, customId: pluginId);

        if (await zipFile.exists()) {
          await zipFile.delete();
        }

        if (result != null) {
          return result['dirPath'] as String;
        }
      } else {
        print('HTTP download error: ${res.statusCode} for $url');
      }
    } catch (e) {
      print('installPlugin error: $e');
    }
    return null;
  }

  static Future<String> getPluginDir(String pluginId) async {
    final docDir = await getApplicationDocumentsDirectory();
    final pluginsDir = Directory(p.join(docDir.path, 'vbook_plugins'));
    return p.join(pluginsDir.path, pluginId);
  }

  /// List all installed plugins
  static Future<List<String>> getInstalledPluginPaths() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final pluginsDir = Directory(p.join(docDir.path, 'vbook_plugins'));
      if (await pluginsDir.exists()) {
        final List<String> paths = [];
        await for (var entity in pluginsDir.list()) {
          if (entity is Directory) {
            paths.add(entity.path);
          }
        }
        return paths;
      }
    } catch (e) {
      print('getInstalledPluginPaths error: $e');
    }
    return [];
  }

  /// Extracts a local zip file and returns the target directory path and raw plugin.json map.
  static Future<Map<String, dynamic>?> extractZipFile(File zipFile, {String? customId}) async {
    try {
      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      ArchiveFile? jsonFile;
      String prefix = '';
      for (final file in archive) {
        if (file.name.endsWith('plugin.json')) {
          jsonFile = file;
          prefix = file.name.substring(0, file.name.length - 'plugin.json'.length);
          break;
        }
      }

      Map<String, dynamic>? pluginJsonMap;
      if (jsonFile != null) {
        final contentStr = String.fromCharCodes(jsonFile.content as List<int>);
        // Clean trailing commas if any
        final cleaned = contentStr.replaceAll(RegExp(r',(?=\s*[}\]])'), '');
        pluginJsonMap = jsonDecode(cleaned) as Map<String, dynamic>;
      }

      final pluginId = customId ?? (pluginJsonMap?['id']?.toString() ?? pluginJsonMap?['metadata']?['id']?.toString() ?? 'plugin_${DateTime.now().millisecondsSinceEpoch}');

      final docDir = await getApplicationDocumentsDirectory();
      final pluginsDir = Directory(p.join(docDir.path, 'vbook_plugins'));
      if (!await pluginsDir.exists()) {
        await pluginsDir.create(recursive: true);
      }

      final targetDir = Directory(p.join(pluginsDir.path, pluginId));
      if (await targetDir.exists()) {
        await targetDir.delete(recursive: true);
      }
      await targetDir.create(recursive: true);

      final targetCanonical = p.canonicalize(targetDir.path);

      for (final file in archive) {
        var filename = file.name;
        if (prefix.isNotEmpty && filename.startsWith(prefix)) {
          filename = filename.substring(prefix.length);
        }
        if (filename.isEmpty) continue;

        final outPath = p.join(targetDir.path, filename);
        final outCanonical = p.canonicalize(outPath);

        if (!outCanonical.startsWith(targetCanonical)) {
          print('Security warning: Skipped Zip Slip entry: $filename');
          continue;
        }

        if (file.isFile) {
          final data = file.content as List<int>;
          final outFile = File(outCanonical);
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(data);
        } else {
          await Directory(outCanonical).create(recursive: true);
        }
      }

      return {
        'pluginId': pluginId,
        'dirPath': targetDir.path,
        'jsonMap': pluginJsonMap,
      };
    } catch (e) {
      print('extractZipFile error: $e');
      rethrow;
    }
  }
}
