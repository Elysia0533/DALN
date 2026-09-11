import 'dart:convert';
import 'dart:math';

import '../../models/search_index_story.dart';
import '../../models/search_index_state.dart';
import '../../models/story.dart';
import '../../models/unified_search.dart';
import '../api_service.dart';
import '../database/database_service.dart';
import 'search_index_repository.dart';

class LocalLibrarySearchIndex {
  LocalLibrarySearchIndex({
    required SearchIndexRepository repository,
    Future<List<Story>> Function()? loadStories,
  }) : _repository = repository,
       _loadStories =
           loadStories ??
           (() => ApiService.fetchPersonalStories(repairCovers: false));

  static final instance = LocalLibrarySearchIndex(
    repository: SearchIndexRepository(DatabaseService.instance),
  );
  static const sourceType = 'local';
  static const sourceId = 'personal_library';
  final SearchIndexRepository _repository;
  final Future<List<Story>> Function() _loadStories;
  Future<void>? _sync;
  String? _lastMetadata;
  Map<String, Story> _stories = {};

  Future<void> synchronize() {
    return _sync ??= _synchronize().whenComplete(() => _sync = null);
  }

  Future<void> _synchronize() async {
    // Keep the preference library authoritative; SQLite contains metadata only.
    final library = await _loadStories();
    final stories = <String, Story>{};
    for (final story in library) {
      if (story.id.trim().isEmpty ||
          story.id != story.id.trim() ||
          story.title.trim().isEmpty ||
          stories.containsKey(story.id)) {
        throw const FormatException('Invalid library identity.');
      }
      stories[story.id] = story;
    }
    final metadata = jsonEncode([
      for (final story in stories.values)
        [
          story.id,
          story.title,
          story.author,
          story.genres,
          story.description,
          story.iconUrl,
          story.fileType,
        ],
    ]);
    if (metadata != _lastMetadata) {
      final now = DateTime.now().toUtc();
      final runId = 'local_${now.microsecondsSinceEpoch}';
      await _repository.startIndexRun(
        SearchIndexRunRecord(
          runId: runId,
          sourceType: sourceType,
          sourceId: sourceId,
          status: SearchIndexRunStatus.indexing,
          indexedCount: 0,
          totalCount: stories.length,
          startedAt: now,
        ),
      );
      final records = [
        for (final story in stories.values)
          SearchIndexStory(
            sourceType: sourceType,
            sourceId: sourceId,
            remoteId: story.id,
            title: story.title,
            authors: story.author.trim().isEmpty ? [] : [story.author],
            genres: story.genres,
            description: story.description,
            coverUrl: story.iconUrl,
            mimeType: story.fileType,
            metadataStatus: SearchMetadataStatus.partial,
            lastSeenRunId: runId,
            lastIndexedAt: now,
          ),
      ];
      try {
        for (
          var offset = 0;
          offset < records.length;
          offset += SearchIndexRepository.maxUpsertBatchSize
        ) {
          await _repository.upsertStories(
            records.sublist(
              offset,
              min(
                records.length,
                offset + SearchIndexRepository.maxUpsertBatchSize,
              ),
            ),
          );
        }
        await _repository.deleteStoriesNotSeenInRun(
          sourceType: sourceType,
          sourceId: sourceId,
          runId: runId,
        );
        await _repository.finishIndexRun(
          runId: runId,
          status: SearchIndexRunStatus.ready,
          indexedCount: records.length,
          totalCount: records.length,
          completedAt: DateTime.now().toUtc(),
        );
      } catch (_) {
        await _repository.finishIndexRun(
          runId: runId,
          status: SearchIndexRunStatus.error,
          indexedCount: 0,
          totalCount: records.length,
          completedAt: DateTime.now().toUtc(),
          errorCode: 'library_index_failed',
        );
        rethrow;
      }
      _lastMetadata = metadata;
    }
    _stories = stories;
  }

  Future<SourceSearchPage> search(
    SearchSource source,
    UnifiedSearchQuery query,
    int page, {
    int pageSize = 30,
  }) async {
    await synchronize();
    final result = await _repository.searchByKeyword(
      query: query.text,
      authors: query.author == null ? [] : [query.author!],
      genres: query.genre == null ? [] : [query.genre!],
      sourceType: sourceType,
      sourceId: sourceId,
      limit: pageSize,
      offset: (page - 1) * pageSize,
    );
    return SourceSearchPage(
      items: [
        for (final item in result.items)
          if (_stories[item.remoteId] case final Story story)
            SearchResult(source: source, remoteId: item.remoteId, story: story),
      ],
      nextPage: result.hasMore ? page + 1 : null,
    );
  }

  Future<SearchFacets> facets() async {
    await synchronize();
    return SearchFacets(
      authors: await _repository.listAuthors(
        sourceType: sourceType,
        sourceId: sourceId,
      ),
      genres: await _repository.listGenres(
        sourceType: sourceType,
        sourceId: sourceId,
      ),
    );
  }
}
