import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import '../../models/source_models.dart';
import 'vbook_dart_engine.dart';

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

class _SourceContext {
  final String dirPath;
  final Map<String, String> scripts;
  _SourceContext(this.dirPath, this.scripts);
}

class VBookEngineChannel {
  static final Map<String, _SourceContext> _sources = {};

  static Future<bool> loadSource(String id, String dirPath) async {
    try {
      final pluginFile = File('$dirPath/plugin.json');
      if (!await pluginFile.exists()) return false;
      
      final jsonStr = await pluginFile.readAsString();
      final pluginData = jsonDecode(jsonStr);
      final scriptsMap = pluginData['scripts'] as Map<String, dynamic>? ?? {};
      
      final scripts = <String, String>{};
      for (final entry in scriptsMap.entries) {
        final scriptFileName = entry.value.toString();
        final scriptFile = File('$dirPath/src/$scriptFileName');
        if (await scriptFile.exists()) {
          final content = await scriptFile.readAsString();
          // We decrypt using empty keys for now unless JsLoader implements something else
          // But since JsLoader is removed/refactored, we just read raw string.
          // Wait, JsLoader.decryptScript might be used here, but for now we just use content.
          scripts[entry.key] = content; 
        }
      }
      
      _sources[id] = _SourceContext(dirPath, scripts);
      return true;
    } catch (e) {
      debugPrint('[VBookEngineChannel] loadSource error: $e');
      return false;
    }
  }

  static Future<dynamic> _executeScript(
    String operation,
    String id,
    String scriptKey,
    String method,
    List<dynamic> args,
  ) async {
    final context = _sources[id];
    if (context == null) throw _fromPlatformException(operation, 'NOT_LOADED');
    final scriptCode = context.scripts[scriptKey];
    if (scriptCode == null) throw _invalidResponse(operation);

    try {
      final jsonResult = await VBookDartEngine.execute(
        context.dirPath,
        method,
        args,
        scriptCode: scriptCode,
      );
      if (jsonResult == null) throw _invalidResponse(operation);
      
      final result = jsonDecode(jsonResult.toString());
      if (result['ok'] == true) {
        return result['data'];
      } else {
        debugPrint('[VBookEngineChannel] JS Error: \${result["error"]}');
        throw _fromPlatformException(operation, 'JS_ERROR');
      }
    } catch (e) {
      if (e is VBookEngineException) rethrow;
      debugPrint('[VBookEngineChannel] Execution error: \$e');
      throw _fromPlatformException(operation, 'EXEC_ERROR');
    }
  }

  static Future<MangasPage?> getPopularManga(String id, int page) async {
    final result = await _executeScript('getPopularManga', id, 'home', 'execute', ['']); 
    return _parseMangasPage(_requireResult(result, 'getPopularManga'), 'getPopularManga');
  }

  static Future<MangasPage?> getLatestUpdates(String id, int page) async {
    final result = await _executeScript('getLatestUpdates', id, 'latest', 'execute', ['']);
    return _parseMangasPage(_requireResult(result, 'getLatestUpdates'), 'getLatestUpdates');
  }

  static Future<MangasPage?> getSearchManga(String id, String query, int page) async {
    final result = await _executeScript('getSearchManga', id, 'search', 'execute', [query, page]);
    return _parseMangasPage(_requireResult(result, 'getSearchManga'), 'getSearchManga');
  }

  static Future<SManga?> getMangaDetails(String id, String url) async {
    final result = await _executeScript('getMangaDetails', id, 'detail', 'execute', [url]);
    if (result == null) return null;
    
    final manga = SManga.create();
    manga.url = url;
    
    if (result is Map) {
      manga.title = result['name']?.toString() ?? result['title']?.toString() ?? '';
      manga.author = result['author']?.toString() ?? '';
      manga.artist = result['artist']?.toString() ?? '';
      manga.description = result['description']?.toString() ?? result['subTitle']?.toString() ?? result['chap']?.toString() ?? '';
      manga.genre = result['genre']?.toString() ?? '';
      manga.status = (result['status'] as num?)?.toInt() ?? SManga.unknown;
      manga.thumbnailUrl = result['cover']?.toString() ?? result['img']?.toString() ?? result['thumbnail_url']?.toString() ?? '';
    }
    
    manga.initialized = true;
    return manga;
  }

