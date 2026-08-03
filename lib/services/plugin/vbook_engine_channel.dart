import 'package:flutter/services.dart';
import '../../models/source_models.dart';

class VBookEngineChannel {
  static const MethodChannel _channel = MethodChannel('com.vbook.reader/vbook_engine');

  /// Loads a vBook plugin from a directory on disk.
  /// [id] should be a stable, unique identifier per plugin (e.g. plugin.id.hashCode).
  static Future<bool> loadSource(int id, String dirPath) async {
    try {
      print('[VBookEngine] loadSource id=$id dirPath=$dirPath');
      final res = await _channel.invokeMethod<bool>('loadSource', {
        'id': id,
        'dirPath': dirPath,
      });
      print('[VBookEngine] loadSource result: $res');
      return res ?? false;
    } on PlatformException catch (e) {
      print('[VBookEngine] loadSource PlatformException:');
      print('  code: ${e.code}');
      print('  message: ${e.message}');
      print('  details: ${e.details}');
      return false;
    } catch (e) {
      print('[VBookEngine] loadSource error: $e');
      return false;
    }
  }

  static Future<MangasPage?> getPopularManga(int id, int page) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getPopularManga', {
        'id': id,
        'page': page,
      });
      if (res != null) {
        return _parseMangasPage(res);
      }
    } catch (e) {
      print('[VBookEngine] getPopularManga error: $e');
    }
    return null;
  }

  static Future<MangasPage?> getLatestUpdates(int id, int page) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getLatestUpdates', {
        'id': id,
        'page': page,
      });
      if (res != null) {
        return _parseMangasPage(res);
      }
    } catch (e) {
      print('[VBookEngine] getLatestUpdates error: $e');
    }
    return null;
  }

  static Future<MangasPage?> getSearchManga(int id, String query, int page) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getSearchManga', {
        'id': id,
        'query': query,
        'page': page,
      });
      if (res != null) {
        return _parseMangasPage(res);
      }
    } catch (e) {
      print('[VBookEngine] getSearchManga error: $e');
    }
    return null;
  }

  static Future<SManga?> getMangaDetails(int id, String url) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getMangaDetails', {
        'id': id,
        'url': url,
      });
      if (res != null) {
        final sm = SManga.create();
        sm.url = url;
        sm.title = res['title']?.toString() ?? '';
        sm.author = res['author']?.toString() ?? '';
        sm.artist = res['artist']?.toString() ?? '';
        sm.description = res['description']?.toString() ?? '';
        sm.genre = res['genre']?.toString() ?? '';
        sm.status = (res['status'] as num?)?.toInt() ?? SManga.UNKNOWN;
        sm.thumbnailUrl = res['thumbnail_url']?.toString() ?? '';
        sm.initialized = true;
        return sm;
      }
    } catch (e) {
      print('[VBookEngine] getMangaDetails error: $e');
    }
    return null;
  }

  static Future<List<SChapter>> getChapterList(int id, String url) async {
    try {
      final res = await _channel.invokeListMethod<dynamic>('getChapterList', {
        'id': id,
        'url': url,
      });
      if (res != null) {
        return res.map((c) {
          final ch = SChapter();
          ch.url = c['url']?.toString() ?? '';
          ch.name = c['name']?.toString() ?? '';
          ch.dateUpload = (c['date_upload'] as num?)?.toInt() ?? 0;
          return ch;
        }).toList();
      }
    } catch (e) {
      print('[VBookEngine] getChapterList error: $e');
    }
    return [];
  }

  static Future<List<Page>> getPageList(int id, String url) async {
    try {
      final res = await _channel.invokeListMethod<dynamic>('getPageList', {
        'id': id,
        'url': url,
      });
      if (res != null) {
        return res.map((p) {
          return Page(
            (p['index'] as num?)?.toInt() ?? 0,
            p['url']?.toString() ?? '',
            p['imageUrl']?.toString() ?? '',
          );
        }).toList();
      }
    } catch (e) {
      print('[VBookEngine] getPageList error: $e');
    }
    return [];
  }

  static Future<List<Map<String, String>>> getHomeTabs(int id) async {
    try {
      final res = await _channel.invokeListMethod<dynamic>('getHomeTabs', {'id': id});
      if (res != null) {
        return res.map((item) {
          final m = Map<String, dynamic>.from(item as Map);
          return {
            'title': m['title']?.toString() ?? '',
            'input': m['input']?.toString() ?? '',
            'script': m['script']?.toString() ?? '',
          };
        }).toList();
      }
    } catch (e) {
      print('[VBookEngine] getHomeTabs error: $e');
    }
    return [];
  }

  static Future<MangasPage?> getMangaListByTab(int id, String input, String script, int page) async {
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getMangaListByTab', {
        'id': id,
        'input': input,
        'script': script,
        'page': page,
      });
      if (res != null) {
        return _parseMangasPage(res);
      }
    } catch (e) {
      print('[VBookEngine] getMangaListByTab error: $e');
    }
    return null;
  }

  static Future<void> closeSource(int id) async {
    try {
      await _channel.invokeMethod('closeSource', {'id': id});
    } catch (e) {
      print('[VBookEngine] closeSource error: $e');
    }
  }

  // ── Helper ──
  static MangasPage _parseMangasPage(Map<String, dynamic> res) {
    final hasNext = res['hasNextPage'] as bool? ?? false;
    final list = (res['mangas'] as List?)?.map((m) {
      final sm = SManga.create();
      sm.url = m['url']?.toString() ?? '';
      sm.title = m['title']?.toString() ?? '';
      sm.thumbnailUrl = m['thumbnail_url']?.toString() ?? '';
      sm.description = m['description']?.toString() ?? '';
      return sm;
    }).toList() ?? <SManga>[];
    return MangasPage(list, hasNext);
  }
}
