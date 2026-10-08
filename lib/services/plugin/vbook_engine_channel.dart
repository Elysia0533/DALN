import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/source_models.dart';

class VBookEngineException implements Exception {
  const VBookEngineException({
    required this.code,
    required this.operation,
    required this.message,
  });

  final String code;
  final String operation;
  final String message;

  @override
  String toString() => message;
}

class VBookEngineChannel {
  static const MethodChannel _channel = MethodChannel(
    'com.vbook.reader/vbook_engine',
  );

  /// Loads a vBook plugin from a directory on disk.
  /// [id] is the unique string identifier per plugin (e.g. plugin.id).
  static Future<bool> loadSource(String id, String dirPath) {
    return _guard('loadSource', () async {
      final result = await _channel.invokeMethod<bool>('loadSource', {
        'id': id,
        'dirPath': dirPath,
      });
      return _requireResult(result, 'loadSource');
    });
  }

  static Future<MangasPage?> getPopularManga(String id, int page) {
    return _guard('getPopularManga', () async {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getPopularManga',
        {'id': id, 'page': page},
      );
      return _parseMangasPage(
        _requireResult(result, 'getPopularManga'),
        'getPopularManga',
      );
    });
  }

  static Future<MangasPage?> getLatestUpdates(String id, int page) {
    return _guard('getLatestUpdates', () async {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getLatestUpdates',
        {'id': id, 'page': page},
      );
      return _parseMangasPage(
        _requireResult(result, 'getLatestUpdates'),
        'getLatestUpdates',
      );
    });
  }

  static Future<MangasPage?> getSearchManga(String id, String query, int page) {
    return _guard('getSearchManga', () async {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getSearchManga',
        {'id': id, 'query': query, 'page': page},
      );
      return _parseMangasPage(
        _requireResult(result, 'getSearchManga'),
        'getSearchManga',
      );
    });
  }

  static Future<SManga?> getMangaDetails(String id, String url) {
    return _guard('getMangaDetails', () async {
      final result = _requireResult(
        await _channel.invokeMapMethod<String, dynamic>('getMangaDetails', {
          'id': id,
          'url': url,
        }),
        'getMangaDetails',
      );
      final manga = SManga.create();
      manga.url = url;
      manga.title = result['title']?.toString() ?? '';
      manga.author = result['author']?.toString() ?? '';
      manga.artist = result['artist']?.toString() ?? '';
      manga.description = result['description']?.toString() ?? '';
      manga.genre = result['genre']?.toString() ?? '';
      manga.status = (result['status'] as num?)?.toInt() ?? SManga.unknown;
      manga.thumbnailUrl = result['thumbnail_url']?.toString() ?? '';
      manga.initialized = true;
      return manga;
    });
  }

  static Future<List<SChapter>> getChapterList(String id, String url) {
    return _guard('getChapterList', () async {
      final result = _requireResult(
        await _channel.invokeListMethod<dynamic>('getChapterList', {
          'id': id,
          'url': url,
        }),
        'getChapterList',
      );
      return result.map((item) {
        final chapterData = Map<String, dynamic>.from(item as Map);
        final chapter = SChapter();
        chapter.url = chapterData['url']?.toString() ?? '';
        chapter.name = chapterData['name']?.toString() ?? '';
        chapter.dateUpload = (chapterData['date_upload'] as num?)?.toInt() ?? 0;
        return chapter;
      }).toList();
    });
  }

  static Future<List<Page>> getPageList(String id, String url) {
    return _guard('getPageList', () async {
      final result = _requireResult(
        await _channel.invokeListMethod<dynamic>('getPageList', {
          'id': id,
          'url': url,
        }),
        'getPageList',
      );
      return result.map((item) {
        final pageData = Map<String, dynamic>.from(item as Map);
        return Page(
          (pageData['index'] as num?)?.toInt() ?? 0,
          pageData['url']?.toString() ?? '',
          pageData['imageUrl']?.toString() ?? '',
        );
      }).toList();
    });
  }

  static Future<List<Map<String, String>>> getHomeTabs(String id) {
    return _guard('getHomeTabs', () async {
      final result = _requireResult(
        await _channel.invokeListMethod<dynamic>('getHomeTabs', {'id': id}),
        'getHomeTabs',
      );
      return result.map((item) {
        final tab = Map<String, dynamic>.from(item as Map);
        return {
          'title': tab['title']?.toString() ?? '',
          'input': tab['input']?.toString() ?? '',
          'script': tab['script']?.toString() ?? '',
        };
      }).toList();
    });
  }

  static Future<MangasPage?> getMangaListByTab(
    String id,
    String input,
    String script,
    int page,
  ) {
    return _guard('getMangaListByTab', () async {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getMangaListByTab',
        {'id': id, 'input': input, 'script': script, 'page': page},
      );
      return _parseMangasPage(
        _requireResult(result, 'getMangaListByTab'),
        'getMangaListByTab',
      );
    });
  }

  static Future<void> closeSource(String id) {
    return _guard('closeSource', () async {
      await _channel.invokeMethod<void>('closeSource', {'id': id});
    });
  }

  static Future<T> _guard<T>(
    String operation,
    Future<T> Function() action,
  ) async {
    try {
      return await action();
    } on VBookEngineException {
      rethrow;
    } on PlatformException catch (error) {
      debugPrint(
        '[VBookEngine] operation=$operation failed code=${error.code}',
      );
      throw _fromPlatformException(operation, error);
    } catch (_) {
      debugPrint(
        '[VBookEngine] operation=$operation returned an invalid response',
      );
      throw _invalidResponse(operation);
    }
  }

  static T _requireResult<T>(T? result, String operation) {
    if (result == null) throw _invalidResponse(operation);
    return result;
  }

  static VBookEngineException _fromPlatformException(
    String operation,
    PlatformException error,
  ) {
    final message = switch (error.code) {
      'EXEC_TIMEOUT' =>
        'Extension execution timed out. Reload the source before retrying.',
      'NETWORK_ERROR' =>
        'The extension could not complete its network request.',
      'JS_ERROR' => 'The extension JavaScript failed to execute.',
      'PARSE_ERROR' => 'The extension returned data in an invalid format.',
      'RESOURCE_LIMIT' => 'The extension exceeded an execution resource limit.',
      'ASYNC_UNSUPPORTED' =>
        'This extension uses Promise/async, which is not supported by the current Android engine.',
      'EXEC_CANCELLED' => 'The extension request was cancelled.',
      'ENGINE_UNAVAILABLE' =>
        'The extension engine is unavailable. Reload the source before retrying.',
      'NOT_LOADED' => 'The extension source is not loaded.',
      'LOAD_FAILED' || 'LOAD_ERROR' => 'The extension could not be loaded.',
      _ => 'The extension engine could not complete this request.',
    };
    return VBookEngineException(
      code: error.code,
      operation: operation,
      message: message,
    );
  }

  static VBookEngineException _invalidResponse(String operation) {
    return VBookEngineException(
      code: 'INVALID_RESPONSE',
      operation: operation,
      message: 'The extension engine returned an invalid response.',
    );
  }

  static MangasPage _parseMangasPage(
    Map<String, dynamic> result,
    String operation,
  ) {
    final rawMangas = result['mangas'];
    if (rawMangas is! List) throw _invalidResponse(operation);
    final hasNext = result['hasNextPage'] as bool? ?? false;
    final mangas = rawMangas.map((item) {
      final mangaData = Map<String, dynamic>.from(item as Map);
      final manga = SManga.create();
      manga.url = mangaData['url']?.toString() ?? '';
      manga.title = mangaData['title']?.toString() ?? '';
      manga.thumbnailUrl = mangaData['thumbnail_url']?.toString() ?? '';
      manga.description = mangaData['description']?.toString() ?? '';
      return manga;
    }).toList();
    return MangasPage(mangas, hasNext);
  }
}
