import 'dart:async';
import 'dart:collection';

import '../../models/plugin_info.dart';
import '../../models/source_models.dart';
import '../plugin/plugin_loader.dart';
import '../plugin/vbook_engine_channel.dart';
import 'extension_search_service.dart';

typedef ExtensionSessionSearch =
    Future<MangasPage> Function(PluginInfo plugin, String query, int page);

class ExtensionSearchRunner {
  ExtensionSearchRunner({
    ExtensionSessionSearch? execute,
    Future<String> Function(String)? resolveDirectory,
    this.timeout = const Duration(seconds: 35),
  }) : _execute =
           execute ??
           ((plugin, query, page) => _searchSession(
             plugin,
             query,
             page,
             resolveDirectory ?? PluginLoader.getPluginDir,
           ));

  static final instance = ExtensionSearchRunner();
  static const maxConcurrency = 2;
  static int _sessionSequence = 0;
  final Duration timeout;
  final ExtensionSessionSearch _execute;
  final Queue<Completer<void>> _queue = Queue();
  int _active = 0;

  Future<MangasPage> search(
    PluginInfo plugin,
    String query,
    int page, {
    required bool Function() isCurrent,
  }) async {
    var expired = false;
    final work = _withPermit(() {
      if (expired || !isCurrent()) {
        throw const VBookEngineException(
          code: 'EXEC_CANCELLED',
          operation: 'getSearchManga',
          message: 'Search cancelled.',
        );
      }
      return _execute(plugin, query, page);
    });
    // A UI timeout is not cancellation of native work. Hold its permit until
    // the real session and cleanup finish, including across new queries.
    return work.timeout(
      timeout,
      onTimeout: () {
        expired = true;
        throw TimeoutException('Extension search timed out.');
      },
    );
  }

  Future<T> _withPermit<T>(Future<T> Function() action) async {
    if (_active >= maxConcurrency) {
      final waiting = Completer<void>();
      _queue.add(waiting);
      await waiting.future;
    } else {
      _active++;
    }
    try {
      return await action();
    } finally {
      if (_queue.isEmpty) {
        _active--;
      } else {
        _queue.removeFirst().complete();
      }
    }
  }

  static Future<MangasPage> _searchSession(
    PluginInfo plugin,
    String query,
    int page,
    Future<String> Function(String) resolveDirectory,
  ) async {
    final directory = await resolveDirectory(plugin.id);
    final sessionId = 'vbook_unified_search_${++_sessionSequence}';
    try {
      final loaded = await VBookEngineChannel.loadSource(sessionId, directory);
      if (!loaded) {
        throw const VBookEngineException(
          code: 'LOAD_FAILED',
          operation: 'loadSource',
          message: 'Search source could not be loaded.',
        );
      }
      return await ExtensionSearchService().searchKeyword(
        plugin: plugin.copyWith(id: sessionId),
        query: query,
        page: page,
      );
    } finally {
      await VBookEngineChannel.closeSource(sessionId);
    }
  }
}
