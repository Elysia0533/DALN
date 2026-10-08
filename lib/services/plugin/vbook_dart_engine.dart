import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:quickjs_engine/quickjs_engine.dart';
import 'package:online_story_reader/services/plugin/dart_app_bridge.dart';

class _JsExecutionRequest {
  final String dirPath;
  final String method;
  final List<dynamic> args;
  final String? scriptCode;
  
  _JsExecutionRequest({
    required this.dirPath,
    required this.method,
    required this.args,
    this.scriptCode,
  });
}

class VBookDartEngine {
  static Future<dynamic> execute(
    String dirPath,
    String method,
    List<dynamic> args, {
    String? scriptCode,
  }) async {
    final request = _JsExecutionRequest(
      dirPath: dirPath,
      method: method,
      args: args,
      scriptCode: scriptCode,
    );

    // Run in a separate isolate to avoid blocking the main UI thread during JS execution
    return await Isolate.run(() => _isolateEntryPoint(request));
  }

  static Future<dynamic> _isolateEntryPoint(_JsExecutionRequest request) async {
    final rootDir = Directory(request.dirPath);
    final bridge = DartAppBridge(rootDir: rootDir, baseUrl: '');
    final jsRuntime = getJavascriptRuntime(xhr: false);
    
    try {
      // Register channels
      jsRuntime.onMessage('fetch', (dynamic args) async {
        if (args is! List || args.isEmpty) return null;
        final url = args[0].toString();
        final optionsJson = args.length > 1 ? args[1].toString() : '{}';
        return await bridge.fetch(url, optionsJson);
      });

      jsRuntime.onMessage('fetchBase64', (dynamic args) async {
        if (args is! List || args.isEmpty) return null;
        final url = args[0].toString();
        final optionsJson = args.length > 1 ? args[1].toString() : '{}';
        return await bridge.fetchBase64(url, optionsJson);
      });

      jsRuntime.onMessage('load', (dynamic args) {
        if (args is! List || args.isEmpty) return null;
        final path = args[0].toString();
        return bridge.load(path);
      });

      jsRuntime.onMessage('jsoupParse', (dynamic args) {
        if (args is! List || args.isEmpty) return null;
        final html = args[0].toString();
        return bridge.jsoupParse(html, request.dirPath);
      });

      jsRuntime.onMessage('jsoupSelect', (dynamic args) {
        if (args is! List || args.length < 2) return null;
        final id = args[0] as int;
        final cssQuery = args[1].toString();
        return bridge.jsoupSelect(id, cssQuery);
      });

      jsRuntime.onMessage('jsoupText', (dynamic args) {
        if (args is! List || args.isEmpty) return null;
        final id = args[0] as int;
        return bridge.jsoupText(id);
      });

      jsRuntime.onMessage('jsoupHtml', (dynamic args) {
        if (args is! List || args.isEmpty) return null;
        final id = args[0] as int;
        return bridge.jsoupHtml(id);
      });

      jsRuntime.onMessage('jsoupAttr', (dynamic args) {
        if (args is! List || args.length < 2) return null;
        final id = args[0] as int;
        final name = args[1].toString();
        return bridge.jsoupAttr(id, name);
      });

      jsRuntime.onMessage('jsoupRemove', (dynamic args) {
        if (args is! List || args.isEmpty) return null;
        final id = args[0] as int;
        bridge.jsoupRemove(id);
        return null;
      });

      jsRuntime.onMessage('jsoupFirst', (dynamic args) {
        if (args is! List || args.isEmpty) return null;
        final id = args[0] as int;
        return bridge.jsoupFirst(id);
      });

      jsRuntime.onMessage('jsoupLast', (dynamic args) {
        if (args is! List || args.isEmpty) return null;
        final id = args[0] as int;
        return bridge.jsoupLast(id);
      });

      jsRuntime.onMessage('jsoupSize', (dynamic args) {
        if (args is! List || args.isEmpty) return null;
        final id = args[0] as int;
        return bridge.jsoupSize(id);
      });

      jsRuntime.onMessage('jsoupGet', (dynamic args) {
        if (args is! List || args.length < 2) return null;
        final id = args[0] as int;
        final index = args[1] as int;
        return bridge.jsoupGet(id, index);
      });

      jsRuntime.onMessage('jsoupParent', (dynamic args) {
        if (args is! List || args.isEmpty) return null;
        final id = args[0] as int;
        return bridge.jsoupParent(id);
      });

      jsRuntime.onMessage('log', (dynamic args) {
        if (args is! List || args.isEmpty) return null;
        print('[JS Log] \${args[0]}');
        return null;
      });
      
      // We must inject synchronous polyfills for our APIs if JS calls them synchronously.
      // However, sendMessage is inherently async. We wrap them in JS functions.
      // If scripts use sync fetch, this will break. But we will provide async wrappers anyway.
      final polyfill = '''
        function fetch(url, options) { return sendMessage("fetch", JSON.stringify([url, JSON.stringify(options || {})])); }
        function fetchBase64(url, options) { return sendMessage("fetchBase64", JSON.stringify([url, JSON.stringify(options || {})])); }
        function load(path) { return sendMessage("load", JSON.stringify([path])); }
        function jsoupParse(html) { return sendMessage("jsoupParse", JSON.stringify([html])); }
        function jsoupSelect(id, css) { return sendMessage("jsoupSelect", JSON.stringify([id, css])); }
        function jsoupText(id) { return sendMessage("jsoupText", JSON.stringify([id])); }
        function jsoupHtml(id) { return sendMessage("jsoupHtml", JSON.stringify([id])); }
        function jsoupAttr(id, name) { return sendMessage("jsoupAttr", JSON.stringify([id, name])); }
        function jsoupRemove(id) { return sendMessage("jsoupRemove", JSON.stringify([id])); }
        function jsoupFirst(id) { return sendMessage("jsoupFirst", JSON.stringify([id])); }
        function jsoupLast(id) { return sendMessage("jsoupLast", JSON.stringify([id])); }
        function jsoupSize(id) { return sendMessage("jsoupSize", JSON.stringify([id])); }
        function jsoupGet(id, index) { return sendMessage("jsoupGet", JSON.stringify([id, index])); }
        function jsoupParent(id) { return sendMessage("jsoupParent", JSON.stringify([id])); }
        function log(message) { return sendMessage("log", JSON.stringify([message])); }
      ''';

      jsRuntime.evaluate(polyfill);

      if (request.scriptCode != null) {
        jsRuntime.evaluate(request.scriptCode!);
      }

      // Convert args to JSON for the method call
      final argsJson = jsonEncode(request.args);
      
      // Evaluate method call
      // e.g. execute("url")
      // Since it could be async (returning a Promise), we need to resolve it!
      // In QuickJS-NG with flutter_js/quickjs_engine, promises are resolved natively if we evaluate async code.
      // We wrap the call in an async function and await it.
      final callCode = '''
        (async function() {
          try {
            var res = await ${request.method}.apply(null, $argsJson);
            return JSON.stringify({ok: true, data: res});
          } catch(e) {
            return JSON.stringify({ok: false, error: e.toString()});
          }
        })();
      ''';
      
      final jsResult = jsRuntime.evaluate(callCode);
      
      // flutter_js 'evaluate' returns JavascriptRuntime.evaluate() which gives a rawResult.
      // If the result is a Promise, flutter_js handles it using handlePromise natively.
      return jsResult.stringResult;
    } finally {
      jsRuntime.dispose();
    }
  }
}
