import 'package:uuid/uuid.dart';

import '../../models/drive_metadata.dart';
import '../../models/search_index_state.dart';
import '../../models/search_index_story.dart';
import '../database/database_service.dart';
import '../google_drive_service.dart';
import 'search_index_repository.dart';
import 'search_text_normalizer.dart';

typedef DriveMetadataSnapshotLoader =
    Future<DriveMetadataSnapshot> Function(String folderInput);
typedef DriveFolderIdParser = String? Function(String folderInput);
typedef SearchIndexClock = DateTime Function();
typedef SearchIndexRunIdFactory = String Function();

class DriveMetadataIndexResult {
  const DriveMetadataIndexResult({
    required this.runId,
    required this.sourceId,
    required this.status,
    required this.indexedCount,
    required this.totalCount,
    required this.writtenCount,
    required this.unchangedCount,
    required this.deletedCount,
    required this.warningCount,
    this.errorCode,
  });

  final String runId;
  final String sourceId;
  final SearchIndexRunStatus status;
  final int indexedCount;
  final int? totalCount;
  final int writtenCount;
  final int unchangedCount;
  final int deletedCount;
  final int warningCount;
  final String? errorCode;
}

class DriveMetadataIndexer {
  DriveMetadataIndexer({
    required SearchIndexRepository repository,
    required DriveMetadataSnapshotLoader snapshotLoader,
    required DriveFolderIdParser folderIdParser,
    SearchIndexClock? clock,
    SearchIndexRunIdFactory? runIdFactory,
  }) : _repository = repository,
       _snapshotLoader = snapshotLoader,
       _folderIdParser = folderIdParser,
       _clock = clock ?? DateTime.now,
       _runIdFactory = runIdFactory ?? const Uuid().v4;

  static const String sourceType = 'googleDrive';
  static final DriveMetadataIndexer instance = DriveMetadataIndexer(
    repository: SearchIndexRepository(DatabaseService.instance),
    snapshotLoader: GoogleDriveService.fetchMetadataIndexSnapshot,
    folderIdParser: GoogleDriveService.extractFolderId,
  );

  final SearchIndexRepository _repository;
  final DriveMetadataSnapshotLoader _snapshotLoader;
  final DriveFolderIdParser _folderIdParser;
  final SearchIndexClock _clock;
  final SearchIndexRunIdFactory _runIdFactory;
  final Map<String, Future<DriveMetadataIndexResult>> _activeSyncs = {};

  Future<DriveMetadataIndexResult> synchronizeFolder(String folderInput) async {
    final sourceId = _folderIdParser(folderInput)?.trim();
    if (sourceId == null || sourceId.isEmpty) {
      throw ArgumentError.value(
        folderInput,
        'folderInput',
        'A valid Google Drive folder URL or ID is required.',
      );
    }

    final activeSync = _activeSyncs[sourceId];
    if (activeSync != null) return activeSync;

    final sync = _synchronizeSource(sourceId);
    _activeSyncs[sourceId] = sync;
    try {
      return await sync;
    } finally {
      if (identical(_activeSyncs[sourceId], sync)) {
        _activeSyncs.remove(sourceId);
      }
    }
  }

