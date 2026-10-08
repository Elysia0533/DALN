import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;
import 'package:http/http.dart' as http;

class JsResourceLimitException implements Exception {
  final String resource;
  JsResourceLimitException(this.resource);
  @override
  String toString() => 'JsResourceLimitException: $resource limit exceeded';
}

class DartAppBridge {
  DartAppBridge({
    required this.rootDir,
    required this.baseUrl,
  });

  final Directory rootDir;
  final String baseUrl;

  final Map<int, List<dom.Element>> _elementsMap = {};
  int _nextId = 0;

  static const int maxJsoupHandles = 10000;
  static const int maxHtmlCharacters = 8 * 1024 * 1024;
  static const int maxHostSleepMs = 5000;

  int storeElements(List<dom.Element> elements) {
    if (_elementsMap.length >= maxJsoupHandles) {
      throw JsResourceLimitException('HTML handle');
    }
    final id = _nextId++;
    _elementsMap[id] = elements;
    return id;
  }

  Map<String, dynamic> _parseRequestOptions(String optionsJson) {
    if (optionsJson.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(optionsJson);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return {};
  }

  Future<String> fetch(String url, String optionsJson) async {
    final options = _parseRequestOptions(optionsJson);
    final method = (options['method'] as String?)?.toUpperCase() ?? 'GET';
    final rawHeaders = options['headers'] as Map<String, dynamic>? ?? {};
    final headers = rawHeaders.map((k, v) => MapEntry(k, v.toString()));
    
    final body = options['body'];

    final uri = Uri.parse(url);
    final request = http.Request(method, uri);
    request.headers.addAll(headers);
    if (body != null) {
      request.body = body.toString();
    }

    final response = await http.Client().send(request);
    final responseBytes = await response.stream.toBytes();
    final text = utf8.decode(responseBytes, allowMalformed: true);

    final result = {
      'ok': response.statusCode >= 200 && response.statusCode < 300,
      'status': response.statusCode,
      'headers': response.headers,
      'text': text,
    };
    return jsonEncode(result);
  }

  Future<String> fetchBase64(String url, String optionsJson) async {
    final options = _parseRequestOptions(optionsJson);
    final method = (options['method'] as String?)?.toUpperCase() ?? 'GET';
    final rawHeaders = options['headers'] as Map<String, dynamic>? ?? {};
    final headers = rawHeaders.map((k, v) => MapEntry(k, v.toString()));
    
    final uri = Uri.parse(url);
    final request = http.Request(method, uri);
    request.headers.addAll(headers);

    final response = await http.Client().send(request);
    final responseBytes = await response.stream.toBytes();
    return base64Encode(responseBytes);
  }

  String load(String path) {
    final canonicalRootDir = rootDir.absolute.path;
    File? fileToRead;

    final srcFile = File('${rootDir.path}/src/$path').absolute;
    if (srcFile.existsSync() && srcFile.path.startsWith(canonicalRootDir)) {
      fileToRead = srcFile;
    } else {
      final rootFile = File('${rootDir.path}/$path').absolute;
      if (rootFile.existsSync() && rootFile.path.startsWith(canonicalRootDir)) {
        fileToRead = rootFile;
      }
    }

    if (fileToRead == null) return '';

    final rawContent = fileToRead.readAsStringSync();
    return rawContent;
  }

  int jsoupParse(String html, String baseUri) {
    if (html.length > maxHtmlCharacters) {
      throw JsResourceLimitException('HTML input');
    }
    final doc = parser.parse(html, sourceUrl: baseUri);
    if (doc.documentElement != null) {
      return storeElements([doc.documentElement!]);
    }
    return storeElements([]);
  }

  int jsoupSelect(int id, String selector) {
    final parents = _elementsMap[id];
    if (parents == null) return -1;
    final List<dom.Element> results = [];
    for (final p in parents) {
      results.addAll(p.querySelectorAll(selector));
    }
    return storeElements(results);
  }

  String jsoupText(int id) {
    final els = _elementsMap[id];
    if (els == null || els.isEmpty) return '';
    return els.map((e) => e.text).join(' ');
  }

  String jsoupHtml(int id) {
    final els = _elementsMap[id];
    if (els == null || els.isEmpty) return '';
    return els.map((e) => e.outerHtml).join('\n');
  }

  String _resolveUrl(String relativeUrl, String? baseUri) {
    if (baseUri == null || baseUri.isEmpty) return relativeUrl;
    try {
      return Uri.parse(baseUri).resolve(relativeUrl).toString();
    } catch (_) {
      return relativeUrl;
    }
  }

  String jsoupAttr(int id, String name) {
    final els = _elementsMap[id];
    if (els == null || els.isEmpty) return '';
    final el = els.first;
    
    final isSrcOrHref = name.toLowerCase() == 'src' || name.toLowerCase() == 'href';
    final baseUri = baseUrl;

    if (name.toLowerCase() == 'src' && el.localName == 'img') {
      final fallbacks = [
        el.attributes['data-src'],
        el.attributes['data-original'],
        el.attributes['data-lazy-src'],
        el.attributes['src'],
      ];
      for (final val in fallbacks) {
        if (val != null && val.isNotEmpty && !val.startsWith('data:')) {
          final resolved = _resolveUrl(val, baseUri);
          if (resolved.startsWith('http')) return resolved;
        }
      }
    }

    final val = el.attributes[name] ?? '';
    if (isSrcOrHref && val.isNotEmpty) {
      return _resolveUrl(val, baseUri);
    }
    return val;
  }

  void jsoupRemove(int id) {
    _elementsMap.remove(id);
  }

  int jsoupFirst(int id) {
    final els = _elementsMap[id];
    if (els == null || els.isEmpty) return storeElements([]);
    return storeElements([els.first]);
  }

  int jsoupLast(int id) {
    final els = _elementsMap[id];
    if (els == null || els.isEmpty) return storeElements([]);
    return storeElements([els.last]);
  }

  int jsoupSize(int id) {
    return _elementsMap[id]?.length ?? 0;
  }

  int jsoupGet(int id, int index) {
    final els = _elementsMap[id];
    if (els == null || index < 0 || index >= els.length) return storeElements([]);
    return storeElements([els[index]]);
  }

  int jsoupParent(int id) {
    final els = _elementsMap[id];
    if (els == null || els.isEmpty) return storeElements([]);
    final p = els.first.parent;
    if (p == null) return storeElements([]);
    return storeElements([p]);
  }

  int jsoupChildren(int id) {
    final els = _elementsMap[id];
    if (els == null || els.isEmpty) return storeElements([]);
    return storeElements(els.first.children);
  }

  bool jsoupHasClass(int id, String className) {
    final els = _elementsMap[id];
    if (els == null || els.isEmpty) return false;
    return els.first.classes.contains(className);
  }

  void sleepMs(int ms) {
    if (ms > maxHostSleepMs) {
      throw JsResourceLimitException('host sleep');
    }
    sleep(Duration(milliseconds: ms > 0 ? ms : 0));
  }
}
