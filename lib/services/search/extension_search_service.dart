import '../../models/plugin_info.dart';
import '../../models/source_models.dart';
import '../plugin/vbook_engine_channel.dart';

typedef ExtensionKeywordSearchExecutor =
    Future<MangasPage?> Function(String sourceId, String query, int page);

class ExtensionSearchCapabilityException implements Exception {
  const ExtensionSearchCapabilityException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => message;
}

class ExtensionSearchService {
  ExtensionSearchService({ExtensionKeywordSearchExecutor? keywordExecutor})
    : _keywordExecutor = keywordExecutor ?? VBookEngineChannel.getSearchManga;

  final ExtensionKeywordSearchExecutor _keywordExecutor;

  Future<MangasPage> searchKeyword({
    required PluginInfo plugin,
    required String query,
    int page = 1,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      throw ArgumentError.value(
        query,
        'query',
        'Search query cannot be empty.',
      );
    }
    if (page < 1) {
      throw ArgumentError.value(page, 'page', 'Page must be at least 1.');
    }

    final capabilities = plugin.searchCapabilities;
    if (!capabilities.supportsKeyword) {
      throw const ExtensionSearchCapabilityException(
        code: 'KEYWORD_UNSUPPORTED',
        message: 'Nguồn này không hỗ trợ tìm kiếm theo từ khóa.',
      );
    }
    if (page > 1 && !capabilities.supportsPagination) {
      throw const ExtensionSearchCapabilityException(
        code: 'PAGINATION_UNSUPPORTED',
        message: 'Nguồn này không hỗ trợ tải thêm kết quả tìm kiếm.',
      );
    }

    final result = await _keywordExecutor(plugin.id, normalizedQuery, page);
    if (result == null) {
      throw const VBookEngineException(
        code: 'INVALID_RESPONSE',
        operation: 'getSearchManga',
        message: 'The extension engine returned an invalid response.',
      );
    }

    return MangasPage(
      result.mangas,
      capabilities.supportsPagination && result.hasNextPage,
    );
  }
}