  Future<DriveMetadataIndexResult> _synchronizeSource(String sourceId) async {
    final startedAt = _clock().toUtc();
    final runId = _runIdFactory().trim();
    if (runId.isEmpty) {
      throw StateError('The search index run ID cannot be empty.');
    }

    await _repository.startIndexRun(
      SearchIndexRunRecord(
        runId: runId,
        sourceType: sourceType,
        sourceId: sourceId,
        status: SearchIndexRunStatus.indexing,
        indexedCount: 0,
        startedAt: startedAt,
      ),
    );

    var indexedCount = 0;
    int? totalCount;
    var writtenCount = 0;
    var unchangedCount = 0;
    var deletedCount = 0;
    var warningCount = 0;

    try {
      final snapshot = await _snapshotLoader(sourceId);
      warningCount = snapshot.warningCount;
      if (snapshot.sourceId.trim() != sourceId || warningCount < 0) {
        throw const _IndexSyncFailure('invalid_snapshot');
      }

      totalCount = snapshot.records.length;
      final existingStories = await _repository.loadStoriesForSource(
        sourceType: sourceType,
        sourceId: sourceId,
      );
      final existingJobs = await _repository.loadIndexJobsForSource(
        sourceType: sourceType,
        sourceId: sourceId,
      );
      final seenRemoteIds = <String>{};
      final storiesToWrite = <SearchIndexStory>[];
      final unchangedRemoteIds = <String>[];
      final jobsToWrite = <SearchIndexJobUpdate>[];
      final indexedAt = _clock().toUtc();
      var allMetadataComplete = true;

      for (final record in snapshot.records) {
        final remoteId = record.driveFileId.trim();
        if (remoteId.isEmpty || !seenRemoteIds.add(remoteId)) {
          throw const _IndexSyncFailure('invalid_snapshot');
        }

        final existing = existingStories[remoteId];
        final sameRevision =
            existing != null && _sameDriveRevision(existing, record);
        final candidate = _storyFromRecord(
          sourceId: sourceId,
          runId: runId,
          indexedAt: indexedAt,
          record: record,
          unchangedExisting: sameRevision ? existing : null,
        );
        final needsWrite =
            existing == null || !_sameStoredMetadata(existing, candidate);
        if (candidate.metadataStatus != SearchMetadataStatus.complete) {
          allMetadataComplete = false;
        }

        if (needsWrite) {
          storiesToWrite.add(candidate);
        } else {
          unchangedRemoteIds.add(remoteId);
        }

        final existingJob = existingJobs[remoteId];
        final desiredJobStatus =
            candidate.metadataStatus == SearchMetadataStatus.complete
            ? SearchIndexJobStatus.complete
            : SearchIndexJobStatus.pending;
        if (needsWrite ||
            existingJob == null ||
            existingJob.status == SearchIndexJobStatus.running ||
            existingJob.status != desiredJobStatus) {
          jobsToWrite.add(
            SearchIndexJobUpdate(
              sourceType: sourceType,
              sourceId: sourceId,
              remoteId: remoteId,
              driveFileId: remoteId,
              status: desiredJobStatus,
              updatedAt: indexedAt,
            ),
          );
        }
      }

      for (final batch in _batches(storiesToWrite)) {
        await _repository.upsertStories(batch);
        indexedCount += batch.length;
        writtenCount += batch.length;
      }
      for (final batch in _batches(unchangedRemoteIds)) {
        await _repository.markStoriesSeen(
          sourceType: sourceType,
          sourceId: sourceId,
          remoteIds: batch,
          runId: runId,
        );
        indexedCount += batch.length;
        unchangedCount += batch.length;
      }
      for (final batch in _batches(jobsToWrite)) {
        await _repository.upsertIndexJobs(batch);
      }

      if (snapshot.traversalComplete) {
        deletedCount = await _repository.deleteStoriesNotSeenInRun(
          sourceType: sourceType,
          sourceId: sourceId,
          runId: runId,
        );
      }

      final status =
          !snapshot.traversalComplete ||
              warningCount > 0 ||
              !allMetadataComplete
          ? SearchIndexRunStatus.partial
          : SearchIndexRunStatus.ready;
      final errorCode = !snapshot.traversalComplete
          ? 'traversal_incomplete'
          : warningCount > 0
          ? 'metadata_warning'
          : !allMetadataComplete
          ? 'metadata_partial'
          : null;

      await _repository.finishIndexRun(
        runId: runId,
        status: status,
        indexedCount: indexedCount,
        totalCount: totalCount,
        completedAt: _clock().toUtc(),
        errorCode: errorCode,
      );
      return DriveMetadataIndexResult(
        runId: runId,
        sourceId: sourceId,
        status: status,
        indexedCount: indexedCount,
        totalCount: totalCount,
        writtenCount: writtenCount,
        unchangedCount: unchangedCount,
        deletedCount: deletedCount,
        warningCount: warningCount,
        errorCode: errorCode,
      );
    } on _IndexSyncFailure catch (error) {
      return _finishFailedRun(
        runId: runId,
        sourceId: sourceId,
        indexedCount: indexedCount,
        totalCount: totalCount,
        writtenCount: writtenCount,
        unchangedCount: unchangedCount,
        warningCount: warningCount,
        errorCode: error.code,
      );
    } catch (_) {
      return _finishFailedRun(
        runId: runId,
        sourceId: sourceId,
        indexedCount: indexedCount,
        totalCount: totalCount,
        writtenCount: writtenCount,
        unchangedCount: unchangedCount,
        warningCount: warningCount,
        errorCode: 'sync_failed',
      );
    }
  }

  Future<DriveMetadataIndexResult> _finishFailedRun({
    required String runId,
    required String sourceId,
    required int indexedCount,
    required int? totalCount,
    required int writtenCount,
    required int unchangedCount,
    required int warningCount,
    required String errorCode,
  }) async {
    await _repository.finishIndexRun(
      runId: runId,
      status: SearchIndexRunStatus.error,
      indexedCount: indexedCount,
      totalCount: totalCount,
      completedAt: _clock().toUtc(),
      errorCode: errorCode,
    );
    return DriveMetadataIndexResult(
      runId: runId,
      sourceId: sourceId,
      status: SearchIndexRunStatus.error,
      indexedCount: indexedCount,
      totalCount: totalCount,
      writtenCount: writtenCount,
      unchangedCount: unchangedCount,
      deletedCount: 0,
      warningCount: warningCount,
      errorCode: errorCode,
    );
  }

