import 'package:sqflite/sqflite.dart';

import '../../models/search_index_state.dart';
import '../../models/search_index_story.dart';
import '../database/database_service.dart';
import 'search_text_normalizer.dart';

class SearchIndexRepository {
  SearchIndexRepository(this._databaseService);

  static const int maxUpsertBatchSize = 100;
  static const int _queryParameterBatchSize = 400;

  final DatabaseService _databaseService;

  Future<void> upsertStories(Iterable<SearchIndexStory> stories) async {
    final input = stories.toList(growable: false);
    if (input.isEmpty) return;
    if (input.length > maxUpsertBatchSize) {
      throw ArgumentError.value(
        input.length,
        'stories',
        'A metadata write batch cannot exceed $maxUpsertBatchSize stories.',
      );
    }

    final prepared = input
        .map(_PreparedStory.fromStory)
        .toList(growable: false);
    _validateBatchIdentities(prepared);

    final database = await _databaseService.database;
    await database.transaction((transaction) async {
      final existingStories = await _queryStoryIds(transaction, prepared);
      final authorLabels = _collectLabels(
        prepared.expand((story) => story.authors),
      );
      final genreLabels = _collectLabels(
        prepared.expand((story) => story.genres),
      );
      final existingAuthors = await _queryLabelIds(
        transaction,
        table: 'authors',
        normalizedNames: authorLabels.keys,
      );
      final existingGenres = await _queryLabelIds(
        transaction,
        table: 'genres',
        normalizedNames: genreLabels.keys,
      );

      final entityBatch = transaction.batch();
      for (final story in prepared) {
        final existingId = existingStories[story.identity];
        if (existingId == null) {
          entityBatch.insert('stories', story.toDatabaseValues());
        } else {
          entityBatch.update(
            'stories',
            story.toDatabaseValues(),
            where: 'id = ?',
            whereArgs: [existingId],
          );
        }
      }
      _writeLabels(
        entityBatch,
        table: 'authors',
        labels: authorLabels,
        existingIds: existingAuthors,
      );
      _writeLabels(
        entityBatch,
        table: 'genres',
        labels: genreLabels,
        existingIds: existingGenres,
      );
      await entityBatch.commit(noResult: true);

      final storyIds = await _queryStoryIds(transaction, prepared);
      final authorIds = await _queryLabelIds(
        transaction,
        table: 'authors',
        normalizedNames: authorLabels.keys,
      );
      final genreIds = await _queryLabelIds(
        transaction,
        table: 'genres',
        normalizedNames: genreLabels.keys,
      );

      final relationBatch = transaction.batch();
      for (final story in prepared) {
        final storyId = storyIds[story.identity];
        if (storyId == null) {
          throw StateError('A persisted search-index story could not be read.');
        }

        relationBatch.delete(
          'story_authors',
          where: 'story_id = ?',
          whereArgs: [storyId],
        );
        relationBatch.delete(
          'story_genres',
          where: 'story_id = ?',
          whereArgs: [storyId],
        );

        for (var position = 0; position < story.authors.length; position++) {
          final author = story.authors[position];
          final authorId = authorIds[author.normalized];
          if (authorId == null) {
            throw StateError(
              'A persisted search-index author could not be read.',
            );
          }
          relationBatch.insert('story_authors', {
            'story_id': storyId,
            'author_id': authorId,
            'position': position,
          });
        }

        for (var position = 0; position < story.genres.length; position++) {
          final genre = story.genres[position];
          final genreId = genreIds[genre.normalized];
          if (genreId == null) {
            throw StateError(
              'A persisted search-index genre could not be read.',
            );
          }
          relationBatch.insert('story_genres', {
            'story_id': storyId,
            'genre_id': genreId,
            'position': position,
          });
        }
      }
      await relationBatch.commit(noResult: true);
    });
  }

