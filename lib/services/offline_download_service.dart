import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/plugin_info.dart';
import '../models/source_models.dart';
import '../services/plugin/vbook_engine_channel.dart';
import '../services/plugin/plugin_loader.dart';
import 'epub_export_service.dart';

class DownloadItem {
  final String pluginId;
  final String storyTitle;
  final String chapterUrl;
  final String chapterTitle;
  final int chapterIndex;

  const DownloadItem({
    required this.pluginId,
    required this.storyTitle,
    required this.chapterUrl,
    required this.chapterTitle,
    required this.chapterIndex,
  });
}

enum DownloadStatus { idle, downloading, paused, completed, error }

class OfflineDownloadService extends ChangeNotifier {
  static final OfflineDownloadService instance = OfflineDownloadService._internal();
  factory OfflineDownloadService() => instance;

  OfflineDownloadService._internal();

  DownloadStatus _status = DownloadStatus.idle;
  DownloadStatus get status => _status;

  String _storyTitle = '';
  String get storyTitle => _storyTitle;

  int _totalChapters = 0;
  int get totalChapters => _totalChapters;

  int _downloadedCount = 0;
  int get downloadedCount => _downloadedCount;

  final List<int> _failedChapterIndices = [];
  List<int> get failedChapterIndices => List.unmodifiable(_failedChapterIndices);
  int get failedCount => _failedChapterIndices.length;

  String _currentDownloadingTitle = '';
  String get currentDownloadingTitle => _currentDownloadingTitle;

  double get progress => _totalChapters > 0 ? (_downloadedCount / _totalChapters) : 0.0;

  bool _shouldCancel = false;

  Future<Directory> get _offlineBaseDir async {
    Directory? dir;
    if (Platform.isAndroid) {
      final publicDir = Directory('/storage/emulated/0/Download/VBook');
      try {
        if (!await publicDir.exists()) {
          await publicDir.create(recursive: true);
        }
        dir = publicDir;
      } catch (_) {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) {
          dir = Directory('${extDir.path}/VBookDownloads');
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
        }
      }
    }