  static SearchIndexStory _storyFromRecord({
    required String sourceId,
    required String runId,
    required DateTime indexedAt,
    required DriveMetadataRecord record,
    required SearchIndexStory? unchangedExisting,
  }) {
    final existing = unchangedExisting;
    final structuredMetadata = record.origin != DriveMetadataOrigin.driveFile;
    final incomingComplete =
        record.metadataStatus == SearchMetadataStatus.complete;

    String title = record.title.trim();
    String description = record.description.trim();
    List<String> authors = _canonicalLabels(record.authors);
    List<String> genres = _canonicalLabels(record.genres);
    var metadataStatus = record.metadataStatus;

    if (existing != null) {
      if (!structuredMetadata) {
        if (_metadataRank(existing.metadataStatus) >
            _metadataRank(SearchMetadataStatus.missing)) {
          title = existing.title;
        }
        description = existing.description;
        authors = existing.authors;
        genres = existing.genres;
      } else if (!incomingComplete) {
        if (description.isEmpty) description = existing.description;
        if (authors.isEmpty) authors = existing.authors;
        if (genres.isEmpty) genres = existing.genres;
      }
      if (_metadataRank(existing.metadataStatus) >
          _metadataRank(metadataStatus)) {
        metadataStatus = existing.metadataStatus;
      }
    }

    if (title.isEmpty) {
      throw const _IndexSyncFailure('invalid_snapshot');
    }

    return SearchIndexStory(
      sourceType: sourceType,
      sourceId: sourceId,
      remoteId: record.driveFileId.trim(),
      driveFileId: record.driveFileId.trim(),
      title: title,
      mimeType: record.mimeType.trim(),
      modifiedTime: record.modifiedTime?.toUtc() ?? existing?.modifiedTime,
      fileSize: record.fileSize ?? existing?.fileSize,
      checksum: _trimToNull(record.checksum) ?? existing?.checksum,
      description: description,
      coverFileId: _trimToNull(record.coverFileId) ?? existing?.coverFileId,
      coverUrl: _trimToNull(record.coverUrl) ?? existing?.coverUrl,
      coverLocalPath: existing?.coverLocalPath,
      metadataStatus: metadataStatus,
      lastSeenRunId: runId,
      lastIndexedAt: indexedAt,
      authors: authors,
      genres: genres,
    );
  }

  static bool _sameDriveRevision(
    SearchIndexStory existing,
    DriveMetadataRecord incoming,
  ) {
    final incomingChecksum = _trimToNull(incoming.checksum);
    final existingChecksum = _trimToNull(existing.checksum);
    if (incomingChecksum != null && existingChecksum != null) {
      return incomingChecksum == existingChecksum;
    }

    final incomingModified = incoming.modifiedTime?.toUtc();
    final existingModified = existing.modifiedTime?.toUtc();
    if (incomingModified == null || existingModified == null) return false;
    if (incomingModified != existingModified) return false;
    if (incoming.fileSize != null &&
        existing.fileSize != null &&
        incoming.fileSize != existing.fileSize) {
      return false;
    }
    return true;
  }

  static bool _sameStoredMetadata(
    SearchIndexStory existing,
    SearchIndexStory candidate,
  ) {
    return existing.sourceType == candidate.sourceType &&
        existing.sourceId == candidate.sourceId &&
        existing.remoteId == candidate.remoteId &&
        existing.driveFileId == candidate.driveFileId &&
        existing.title == candidate.title &&
        existing.mimeType == candidate.mimeType &&
        existing.modifiedTime?.toUtc() == candidate.modifiedTime?.toUtc() &&
        existing.fileSize == candidate.fileSize &&
        existing.checksum == candidate.checksum &&
        existing.description == candidate.description &&
        existing.coverFileId == candidate.coverFileId &&
        existing.coverUrl == candidate.coverUrl &&
        existing.coverLocalPath == candidate.coverLocalPath &&
        existing.metadataStatus == candidate.metadataStatus &&
        _sameLabels(existing.authors, candidate.authors) &&
        _sameLabels(existing.genres, candidate.genres);
  }

  static List<String> _canonicalLabels(Iterable<String> values) {
    final labels = <String, String>{};
    for (final value in values) {
      final original = value.trim();
      final normalized = SearchTextNormalizer.normalize(original);
      if (original.isNotEmpty && normalized.isNotEmpty) {
        labels.putIfAbsent(normalized, () => original);
      }
    }
    return labels.values.toList(growable: false);
  }

  static bool _sameLabels(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (SearchTextNormalizer.normalize(left[index]) !=
          SearchTextNormalizer.normalize(right[index])) {
        return false;
      }
    }
    return true;
  }

  static int _metadataRank(SearchMetadataStatus status) {
    return switch (status) {
      SearchMetadataStatus.complete => 4,
      SearchMetadataStatus.partial => 3,
      SearchMetadataStatus.missing => 2,
      SearchMetadataStatus.pending => 1,
      SearchMetadataStatus.error => 0,
    };
  }

  static String? _trimToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static Iterable<List<T>> _batches<T>(List<T> values) sync* {
    for (
      var start = 0;
      start < values.length;
      start += SearchIndexRepository.maxUpsertBatchSize
    ) {
      final end = start + SearchIndexRepository.maxUpsertBatchSize;
      yield values.sublist(start, end > values.length ? values.length : end);
    }
  }
}

class _IndexSyncFailure implements Exception {
  const _IndexSyncFailure(this.code);

  final String code;
}