  static Future<List<SChapter>> getChapterList(String id, String url) async {
    final result = await _executeScript('getChapterList', id, 'chapter', 'execute', [url]);
    
    List listResult = [];
    if (result is List) {
      listResult = result;
    } else if (result is Map && result['data'] is List) {
      listResult = result['data'] as List;
    } else {
      throw _invalidResponse('getChapterList');
    }
    
    return listResult.map((item) {
      final chapterData = Map<String, dynamic>.from(item as Map);
      final chapter = SChapter();
      chapter.url = chapterData['url']?.toString() ?? chapterData['link']?.toString() ?? '';
      chapter.name = chapterData['name']?.toString() ?? chapterData['title']?.toString() ?? '';
      chapter.dateUpload = (chapterData['date_upload'] as num?)?.toInt() ?? 0;
      return chapter;
    }).toList();
  }

  static Future<List<Page>> getPageList(String id, String url) async {
    final result = await _executeScript('getPageList', id, 'page', 'execute', [url]);
    
    List listResult = [];
    if (result is List) {
      listResult = result;
    } else if (result is Map && result['data'] is List) {
      listResult = result['data'] as List;
    } else {
      throw _invalidResponse('getPageList');
    }
    
    int index = 0;
    return listResult.map((item) {
      var imageUrl = '';
      if (item is String) {
        imageUrl = item;
      } else if (item is Map) {
        imageUrl = item['url']?.toString() ?? item['src']?.toString() ?? item['image']?.toString() ?? item['link']?.toString() ?? '';
      }
      return Page(index++, url, imageUrl);
    }).toList();
  }

  static Future<List<Map<String, String>>> getHomeTabs(String id) async {
    final result = await _executeScript('getHomeTabs', id, 'gen', 'execute', []);
    
    List listResult = [];
    if (result is List) {
      listResult = result;
    } else if (result is Map && result['data'] is List) {
      listResult = result['data'] as List;
    } else {
      throw _invalidResponse('getHomeTabs');
    }
    
    return listResult.map((item) {
      final tab = Map<String, dynamic>.from(item as Map);
      return {
        'title': tab['title']?.toString() ?? '',
        'input': tab['input']?.toString() ?? '',
        'script': tab['script']?.toString() ?? '',
      };
    }).toList();
  }

  static Future<MangasPage?> getMangaListByTab(
    String id,
    String input,
    String scriptKey,
    int page,
  ) async {
    final result = await _executeScript('getMangaListByTab', id, scriptKey, 'execute', [input, page]);
    return _parseMangasPage(_requireResult(result, 'getMangaListByTab'), 'getMangaListByTab');
  }

  static Future<void> closeSource(String id) async {
    _sources.remove(id);
  }

  static T _requireResult<T>(T? result, String operation) {
    if (result == null) throw _invalidResponse(operation);
    return result;
  }

  static VBookEngineException _fromPlatformException(
    String operation,
    String code,
  ) {
    final message = switch (code) {
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
      code: code,
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
    dynamic result,
    String operation,
  ) {
    List listResult = [];
    if (result is List) {
      listResult = result;
    } else if (result is Map) {
      final data = result['data'];
      if (data is List) {
        listResult = data;
      } else {
        throw _invalidResponse(operation);
      }
    } else {
      throw _invalidResponse(operation);
    }
    
    final mangas = listResult.map((item) {
      final mangaData = Map<String, dynamic>.from(item as Map);
      final manga = SManga.create();
      manga.url = mangaData['url']?.toString() ?? mangaData['link']?.toString() ?? '';
      manga.title = mangaData['title']?.toString() ?? mangaData['name']?.toString() ?? '';
      manga.thumbnailUrl = mangaData['thumbnail_url']?.toString() ?? mangaData['cover']?.toString() ?? mangaData['img']?.toString() ?? '';
      manga.description = mangaData['description']?.toString() ?? '';
      return manga;
    }).toList();
    return MangasPage(mangas, false);
  }
}
