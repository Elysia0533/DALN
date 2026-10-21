import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../models/online_chapter_content.dart';
import '../models/plugin_info.dart';
import '../models/source_models.dart';
import '../services/plugin/vbook_engine_channel.dart';
import '../services/plugin/plugin_loader.dart';
import 'epub_export_service.dart';
import 'book_file_names.dart';
import 'chapter_image_service.dart';
import 'offline_chapter_store.dart';

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
  static final OfflineDownloadService instance =
      OfflineDownloadService._internal();
  factory OfflineDownloadService() => instance;

  OfflineDownloadService._internal();

  @visibleForTesting
  OfflineDownloadService.forTesting({
    required Directory directory,
    required Future<List<Page>> Function(String, String) loadPages,
    required Future<bool> Function(PluginInfo) prepareSource,
    required ChapterImageLoader loadImage,
  }) {
    _directoryOverride = directory;
    _loadPages = loadPages;
    _prepareSource = prepareSource;
    _loadImage = loadImage;
    _requestDelay = Duration.zero;
  }

  Directory? _directoryOverride;
  Future<List<Page>> Function(String, String) _loadPages =
      VBookEngineChannel.getPageList;
  ChapterImageLoader _loadImage = ChapterImageService.load;
  Future<bool> Function(PluginInfo)? _prepareSource;
  static int _sessionSequence = 0;
  Duration _requestDelay = const Duration(milliseconds: 1200);
  bool _isRunning = false;
  PluginInfo? _lastPlugin;
  List<Map<String, String>> _lastChapters = const [];
  String? _lastStoryUrl;
  bool get canRetry => !_isRunning && _lastPlugin != null;

  DownloadStatus _status = DownloadStatus.idle;
  DownloadStatus get status => _status;

  String _storyTitle = '';
  String get storyTitle => _storyTitle;

  int _totalChapters = 0;
  int get totalChapters => _totalChapters;

  int _downloadedCount = 0;
  int get downloadedCount => _downloadedCount;

  final List<int> _failedChapterIndices = [];
  List<int> get failedChapterIndices =>
      List.unmodifiable(_failedChapterIndices);
  int get failedCount => _failedChapterIndices.length;

  String _currentDownloadingTitle = '';
  String get currentDownloadingTitle => _currentDownloadingTitle;

  String _errorMessage = '';
  String get errorMessage => _errorMessage;

  double get progress =>
      _totalChapters > 0 ? (_downloadedCount / _totalChapters) : 0.0;

  bool _shouldCancel = false;

  Future<Directory> get _offlineBaseDir async {
    if (_directoryOverride case final Directory directory) return directory;
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
    return BookFileNames.stem(name);
  }

  Future<Directory> _getStoryFolder(
    String pluginId,
    String storyTitle, {
    bool createIfMissing = false,
    String? storyUrl,
  }) async {
    final baseDir = await _offlineBaseDir;
    final sanitizedTitle = _sanitizeFileName(storyTitle);
    final sanitizedPlugin = _sanitizeFileName(pluginId);

    final identity = sha256
        .convert(
          utf8.encode(
            '$pluginId\u0000${storyUrl?.trim().isNotEmpty == true ? storyUrl : storyTitle}',
          ),
        )
        .toString()
        .substring(0, 12);
    final cleanFolder = Directory(
      p.join(baseDir.path, '$sanitizedTitle [$identity]'),
    );
    for (final candidate in [
      cleanFolder,
      Directory(p.join(baseDir.path, sanitizedTitle)),
      Directory(p.join(baseDir.path, '${sanitizedPlugin}_$sanitizedTitle')),
    ]) {
      if (await FileSystemEntity.type(candidate.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      final data = await _readInfo(candidate);
      if (data != null &&
          data['pluginId'] == pluginId &&
          data['storyTitle'] == storyTitle &&
          (storyUrl == null ||
              data['storyUrl'] == null ||
              data['storyUrl'] == storyUrl)) {
        return candidate;
      }
    }
    final matches = <Directory>[];
    if (await baseDir.exists()) {
      await for (final candidate in baseDir.list(followLinks: false)) {
        if (candidate is! Directory) continue;
        final data = await _readInfo(candidate);
        if (data != null &&
            data['pluginId'] == pluginId &&
            data['storyTitle'] == storyTitle &&
            (storyUrl == null || data['storyUrl'] == storyUrl)) {
          matches.add(candidate);
        }
      }
    }
    if (matches.length == 1) return matches.single;
    if (matches.length > 1) {
      throw const FileSystemException(
        'Có nhiều truyện cùng tên. Hãy mở từ đúng nguồn truyện.',
      );
    }
    if (await FileSystemEntity.type(cleanFolder.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FileSystemException(
        'Thư mục truyện không khớp dữ liệu đã lưu.',
      );
    }
    if (createIfMissing) {
      await cleanFolder.create(recursive: true);
    }
    return cleanFolder;
  }

  Future<List<int>> _chapterIndices(Directory folder) async {
    if (!await folder.exists()) return [];
    final indices = <int>[];
    await for (final entry in folder.list(followLinks: false)) {
      if (entry is! File) continue;
      final match = RegExp(
        r'^chap_(\d+)\.json$',
      ).firstMatch(p.basename(entry.path));
      final index = match == null ? null : int.tryParse(match[1]!);
      if (index != null && index >= 0) indices.add(index);
    }
    indices.sort();
    return indices;
  }

  Future<Map<String, dynamic>?> _readInfo(Directory folder) async {
    try {
      var file = File(p.join(folder.path, 'story_info.json'));
      if (!await file.exists()) {
        final indices = await _chapterIndices(folder);
        if (indices.isEmpty) return null;
        file = File(p.join(folder.path, 'chap_${indices.first}.json'));
      }
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          !p.isWithin(
            await folder.resolveSymbolicLinks(),
            await file.resolveSymbolicLinks(),
          ) ||
          await file.length() > 8 * 1024 * 1024) {
        return null;
      }
      final data = jsonDecode(await file.readAsString());
      if (data is! Map<String, dynamic> ||
          data['pluginId'] is! String ||
          data['storyTitle'] is! String) {
        return null;
      }
      return data;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getDownloadedStories() async {
    final baseDir = await _offlineBaseDir;
    if (!await baseDir.exists()) return [];
    final results = <Map<String, dynamic>>[];
    await for (final entity in baseDir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final info = await _readInfo(entity);
      if (info == null) continue;
      final indices = await _chapterIndices(entity);
      final complete = <int>[];
      for (final index in indices) {
        if (await OfflineChapterStore.isComplete(entity, index)) {
          complete.add(index);
        }
      }
      final rawChapters = info['chapters'];
      final chapters = <Map<String, String>>[];
      if (rawChapters is List) {
        for (final entry in rawChapters) {
          chapters.add({
            'url': entry is Map && entry['url'] is String
                ? entry['url'] as String
                : '',
            'name': entry is Map && entry['name'] is String
                ? entry['name'] as String
                : 'Chương ${chapters.length + 1}',
          });
        }
      }
      if (chapters.isEmpty && indices.isNotEmpty) {
        // Older downloads did not persist a TOC. Keep original chapter indices.
        for (var index = 0; index <= indices.last && index < 100000; index++) {
          chapters.add({'url': '', 'name': 'Chương ${index + 1}'});
        }
        for (final index in indices.where((i) => i < chapters.length)) {
          try {
            final file = File(p.join(entity.path, 'chap_$index.json'));
            if (await file.length() > 8 * 1024 * 1024) continue;
            final record = jsonDecode(await file.readAsString());
            if (record is Map) {
              if (record['chapterUrl'] is String) {
                chapters[index]['url'] = record['chapterUrl'] as String;
              }
              if (record['chapterTitle'] is String) {
                chapters[index]['name'] = record['chapterTitle'] as String;
              }
            }
          } on FormatException {
            continue;
          } on FileSystemException {
            continue;
          }
        }
      }
      results.add({
        'folderPath': entity.path,
        'storyTitle': info['storyTitle'],
        'pluginId': info['pluginId'],
        'plugin': info['plugin'],
        'type': info['type'] is String ? info['type'] : 'novel',
        'storyUrl': info['storyUrl'] is String ? info['storyUrl'] : null,
        'chapterCount': complete.length,
        'totalChapters': chapters.length,
        'firstChapterIndex': complete.isNotEmpty
            ? complete.first
            : (indices.isEmpty ? 0 : indices.first),
        'chapters': chapters,
      });
    }
    return results;
  }

  Future<void> deleteDownloadedStory(String folderPath) async {
    if (_isRunning) throw StateError('Hãy dừng lượt tải trước khi xóa truyện.');
    final base = await _offlineBaseDir;
    final dir = Directory(folderPath);
    if (await FileSystemEntity.type(dir.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    final root = await base.resolveSymbolicLinks();
    final target = await dir.resolveSymbolicLinks();
    if (!p.isWithin(root, target) ||
        p.dirname(target) != root ||
        await _readInfo(dir) == null) {
      throw const FileSystemException('Thư mục không thuộc truyện đã tải.');
    }
    await dir.delete(recursive: true);
    notifyListeners();
  }

  Future<bool> isChapterDownloaded(
    String pluginId,
    String storyTitle,
    int chapterIndex, {
    String? storyUrl,
  }) async {
    final storyFolder = await _getStoryFolder(
      pluginId,
      storyTitle,
      storyUrl: storyUrl,
    );
    return OfflineChapterStore.isComplete(storyFolder, chapterIndex);
  }

  Future<String?> getDownloadedChapterContent(
    String pluginId,
    String storyTitle,
    int chapterIndex, {
    String? storyUrl,
    String chapterUrl = '',
    String sourceType = 'novel',
  }) async {
    final storyFolder = await _getStoryFolder(
      pluginId,
      storyTitle,
      storyUrl: storyUrl,
    );
    final content = await OfflineChapterStore.read(
      storyFolder,
      chapterIndex,
      chapterUrl: chapterUrl,
      sourceType: sourceType,
    );
    return content?.encode();
  }

  Future<void> startBatchDownload({
    required PluginInfo plugin,
    required String storyTitle,
    required List<Map<String, String>> chapters,
    int startFrom = 0,
    String? storyUrl,
  }) async {
    if (_isRunning) {
      throw StateError('Một lượt tải đang chạy. Hãy chờ lượt hiện tại dừng.');
    }
    if (chapters.isEmpty ||
        storyTitle.trim().isEmpty ||
        startFrom < 0 ||
        startFrom >= chapters.length) {
      throw ArgumentError(
        'Thông tin truyện hoặc danh sách chương không hợp lệ.',
      );
    }
    _isRunning = true;
    final sessionId = _prepareSource == null
        ? 'vbook_offline_${++_sessionSequence}'
        : plugin.id;
    _lastPlugin = plugin;
    _lastChapters = chapters
        .map((chapter) => Map<String, String>.from(chapter))
        .toList(growable: false);
    _lastStoryUrl = storyUrl;
    _status = DownloadStatus.downloading;
    _shouldCancel = false;
    _storyTitle = storyTitle;
    _totalChapters = chapters.length;
    _downloadedCount = 0;
    _errorMessage = '';
    _failedChapterIndices.clear();
    notifyListeners();

    try {
      final folder = await _getStoryFolder(
        plugin.id,
        storyTitle,
        createIfMissing: true,
        storyUrl: storyUrl,
      );
      final info = File(p.join(folder.path, 'story_info.json'));
      final temporaryInfo = File('${info.path}.partial');
      await temporaryInfo.writeAsString(
        jsonEncode({
          'schemaVersion': 2,
          'pluginId': plugin.id,
          'plugin': plugin.toJson(),
          'storyTitle': storyTitle,
          'storyUrl': ?storyUrl,
          'type': plugin.type,
          'totalChapters': chapters.length,
          'chapters': chapters,
          'downloadedAt': DateTime.now().toIso8601String(),
        }),
        flush: true,
      );
      await temporaryInfo.rename(info.path);
      final complete = <int>{};
      for (var index = 0; index < chapters.length; index++) {
        if (await OfflineChapterStore.isComplete(
          folder,
          index,
          requireCurrentFormat: true,
        )) {
          complete.add(index);
        }
      }
      _downloadedCount = complete.length;
      notifyListeners();
      var preparedSource = false;
      for (var index = startFrom; index < chapters.length; index++) {
        if (_shouldCancel) break;
        if (complete.contains(index)) continue;
        final chapter = chapters[index];
        final url = chapter['url'] ?? '';
        final title = chapter['name']?.trim().isNotEmpty == true
            ? chapter['name']!
            : 'Chương ${index + 1}';
        _currentDownloadingTitle = title;
        notifyListeners();
        var saved = false;
        for (
          var attempt = 0;
          attempt < 3 && !_shouldCancel && !saved;
          attempt++
        ) {
          try {
            if (!preparedSource) {
              preparedSource = _prepareSource != null
                  ? await _prepareSource!(plugin)
                  : await VBookEngineChannel.loadSource(
                      sessionId,
                      await PluginLoader.getPluginDir(plugin.id),
                    );
              if (!preparedSource) {
                throw StateError('Extension source unavailable.');
              }
            }
            final pages = await _loadPages(sessionId, url);
            final content = OnlineChapterContent.fromPages(
              pages,
              chapterUrl: url,
              sourceType: plugin.type,
            );
            await OfflineChapterStore.write(
              folder: folder,
              index: index,
              pluginId: plugin.id,
              storyTitle: storyTitle,
              chapterTitle: title,
              chapterUrl: url,
              content: content,
              loadImage: _loadImage,
              isCancelled: () => _shouldCancel,
            );
            saved = true;
            _downloadedCount++;
            notifyListeners();
          } catch (_) {
            if (!_shouldCancel && attempt < 2) {
              await Future<void>.delayed(_requestDelay * (attempt + 1));
            }
          }
        }
        if (!saved && !_shouldCancel) {
          _failedChapterIndices.add(index);
          _errorMessage =
              'Một số chương hoặc ảnh chưa tải được. Dữ liệu đã tải được giữ nguyên.';
        }
        if (!_shouldCancel) await Future<void>.delayed(_requestDelay);
      }
      if (_shouldCancel) {
        _status = DownloadStatus.paused;
      } else if (_downloadedCount == _totalChapters) {
        _status = DownloadStatus.completed;
      } else {
        _status = DownloadStatus.error;
        _errorMessage =
            'Còn chương hoặc ảnh chưa tải xong. Hãy thử tải lại các chương thiếu.';
      }
    } catch (_) {
      _status = _shouldCancel ? DownloadStatus.paused : DownloadStatus.error;
      _errorMessage =
          'Không thể hoàn tất tải truyện. Kiểm tra nguồn truyện và quyền lưu trữ rồi thử lại.';
    } finally {
      if (_prepareSource == null) {
        try {
          await VBookEngineChannel.closeSource(sessionId);
        } catch (_) {
          /* The download result must survive engine cleanup failure. */
        }
      }
      _isRunning = false;
      notifyListeners();
    }
  }

  Future<void> retryFailedDownloads() async {
    final plugin = _lastPlugin;
    if (!canRetry || plugin == null) return;
    await startBatchDownload(
      plugin: plugin,
      storyTitle: _storyTitle,
      chapters: _lastChapters,
      storyUrl: _lastStoryUrl,
    );
  }

  void cancelDownload() {
    _shouldCancel = true;
    _status = DownloadStatus.paused;
    notifyListeners();
  }

  Future<List<Map<String, String>>> _exportChapters(Directory folder) async {
    final chapters = <Map<String, String>>[];
    for (final index in await _chapterIndices(folder)) {
      final content = await OfflineChapterStore.read(folder, index);
      if (content == null) continue;
      final record =
          jsonDecode(
                await File(
                  p.join(folder.path, 'chap_$index.json'),
                ).readAsString(),
              )
              as Map;
      chapters.add({
        'title': record['chapterTitle'] is String
            ? record['chapterTitle'] as String
            : 'Chương ${index + 1}',
        'content': content.encode(),
      });
    }
    return chapters;
  }

  Future<File?> exportToTxt(
    String pluginId,
    String storyTitle,
    int totalChaps, {
    String? storyUrl,
  }) async {
    final folder = await _getStoryFolder(
      pluginId,
      storyTitle,
      storyUrl: storyUrl,
    );
    final chapters = await _exportChapters(folder);
    if (chapters.isEmpty) return null;
    final file = await BookFileNames.availableFile(
      await _offlineBaseDir,
      storyTitle,
      'txt',
    );
    final sink = file.openWrite();
    try {
      sink.writeln('==================================================');
      sink.writeln(storyTitle);
      sink.writeln('Nguồn: vBook Extension ($pluginId)');
      sink.writeln('==================================================');
      for (final chapter in chapters) {
        sink.writeln('\n--- ${chapter['title']} ---\n');
        final content = OnlineChapterContent.decode(
          chapter['content']!,
          chapterUrl: '',
          sourceType: 'novel',
        );
        for (final block in content.blocks) {
          sink.writeln(
            block.isImage
                ? '[Minh họa: xem trong bản EPUB hoặc trình đọc vBook]'
                : block.value,
          );
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return file;
  }

  Future<File?> exportToEpub(
    String pluginId,
    String storyTitle,
    int totalChaps, {
    String author = 'VBook Source',
    String? storyUrl,
  }) async {
    final folder = await _getStoryFolder(
      pluginId,
      storyTitle,
      storyUrl: storyUrl,
    );
    final chapters = await _exportChapters(folder);
    if (chapters.isEmpty) return null;
    return EpubExportService.instance.exportToEpub(
      storyTitle: storyTitle,
      author: author,
      chapters: chapters,
      imageRootDirectory: folder,
      outputDirectory: await _offlineBaseDir,
    );
  }
}