  Future<SearchIndexStory?> findByIdentity({
    required String sourceType,
    required String sourceId,
    required String remoteId,
  }) async {
    final database = await _databaseService.database;
    final rows = await database.query(
      'stories',
      where: 'source_type = ? AND source_id = ? AND remote_id = ?',
      whereArgs: [sourceType.trim(), sourceId.trim(), remoteId.trim()],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _hydrateStory(database, rows.single);
  }

  Future<SearchIndexStory?> findByDriveFileId(String driveFileId) async {
    final database = await _databaseService.database;
    final rows = await database.query(
      'stories',
      where: 'drive_file_id = ?',
      whereArgs: [driveFileId.trim()],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _hydrateStory(database, rows.single);
  }

  Future<int> countStories() async {
    final database = await _databaseService.database;
    final rows = await database.rawQuery(
      'SELECT COUNT(*) AS story_count FROM stories',
    );
    return (rows.single['story_count'] as num).toInt();
  }

  Future<Map<String, SearchIndexStory>> loadStoriesForSource({
    required String sourceType,
    required String sourceId,
  }) async {
    final normalizedSourceType = sourceType.trim();
    final normalizedSourceId = sourceId.trim();
    if (normalizedSourceType.isEmpty || normalizedSourceId.isEmpty) {
      throw ArgumentError('Search-index source identity cannot be empty.');
    }

    final database = await _databaseService.database;
    final storyRows = await database.query(
      'stories',
      where: 'source_type = ? AND source_id = ?',
      whereArgs: [normalizedSourceType, normalizedSourceId],
    );
    if (storyRows.isEmpty) return {};

    final relationArguments = [normalizedSourceType, normalizedSourceId];
    final authorRows = await database.rawQuery(
      'SELECT story_authors.story_id, story_authors.position, authors.name '
      'FROM story_authors '
      'INNER JOIN authors ON authors.id = story_authors.author_id '
      'INNER JOIN stories ON stories.id = story_authors.story_id '
      'WHERE stories.source_type = ? AND stories.source_id = ? '
      'ORDER BY story_authors.story_id, story_authors.position',
      relationArguments,
    );
    final genreRows = await database.rawQuery(
      'SELECT story_genres.story_id, story_genres.position, genres.name '
      'FROM story_genres '
      'INNER JOIN genres ON genres.id = story_genres.genre_id '
      'INNER JOIN stories ON stories.id = story_genres.story_id '
      'WHERE stories.source_type = ? AND stories.source_id = ? '
      'ORDER BY story_genres.story_id, story_genres.position',
      relationArguments,
    );
    final authorsByStory = _groupRelationNames(authorRows);
    final genresByStory = _groupRelationNames(genreRows);

    return {
      for (final row in storyRows)
        row['remote_id'] as String: _storyFromDatabaseRow(
          row,
          authors: authorsByStory[(row['id'] as num).toInt()] ?? const [],
          genres: genresByStory[(row['id'] as num).toInt()] ?? const [],
        ),
    };
  }

  Future<void> markStoriesSeen({
    required String sourceType,
    required String sourceId,
    required Iterable<String> remoteIds,
    required String runId,
  }) async {
    final normalizedSourceType = sourceType.trim();
    final normalizedSourceId = sourceId.trim();
    final normalizedRunId = runId.trim();
    if (normalizedSourceType.isEmpty ||
        normalizedSourceId.isEmpty ||
        normalizedRunId.isEmpty) {
      throw ArgumentError('Seen-marker identity fields cannot be empty.');
    }
    final ids = remoteIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) return;
    if (ids.length > maxUpsertBatchSize) {
      throw ArgumentError.value(
        ids.length,
        'remoteIds',
        'A seen-marker batch cannot exceed $maxUpsertBatchSize stories.',
      );
    }

    final database = await _databaseService.database;
    await database.transaction((transaction) async {
      final batch = transaction.batch();
      for (final remoteId in ids) {
        batch.update(
          'stories',
          {'last_seen_run_id': normalizedRunId},
          where: 'source_type = ? AND source_id = ? AND remote_id = ?',
          whereArgs: [normalizedSourceType, normalizedSourceId, remoteId],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<int> deleteStoriesNotSeenInRun({
    required String sourceType,
    required String sourceId,
    required String runId,
  }) async {
    final normalizedSourceType = sourceType.trim();
    final normalizedSourceId = sourceId.trim();
    final normalizedRunId = runId.trim();
    if (normalizedSourceType.isEmpty ||
        normalizedSourceId.isEmpty ||
        normalizedRunId.isEmpty) {
      throw ArgumentError('Reconciliation identity fields cannot be empty.');
    }
    final database = await _databaseService.database;
    return database.transaction((transaction) async {
      final arguments = [
        normalizedSourceType,
        normalizedSourceId,
        normalizedRunId,
      ];
      final deleted = await transaction.rawDelete(
        'DELETE FROM stories '
        'WHERE source_type = ? AND source_id = ? '
        'AND (last_seen_run_id IS NULL OR last_seen_run_id <> ?)',
        arguments,
      );
      await transaction.rawDelete(
        'DELETE FROM index_jobs '
        'WHERE source_type = ? AND source_id = ? '
        'AND NOT EXISTS ('
        'SELECT 1 FROM stories '
        'WHERE stories.source_type = index_jobs.source_type '
        'AND stories.source_id = index_jobs.source_id '
        'AND stories.remote_id = index_jobs.remote_id'
        ')',
        [normalizedSourceType, normalizedSourceId],
      );
      return deleted;
    });
  }

  Future<void> startIndexRun(SearchIndexRunRecord run) async {
    if (run.status != SearchIndexRunStatus.indexing) {
      throw ArgumentError('A new index run must start in indexing state.');
    }
    _validateRunValues(
      runId: run.runId,
      sourceType: run.sourceType,
      sourceId: run.sourceId,
      indexedCount: run.indexedCount,
      totalCount: run.totalCount,
    );
    final database = await _databaseService.database;
    await database.insert('index_runs', {
      'run_id': run.runId.trim(),
      'source_type': run.sourceType.trim(),
      'source_id': run.sourceId.trim(),
      'status': run.status.storageValue,
      'indexed_count': run.indexedCount,
      'total_count': run.totalCount,
      'started_at': run.startedAt.toUtc().millisecondsSinceEpoch,
      'completed_at': run.completedAt?.toUtc().millisecondsSinceEpoch,
      'last_error': _trimToNull(run.errorCode),
    });
  }

  Future<void> finishIndexRun({
    required String runId,
    required SearchIndexRunStatus status,
    required int indexedCount,
    required int? totalCount,
    required DateTime completedAt,
    String? errorCode,
  }) async {
    if (status == SearchIndexRunStatus.indexing) {
      throw ArgumentError('A finished index run cannot remain indexing.');
    }
    final normalizedRunId = runId.trim();
    if (normalizedRunId.isEmpty ||
        indexedCount < 0 ||
        (totalCount != null && totalCount < 0)) {
      throw ArgumentError('Finished index-run values are invalid.');
    }
    final database = await _databaseService.database;
    final updated = await database.update(
      'index_runs',
      {
        'status': status.storageValue,
        'indexed_count': indexedCount,
        'total_count': totalCount,
        'completed_at': completedAt.toUtc().millisecondsSinceEpoch,
        'last_error': _trimToNull(errorCode),
      },
      where: 'run_id = ?',
      whereArgs: [normalizedRunId],
    );
    if (updated != 1) {
      throw StateError('The search index run no longer exists.');
    }
  }

  Future<SearchIndexRunRecord?> latestIndexRun({
    required String sourceType,
    required String sourceId,
  }) async {
    final database = await _databaseService.database;
    final rows = await database.query(
      'index_runs',
      where: 'source_type = ? AND source_id = ?',
      whereArgs: [sourceType.trim(), sourceId.trim()],
      orderBy: 'started_at DESC, rowid DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final completedAt = (row['completed_at'] as num?)?.toInt();
    return SearchIndexRunRecord(
      runId: row['run_id'] as String,
      sourceType: row['source_type'] as String,
      sourceId: row['source_id'] as String,
      status: SearchIndexRunStatus.fromStorage(row['status'] as String),
      indexedCount: (row['indexed_count'] as num).toInt(),
      totalCount: (row['total_count'] as num?)?.toInt(),
      startedAt: DateTime.fromMillisecondsSinceEpoch(
        (row['started_at'] as num).toInt(),
        isUtc: true,
      ),
      completedAt: completedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(completedAt, isUtc: true),
      errorCode: row['last_error'] as String?,
    );
  }

  Future<SearchIndexState> readIndexState({
    required String sourceType,
    required String sourceId,
  }) async {
    final run = await latestIndexRun(
      sourceType: sourceType,
      sourceId: sourceId,
    );
    if (run == null) return const SearchIndexState.notStarted();

    return SearchIndexState(
      status: switch (run.status) {
        SearchIndexRunStatus.indexing => SearchIndexStatus.indexing,
        SearchIndexRunStatus.ready => SearchIndexStatus.ready,
        SearchIndexRunStatus.partial => SearchIndexStatus.partial,
        SearchIndexRunStatus.error => SearchIndexStatus.error,
      },
      indexedCount: run.indexedCount,
      totalCount: run.totalCount,
      lastIndexedAt: run.completedAt ?? run.startedAt,
      errorCode: run.errorCode,
    );
  }

  Future<void> upsertIndexJobs(
    Iterable<SearchIndexJobUpdate> jobUpdates,
  ) async {
    final jobs = jobUpdates.toList(growable: false);
    if (jobs.isEmpty) return;
    if (jobs.length > maxUpsertBatchSize) {
      throw ArgumentError.value(
        jobs.length,
        'jobUpdates',
        'An index-job batch cannot exceed $maxUpsertBatchSize jobs.',
      );
    }

    final database = await _databaseService.database;
    await database.transaction((transaction) async {
      final batch = transaction.batch();
      for (final job in jobs) {
        final sourceType = job.sourceType.trim();
        final sourceId = job.sourceId.trim();
        final remoteId = job.remoteId.trim();
        if (sourceType.isEmpty ||
            sourceId.isEmpty ||
            remoteId.isEmpty ||
            job.attempts < 0) {
          throw ArgumentError('Index-job values are invalid.');
        }
        batch.insert('index_jobs', {
          'source_type': sourceType,
          'source_id': sourceId,
          'remote_id': remoteId,
          'drive_file_id': _trimToNull(job.driveFileId),
          'status': job.status.storageValue,
          'attempts': job.attempts,
          'last_error': _trimToNull(job.errorCode),
          'updated_at': job.updatedAt.toUtc().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<Map<String, SearchIndexJobUpdate>> loadIndexJobsForSource({
    required String sourceType,
    required String sourceId,
  }) async {
    final normalizedSourceType = sourceType.trim();
    final normalizedSourceId = sourceId.trim();
    if (normalizedSourceType.isEmpty || normalizedSourceId.isEmpty) {
      throw ArgumentError('Index-job source identity cannot be empty.');
    }

    final database = await _databaseService.database;
    final rows = await database.query(
      'index_jobs',
      where: 'source_type = ? AND source_id = ?',
      whereArgs: [normalizedSourceType, normalizedSourceId],
    );
    return {
      for (final row in rows)
        row['remote_id'] as String: SearchIndexJobUpdate(
          sourceType: row['source_type'] as String,
          sourceId: row['source_id'] as String,
          remoteId: row['remote_id'] as String,
          driveFileId: row['drive_file_id'] as String?,
          status: SearchIndexJobStatus.fromStorage(row['status'] as String),
          attempts: (row['attempts'] as num).toInt(),
          errorCode: row['last_error'] as String?,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (row['updated_at'] as num).toInt(),
            isUtc: true,
          ),
        ),
    };
  }

  static void _validateBatchIdentities(List<_PreparedStory> stories) {
    final identities = <(String, String, String)>{};
    final driveFileIds = <String>{};
    for (final story in stories) {
      if (!identities.add(story.identity)) {
        throw ArgumentError(
          'A metadata batch contains a duplicate story identity.',
        );
      }
      final driveFileId = story.driveFileId;
      if (driveFileId != null && !driveFileIds.add(driveFileId)) {
        throw ArgumentError(
          'A metadata batch contains a duplicate Drive file ID.',
        );
      }
    }
  }

  static Future<Map<(String, String, String), int>> _queryStoryIds(
    DatabaseExecutor database,
    List<_PreparedStory> stories,
  ) async {
    if (stories.isEmpty) return {};

    final clauses = <String>[];
    final arguments = <Object?>[];
    for (final story in stories) {
      clauses.add('(source_type = ? AND source_id = ? AND remote_id = ?)');
      arguments.addAll([story.sourceType, story.sourceId, story.remoteId]);
    }

    final rows = await database.rawQuery(
      'SELECT id, source_type, source_id, remote_id FROM stories '
      'WHERE ${clauses.join(' OR ')}',
      arguments,
    );
    return {
      for (final row in rows)
        (
          row['source_type'] as String,
          row['source_id'] as String,
          row['remote_id'] as String,
        ): (row['id'] as num)
            .toInt(),
    };
  }

  static Map<String, String> _collectLabels(Iterable<_PreparedLabel> labels) {
    final result = <String, String>{};
    for (final label in labels) {
      result[label.normalized] = label.original;
    }
    return result;
  }

  static Future<Map<String, int>> _queryLabelIds(
    DatabaseExecutor database, {
    required String table,
    required Iterable<String> normalizedNames,
  }) async {
    final names = normalizedNames.toList(growable: false);
    final result = <String, int>{};
    for (
      var start = 0;
      start < names.length;
      start += _queryParameterBatchSize
    ) {
      final end = start + _queryParameterBatchSize < names.length
          ? start + _queryParameterBatchSize
          : names.length;
      final chunk = names.sublist(start, end);
      final placeholders = List.filled(chunk.length, '?').join(', ');
      final rows = await database.rawQuery(
        'SELECT id, normalized_name FROM $table '
        'WHERE normalized_name IN ($placeholders)',
        chunk,
      );
      for (final row in rows) {
        result[row['normalized_name'] as String] = (row['id'] as num).toInt();
      }
    }
    return result;
  }

  static void _writeLabels(
    Batch batch, {
    required String table,
    required Map<String, String> labels,
    required Map<String, int> existingIds,
  }) {
    for (final entry in labels.entries) {
      final values = {'name': entry.value, 'normalized_name': entry.key};
      final existingId = existingIds[entry.key];
      if (existingId == null) {
        batch.insert(table, values);
      } else {
        batch.update(table, values, where: 'id = ?', whereArgs: [existingId]);
      }
    }
  }

  static Future<SearchIndexStory> _hydrateStory(
    DatabaseExecutor database,
    Map<String, Object?> row,
  ) async {
    final storyId = (row['id'] as num).toInt();
    final authorRows = await database.rawQuery(
      'SELECT authors.name FROM authors '
      'INNER JOIN story_authors ON story_authors.author_id = authors.id '
      'WHERE story_authors.story_id = ? ORDER BY story_authors.position',
      [storyId],
    );
    final genreRows = await database.rawQuery(
      'SELECT genres.name FROM genres '
      'INNER JOIN story_genres ON story_genres.genre_id = genres.id '
      'WHERE story_genres.story_id = ? ORDER BY story_genres.position',
      [storyId],
    );
    return _storyFromDatabaseRow(
      row,
      authors: [for (final author in authorRows) author['name'] as String],
      genres: [for (final genre in genreRows) genre['name'] as String],
    );
  }

  static Map<int, List<String>> _groupRelationNames(
    Iterable<Map<String, Object?>> rows,
  ) {
    final namesByStory = <int, List<String>>{};
    for (final row in rows) {
      final storyId = (row['story_id'] as num).toInt();
      namesByStory
          .putIfAbsent(storyId, () => <String>[])
          .add(row['name'] as String);
    }
    return namesByStory;
  }

  static SearchIndexStory _storyFromDatabaseRow(
    Map<String, Object?> row, {
    required List<String> authors,
    required List<String> genres,
  }) {
    final storyId = (row['id'] as num).toInt();
    final modifiedTime = (row['modified_time'] as num?)?.toInt();
    final lastIndexedAt = (row['last_indexed_at'] as num).toInt();
    return SearchIndexStory(
      databaseId: storyId,
      sourceType: row['source_type'] as String,
      sourceId: row['source_id'] as String,
      remoteId: row['remote_id'] as String,
      driveFileId: row['drive_file_id'] as String?,
      title: row['title'] as String,
      mimeType: row['mime_type'] as String,
      modifiedTime: modifiedTime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(modifiedTime, isUtc: true),
      fileSize: (row['file_size'] as num?)?.toInt(),
      checksum: row['checksum'] as String?,
      description: row['description'] as String,
      coverFileId: row['cover_file_id'] as String?,
      coverUrl: row['cover_url'] as String?,
      coverLocalPath: row['cover_local_path'] as String?,
      metadataStatus: SearchMetadataStatus.fromStorage(
        row['metadata_status'] as String,
      ),
      lastSeenRunId: row['last_seen_run_id'] as String?,
      lastIndexedAt: DateTime.fromMillisecondsSinceEpoch(
        lastIndexedAt,
        isUtc: true,
      ),
      authors: authors,
      genres: genres,
    );
  }

  static String? _trimToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static void _validateRunValues({
    required String runId,
    required String sourceType,
    required String sourceId,
    required int indexedCount,
    required int? totalCount,
  }) {
    if (runId.trim().isEmpty ||
        sourceType.trim().isEmpty ||
        sourceId.trim().isEmpty ||
        indexedCount < 0 ||
        (totalCount != null && totalCount < 0)) {
      throw ArgumentError('Index-run values are invalid.');
    }
  }
}

class _PreparedStory {
  _PreparedStory({
    required this.sourceType,
    required this.sourceId,
    required this.remoteId,
    required this.driveFileId,
    required this.title,
    required this.normalizedTitle,
    required this.mimeType,
    required this.modifiedTime,
    required this.fileSize,
    required this.checksum,
    required this.description,
    required this.coverFileId,
    required this.coverUrl,
    required this.coverLocalPath,
    required this.metadataStatus,
    required this.lastSeenRunId,
    required this.lastIndexedAt,
    required this.authors,
    required this.genres,
  });

  factory _PreparedStory.fromStory(SearchIndexStory story) {
    final sourceType = story.sourceType.trim();
    final sourceId = story.sourceId.trim();
    final remoteId = story.remoteId.trim();
    final title = story.title.trim();
    final normalizedTitle = SearchTextNormalizer.normalize(title);
    if (sourceType.isEmpty || sourceId.isEmpty || remoteId.isEmpty) {
      throw ArgumentError(
        'Search-index source identity fields cannot be empty.',
      );
    }
    if (title.isEmpty || normalizedTitle.isEmpty) {
      throw ArgumentError('A search-index story title cannot be empty.');
    }
    if (story.fileSize != null && story.fileSize! < 0) {
      throw ArgumentError.value(
        story.fileSize,
        'fileSize',
        'File size cannot be negative.',
      );
    }

    return _PreparedStory(
      sourceType: sourceType,
      sourceId: sourceId,
      remoteId: remoteId,
      driveFileId: _trimToNull(story.driveFileId),
      title: title,
      normalizedTitle: normalizedTitle,
      mimeType: story.mimeType.trim(),
      modifiedTime: story.modifiedTime?.toUtc().millisecondsSinceEpoch,
      fileSize: story.fileSize,
      checksum: _trimToNull(story.checksum),
      description: story.description.trim(),
      coverFileId: _trimToNull(story.coverFileId),
      coverUrl: _trimToNull(story.coverUrl),
      coverLocalPath: _trimToNull(story.coverLocalPath),
      metadataStatus: story.metadataStatus.storageValue,
      lastSeenRunId: _trimToNull(story.lastSeenRunId),
      lastIndexedAt: story.lastIndexedAt.toUtc().millisecondsSinceEpoch,
      authors: _prepareLabels(story.authors),
      genres: _prepareLabels(story.genres),
    );
  }

  final String sourceType;
  final String sourceId;
  final String remoteId;
  final String? driveFileId;
  final String title;
  final String normalizedTitle;
  final String mimeType;
  final int? modifiedTime;
  final int? fileSize;
  final String? checksum;
  final String description;
  final String? coverFileId;
  final String? coverUrl;
  final String? coverLocalPath;
  final String metadataStatus;
  final String? lastSeenRunId;
  final int lastIndexedAt;
  final List<_PreparedLabel> authors;
  final List<_PreparedLabel> genres;

  (String, String, String) get identity => (sourceType, sourceId, remoteId);

  Map<String, Object?> toDatabaseValues() {
    return {
      'source_type': sourceType,
      'source_id': sourceId,
      'remote_id': remoteId,
      'drive_file_id': driveFileId,
      'title': title,
      'normalized_title': normalizedTitle,
      'mime_type': mimeType,
      'modified_time': modifiedTime,
      'file_size': fileSize,
      'checksum': checksum,
      'description': description,
      'cover_file_id': coverFileId,
      'cover_url': coverUrl,
      'cover_local_path': coverLocalPath,
      'metadata_status': metadataStatus,
      'last_seen_run_id': lastSeenRunId,
      'last_indexed_at': lastIndexedAt,
    };
  }

  static List<_PreparedLabel> _prepareLabels(Iterable<String> values) {
    final labels = <String, _PreparedLabel>{};
    for (final value in values) {
      final original = value.trim();
      final normalized = SearchTextNormalizer.normalize(original);
      if (original.isEmpty || normalized.isEmpty) continue;
      labels.putIfAbsent(
        normalized,
        () => _PreparedLabel(original: original, normalized: normalized),
      );
    }
    return labels.values.toList(growable: false);
  }

  static String? _trimToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

class _PreparedLabel {
  const _PreparedLabel({required this.original, required this.normalized});

  final String original;
  final String normalized;
}
