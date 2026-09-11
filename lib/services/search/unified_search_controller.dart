import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/unified_search.dart';
import '../plugin/vbook_engine_channel.dart';
import 'unified_search_gateway.dart';

class UnifiedSearchController extends ChangeNotifier {
  UnifiedSearchController(this.gateway);

  final UnifiedSearchGateway gateway;
  final Map<String, SourceSearchState> _states = {};
  final Map<String, int> _requests = {};
  int _generation = 0;
  bool _disposed = false;
  UnifiedSearchQuery _query = const UnifiedSearchQuery();

  List<SourceSearchState> get states => List.unmodifiable(_states.values);

  void clear() {
    _generation++;
    _states.clear();
    _requests.clear();
    if (!_disposed) notifyListeners();
  }

  Future<void> search(
    Iterable<SearchSource> sources,
    UnifiedSearchQuery query,
  ) async {
    if (_disposed) return;
    final selected = sources.toList();
    final generation = ++_generation;
    _query = query;
    _states.clear();
    _requests.clear();
    for (final source in selected) {
      _states[source.key] = SourceSearchState(source: source);
    }
    if (!_disposed) notifyListeners();
    if (query.isEmpty) return;
    await Future.wait([
      for (final source in selected) _load(source, query, 1, generation),
    ]);
  }

  Future<void> loadMore(String key) async {
    final state = _states[key];
    if (state == null ||
        state.status == SourceSearchStatus.loading ||
        state.nextPage == null) {
      return;
    }
    await _load(state.source, _query, state.nextPage!, _generation);
  }

  Future<void> retry(String key) async {
    final state = _states[key];
    if (state == null || state.status != SourceSearchStatus.error) return;
    await _load(state.source, _query, state.failedPage ?? 1, _generation);
  }

  Future<void> refreshSource(String key) async {
    final state = _states[key];
    if (_disposed || state == null || _query.isEmpty) return;
    await _load(state.source, _query, 1, _generation, preserveResults: true);
  }

  Future<void> _load(
    SearchSource source,
    UnifiedSearchQuery query,
    int page,
    int generation, {
    bool preserveResults = false,
  }) async {
    if (_disposed || generation != _generation) return;
    final request = (_requests[source.key] ?? 0) + 1;
    _requests[source.key] = request;
    bool current() =>
        !_disposed &&
        generation == _generation &&
        _requests[source.key] == request;
    final capabilities = source.capabilities;
    final unsupported =
        query.author != null && !capabilities.supportsAuthor ||
        query.genre != null && !capabilities.supportsGenre ||
        query.text.trim().isNotEmpty && !capabilities.supportsKeyword;
    if (unsupported) {
      _states[source.key] = SourceSearchState(
        source: source,
        status: SourceSearchStatus.unsupported,
        message: 'Nguồn này không hỗ trợ điều kiện tìm kiếm đã chọn.',
      );
      notifyListeners();
      return;
    }
    final previous = _states[source.key]!;
    final retained = page > 1 || preserveResults
        ? previous.items
        : <SearchResult>[];
    _states[source.key] = SourceSearchState(
      source: source,
      status: SourceSearchStatus.loading,
      items: retained,
      nextPage: previous.nextPage,
    );
    notifyListeners();
    try {
      final result = await gateway.search(
        source,
        query,
        page,
        isCurrent: current,
      );
      if (!current()) return;
      final byIdentity = {
        if (page > 1)
          for (final item in retained) item.stableId: item,
      };
      var added = 0;
      for (final item in result.items) {
        if (!byIdentity.containsKey(item.stableId)) added++;
        byIdentity[item.stableId] = item;
      }
      _states[source.key] = SourceSearchState(
        source: source,
        status: SourceSearchStatus.ready,
        items: byIdentity.values,
        nextPage:
            capabilities.supportsPagination &&
                (page == 1 || added > 0) &&
                (result.nextPage ?? 0) > page
            ? result.nextPage
            : null,
        message: page > 1 && added == 0 && result.nextPage != null
            ? 'Nguồn không trả thêm kết quả mới.'
            : null,
      );
    } catch (error) {
      if (!current()) return;
      _states[source.key] = SourceSearchState(
        source: source,
        status: SourceSearchStatus.error,
        items: retained,
        nextPage: previous.nextPage,
        failedPage: page,
        message: _message(error),
      );
    }
    if (current()) notifyListeners();
  }

  static String _message(Object error) {
    if (error is TimeoutException ||
        error is VBookEngineException && error.code == 'EXEC_TIMEOUT') {
      return 'Nguồn phản hồi quá lâu. Bạn có thể thử lại.';
    }
    if (error is VBookEngineException && error.code == 'NETWORK_ERROR') {
      return 'Không kết nối được nguồn truyện.';
    }
    return 'Không tải được kết quả từ nguồn này. Vui lòng thử lại.';
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