    if (dir == null) {
      final appDir = await getApplicationDocumentsDirectory();
      dir = Directory('${appDir.path}/VBookDownloads');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }
    return dir;
  }

  Future<String> get publicStoragePath async {
    final dir = await _offlineBaseDir;
    return dir.path;
  }

  String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  /// Scan storage and get list of downloaded stories
  Future<List<Map<String, dynamic>>> getDownloadedStories() async {
    final baseDir = await _offlineBaseDir;
    if (!await baseDir.exists()) return [];

    final List<Map<String, dynamic>> results = [];
    final entities = baseDir.listSync();

    for (final entity in entities) {
      if (entity is Directory) {
        final jsonFiles = entity.listSync().where((f) => f.path.endsWith('.json')).toList();
        if (jsonFiles.isNotEmpty) {
          String title = entity.path.split('/').last;
          String pluginId = 'vbook';
          final firstJson = jsonFiles.first;
          if (firstJson is File) {
            try {
              final content = jsonDecode(firstJson.readAsStringSync());
              title = content['storyTitle'] ?? title;
              pluginId = content['pluginId'] ?? pluginId;
            } catch (_) {}
          }
          results.add({
            'folderPath': entity.path,
            'storyTitle': title,
            'pluginId': pluginId,
            'chapterCount': jsonFiles.length,
          });
        }
      }
    }
    return results;
  }

  /// Delete a downloaded story folder
  Future<void> deleteDownloadedStory(String folderPath) async {
    final dir = Directory(folderPath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      notifyListeners();
    }
  }

  Future<bool> isChapterDownloaded(String pluginId, String storyTitle, int chapterIndex) async {
    final baseDir = await _offlineBaseDir;
    final storyFolder = Directory('${baseDir.path}/${_sanitizeFileName(pluginId)}_${_sanitizeFileName(storyTitle)}');
    final file = File('${storyFolder.path}/chap_$chapterIndex.json');
    return await file.exists();
  }

  Future<String?> getDownloadedChapterContent(String pluginId, String storyTitle, int chapterIndex) async {
    final baseDir = await _offlineBaseDir;
    final storyFolder = Directory('${baseDir.path}/${_sanitizeFileName(pluginId)}_${_sanitizeFileName(storyTitle)}');
    final file = File('${storyFolder.path}/chap_$chapterIndex.json');
    if (await file.exists()) {
      final jsonStr = await file.readAsString();
      final map = jsonDecode(jsonStr);
      return map['content'] as String?;
    }
    return null;
  }

  Future<void> startBatchDownload({
    required PluginInfo plugin,
    required String storyTitle,
    required List<Map<String, String>> chapters, // [{ 'url': ..., 'name': ... }]
    int startFrom = 0,
  }) async {
    _status = DownloadStatus.downloading;
    _shouldCancel = false;
    _storyTitle = storyTitle;
    _totalChapters = chapters.length;
    _downloadedCount = 0;
    _failedChapterIndices.clear();
    notifyListeners();

    final baseDir = await _offlineBaseDir;
    final storyFolder = Directory('${baseDir.path}/${_sanitizeFileName(plugin.id)}_${_sanitizeFileName(storyTitle)}');
    if (!await storyFolder.exists()) {
      await storyFolder.create(recursive: true);
    }

    try {
      final dirPath = await PluginLoader.getPluginDir(plugin.id);
      await VBookEngineChannel.loadSource(plugin.id.hashCode, dirPath);

      // Count valid non-empty downloaded files first
      int alreadyDownloaded = 0;
      for (int i = 0; i < chapters.length; i++) {
        final file = File('${storyFolder.path}/chap_$i.json');
        if (await file.exists()) {
          try {
            final jsonStr = await file.readAsString();
            final map = jsonDecode(jsonStr);
            final content = map['content'] as String? ?? '';
            if (content.trim().isNotEmpty) {
              alreadyDownloaded++;
            } else {
              // Delete corrupted / empty chapter file
              await file.delete();
            }
          } catch (_) {
            await file.delete();
          }
        }
      }

      _downloadedCount = alreadyDownloaded;
      notifyListeners();

      for (int i = startFrom; i < chapters.length; i++) {
        if (_shouldCancel) {
          _status = DownloadStatus.idle;
          notifyListeners();
          return;
        }

        final chap = chapters[i];
        final url = chap['url'] ?? '';
        final title = chap['name'] ?? 'Chương ${i + 1}';
        _currentDownloadingTitle = title;
        notifyListeners();

        final file = File('${storyFolder.path}/chap_$i.json');
        
        bool hasValidContent = false;
        if (await file.exists()) {
          try {
            final jsonStr = await file.readAsString();
            final map = jsonDecode(jsonStr);
            final content = map['content'] as String? ?? '';
            if (content.trim().isNotEmpty) {
              hasValidContent = true;
            } else {
              await file.delete();
            }
          } catch (_) {
            await file.delete();
          }
        }

        if (!hasValidContent) {
          String rawContent = '';
          int attempts = 0;

          // Attempt fetching with up to 3 retries and adaptive delay
          while (attempts < 3 && rawContent.isEmpty) {
            attempts++;
            if (_shouldCancel) break;

            try {
              final pages = await VBookEngineChannel.getPageList(plugin.id.hashCode, url);
              if (pages != null && pages.isNotEmpty) {
                if (pages.length > 1) {
                  // Comic multiple images
                  final pageUrls = pages.map((p) => p.imageUrl.isNotEmpty ? p.imageUrl : p.url).toList();
                  rawContent = jsonEncode(pageUrls);
                } else {
                  // Novel text
                  var text = pages.first.imageUrl;
                  if (text.startsWith('vbook-text://')) {
                    text = text.substring(13);
                  }
                  rawContent = EpubExportService.cleanTextForEpub(text);
                }
              }
            } catch (e) {
              debugPrint('Lỗi tải chương $i (Thử $attempts): $e');
            }

            if (rawContent.isEmpty && attempts < 3) {
              await Future.delayed(Duration(milliseconds: 800 * attempts));
            }
          }

          if (rawContent.isNotEmpty) {
            final dataMap = {
              'pluginId': plugin.id,
              'storyTitle': storyTitle,
              'chapterTitle': title,
              'chapterIndex': i,
              'chapterUrl': url,
              'content': rawContent,
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            };
            await file.writeAsString(jsonEncode(dataMap));
            _downloadedCount++;
            notifyListeners();
          } else {
            _failedChapterIndices.add(i);
            debugPrint('Bỏ qua chương $i do server không trả về nội dung sau 3 lần thử.');
          }
        }

        // Polite delay between requests to prevent server 429 rate limiting
        await Future.delayed(const Duration(milliseconds: 400));
      }

      if (_failedChapterIndices.isNotEmpty) {
        _status = DownloadStatus.error;
      } else {
        _status = DownloadStatus.completed;
      }
      notifyListeners();
    } catch (e) {
      _status = DownloadStatus.error;
      notifyListeners();
    }
  }

  void cancelDownload() {
    _shouldCancel = true;
    _status = DownloadStatus.idle;
    notifyListeners();
  }

  /// 📦 Export downloaded story to TXT file
  Future<File?> exportToTxt(String pluginId, String storyTitle, int totalChaps) async {
    final baseDir = await _offlineBaseDir;
    final storyFolder = Directory('${baseDir.path}/${_sanitizeFileName(pluginId)}_${_sanitizeFileName(storyTitle)}');
    if (!await storyFolder.exists()) return null;

    final downloadsDir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final exportFile = File('${downloadsDir.path}/${_sanitizeFileName(storyTitle)}.txt');
    final sink = exportFile.openWrite();

    sink.writeln('==================================================');
    sink.writeln(storyTitle);
    sink.writeln('Nguồn: vBook Extension ($pluginId)');
    sink.writeln('==================================================\n');

    for (int i = 0; i < totalChaps; i++) {
      final file = File('${storyFolder.path}/chap_$i.json');
      if (await file.exists()) {
        try {
          final jsonStr = await file.readAsString();
          final map = jsonDecode(jsonStr);
          final content = map['content'] as String? ?? '';
          if (content.trim().isNotEmpty) {
            sink.writeln('\n--- ${map['chapterTitle']} ---\n');
            sink.writeln(content);
          }
        } catch (_) {}
      }
    }
    await sink.flush();
    await sink.close();
    return exportFile;
  }

  /// 📦 Export downloaded story to EPUB file
  Future<File?> exportToEpub(String pluginId, String storyTitle, int totalChaps, {String author = 'VBook Source'}) async {
    final baseDir = await _offlineBaseDir;
    final storyFolder = Directory('${baseDir.path}/${_sanitizeFileName(pluginId)}_${_sanitizeFileName(storyTitle)}');
    if (!await storyFolder.exists()) return null;

    final List<Map<String, String>> chapters = [];
    for (int i = 0; i < totalChaps; i++) {
      final file = File('${storyFolder.path}/chap_$i.json');
      if (await file.exists()) {
        try {
          final jsonStr = await file.readAsString();
          final map = jsonDecode(jsonStr);
          final title = map['chapterTitle'] as String? ?? 'Chương ${i + 1}';
          final content = map['content'] as String? ?? '';
          
          if (content.trim().isNotEmpty) {
            chapters.add({
              'title': title,
              'content': content,
            });
          }
        } catch (_) {}
      }
    }

    if (chapters.isEmpty) return null;

    return await EpubExportService.instance.exportToEpub(
      storyTitle: storyTitle,
      author: author,
      chapters: chapters,
    );
  }
}
