import 'package:uuid/uuid.dart';

import '../../models/drive_metadata.dart';
import '../../models/search_index_state.dart';
import '../../models/search_index_story.dart';
import '../database/database_service.dart';
import '../google_drive_service.dart';
import 'search_index_repository.dart';
import 'search_text_normalizer.dart';
import 'book_metadata_extractor.dart';
import 'epub_metadata_extractor.dart';
import 'txt_metadata_extractor.dart';

typedef DriveMetadataSnapshotLoader =
    Future<DriveMetadataSnapshot> Function(String folderInput);
typedef DriveFolderIdParser = String? Function(String folderInput);
typedef SearchIndexClock = DateTime Function();
typedef SearchIndexRunIdFactory = String Function();

typedef DriveIndexProgressCallback = void Function(DriveIndexProgress progress);

class DriveIndexProgress {
  const DriveIndexProgress({
    required this.indexedCount,
    required this.totalCount,
    required this.metadataChanged,
  });

  final int indexedCount;
  final int? totalCount;
  final bool metadataChanged;
}

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
    TxtMetadataLoader? txtMetadataLoader,
    BookMetadataLoader? epubMetadataLoader,
  }) : _repository = repository,
       _snapshotLoader = snapshotLoader,
       _folderIdParser = folderIdParser,
       _txtMetadataLoader = txtMetadataLoader,
       _epubMetadataLoader = epubMetadataLoader,
       _clock = clock ?? DateTime.now,
       _runIdFactory = runIdFactory ?? const Uuid().v4;

  static const String sourceType = 'googleDrive';
  static final DriveMetadataIndexer instance = DriveMetadataIndexer(
    repository: SearchIndexRepository(DatabaseService.instance),
    snapshotLoader: GoogleDriveService.fetchMetadataIndexSnapshot,
    folderIdParser: GoogleDriveService.extractFolderId,
    txtMetadataLoader: TxtMetadataExtractor.extract,
    epubMetadataLoader: EpubMetadataExtractor.extract,
  );

  final SearchIndexRepository _repository;
  final DriveMetadataSnapshotLoader _snapshotLoader;
  final DriveFolderIdParser _folderIdParser;
  final TxtMetadataLoader? _txtMetadataLoader;
  final BookMetadataLoader? _epubMetadataLoader;
  static const int currentExtractorVersion = 1;
  static const maxExtractionAttempts = 3;
  final SearchIndexClock _clock;
  final SearchIndexRunIdFactory _runIdFactory;
  final Map<String, Future<DriveMetadataIndexResult>> _activeSyncs = {};

  Future<DriveMetadataIndexResult> synchronizeFolder(
    String folderInput, {
    DriveIndexProgressCallback? onProgress,
    bool retryFailedExtractions = false,
  }) async {
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

    final sync = _synchronizeSource(
      sourceId,
      onProgress: onProgress,
      retryFailedExtractions: retryFailedExtractions,
    );
    _activeSyncs[sourceId] = sync;
    try {
      return await sync;
    } finally {
      if (identical(_activeSyncs[sourceId], sync)) {
        _activeSyncs.remove(sourceId);
      }
    }
  }

  Future<DriveMetadataIndexResult> _synchronizeSource(
    String sourceId, {
    DriveIndexProgressCallback? onProgress,
    required bool retryFailedExtractions,
  }) async {
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

      totalCount = snapshot.traversalComplete ? snapshot.records.length : null;
      final existingStories = await _repository.loadStoriesForSource(
        sourceType: sourceType,
        sourceId: sourceId,
      );
      final existingJobs = await _repository.loadIndexJobsForSource(
        sourceType: sourceType,
        sourceId: sourceId,
      );
      final seenRemoteIds = <String>{};
      // Validate identity across the snapshot before publishing any batch.
      for (final record in snapshot.records) {
        if (record.driveFileId.trim().isEmpty ||
            record.title.trim().isEmpty ||
            !seenRemoteIds.add(record.driveFileId.trim())) {
          throw const _IndexSyncFailure('invalid_snapshot');
        }
      }
      final storiesToWrite = <SearchIndexStory>[];
      final unchangedRemoteIds = <String>[];
      final jobsToWrite = <SearchIndexJobUpdate>[];
      final indexedAt = _clock().toUtc();
      var allMetadataComplete = true;
      var availableCount = existingStories.length;

      Future<void> publishBatch() async {
        if (storiesToWrite.isEmpty &&
            unchangedRemoteIds.isEmpty &&
            jobsToWrite.isEmpty) {
          return;
        }
        final metadataChanged = storiesToWrite.isNotEmpty;
        if (storiesToWrite.isNotEmpty) {
          await _repository.upsertStories(storiesToWrite);
        }
        writtenCount += storiesToWrite.length;
        availableCount += storiesToWrite
            .where((story) => !existingStories.containsKey(story.remoteId))
            .length;
        if (unchangedRemoteIds.isNotEmpty) {
          await _repository.markStoriesSeen(
            sourceType: sourceType,
            sourceId: sourceId,
            remoteIds: unchangedRemoteIds,
            runId: runId,
          );
        }
        unchangedCount += unchangedRemoteIds.length;
        // A completed job must never precede its searchable metadata commit.
        if (jobsToWrite.isNotEmpty) {
          await _repository.upsertIndexJobs(jobsToWrite);
        }
        storiesToWrite.clear();
        unchangedRemoteIds.clear();
        jobsToWrite.clear();
        onProgress?.call(
          DriveIndexProgress(
            indexedCount: availableCount,
            totalCount: totalCount != null && totalCount >= availableCount
                ? totalCount
                : null,
            metadataChanged: metadataChanged,
          ),
        );
      }

      for (final records in _batches(snapshot.records, size: 2)) {
        final prepared = await Future.wait([
          for (final record in records)
            _prepareRecord(
              sourceId: sourceId,
              runId: runId,
              indexedAt: indexedAt,
              record: record,
              existing: existingStories[record.driveFileId.trim()],
              existingJob: existingJobs[record.driveFileId.trim()],
              retryFailedExtractions: retryFailedExtractions,
            ),
        ]);
        for (final result in prepared) {
          final candidate = result.story;
          final remoteId = candidate.remoteId;
          final existing = existingStories[remoteId];
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
          final job = result.job;
          if (job.status == SearchIndexJobStatus.error) warningCount++;
          if (needsWrite ||
              existingJob == null ||
              existingJob.status == SearchIndexJobStatus.running ||
              existingJob.status != job.status ||
              existingJob.attempts != job.attempts ||
              existingJob.errorCode != job.errorCode) {
            jobsToWrite.add(job);
          }
        }
        // Keep fast catalog writes batched; publish slow extraction results
        // before starting the next network pair instead of buffering a root.
        if (prepared.any((result) => result.didExtract) ||
            storiesToWrite.length + unchangedRemoteIds.length >=
                SearchIndexRepository.maxUpsertBatchSize) {
          await publishBatch();
        }
      }
      await publishBatch();

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

      indexedCount = await _repository.countStories(
        sourceType: sourceType,
        sourceId: sourceId,
      );
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
    required int? totalCount,
    required int writtenCount,
    required int unchangedCount,
    required int warningCount,
    required String errorCode,
  }) async {
    final availableCount = await _repository.countStories(
      sourceType: sourceType,
      sourceId: sourceId,
    );
    final knownTotal = totalCount != null && totalCount >= availableCount
        ? totalCount
        : null;
    await _repository.finishIndexRun(
      runId: runId,
      status: SearchIndexRunStatus.error,
      indexedCount: availableCount,
      totalCount: knownTotal,
      completedAt: _clock().toUtc(),
      errorCode: errorCode,
    );
    return DriveMetadataIndexResult(
      runId: runId,
      sourceId: sourceId,
      status: SearchIndexRunStatus.error,
      indexedCount: availableCount,
      totalCount: knownTotal,
      writtenCount: writtenCount,
      unchangedCount: unchangedCount,
      deletedCount: 0,
      warningCount: warningCount,
      errorCode: errorCode,
    );
  }

  Future<_PreparedMetadata> _prepareRecord({
    required String sourceId,
    required String runId,
    required DateTime indexedAt,
    required DriveMetadataRecord record,
    required SearchIndexStory? existing,
    required SearchIndexJobUpdate? existingJob,
    required bool retryFailedExtractions,
  }) async {
    final sameRevision =
        existing != null && _sameDriveRevision(existing, record);
    var candidate = _storyFromRecord(
      sourceId: sourceId,
      runId: runId,
      indexedAt: indexedAt,
      record: record,
      unchangedExisting: sameRevision ? existing : null,
    );
    var status = candidate.metadataStatus == SearchMetadataStatus.complete
        ? SearchIndexJobStatus.complete
        : SearchIndexJobStatus.pending;
    var attempts = sameRevision ? existingJob?.attempts ?? 0 : 0;
    var didExtract = false;
    String? errorCode;
    final mimeType = record.mimeType.trim().toLowerCase();
    final BookMetadataLoader? loader = switch (mimeType) {
      'text/plain' => _txtMetadataLoader,
      'application/epub+zip' => _epubMetadataLoader,
      _ => null,
    };
    final failureCode = mimeType == 'text/plain'
        ? 'txt_extraction_failed'
        : 'epub_extraction_failed';
    final hasRevision =
        _trimToNull(record.checksum) != null || record.modifiedTime != null;
    final oldExtractor =
        existing != null &&
        existing.extractorVersion != currentExtractorVersion;

    final needsExtraction =
        status != SearchIndexJobStatus.complete || oldExtractor;
    final allowedToExtract = hasRevision;

    if (loader != null && needsExtraction && allowedToExtract) {
      if (mimeType == 'application/epub+zip' &&
          (record.fileSize ?? 0) > GoogleDriveService.epubMetadataMaxBytes) {
        status = SearchIndexJobStatus.error;
        errorCode = 'epub_size_limit';
      } else if (sameRevision &&
          !oldExtractor &&
          existingJob?.status == SearchIndexJobStatus.complete) {
        status = SearchIndexJobStatus.complete;
      } else if (sameRevision &&
          attempts >= maxExtractionAttempts &&
          existingJob?.status != SearchIndexJobStatus.running &&
          !(retryFailedExtractions &&
              existingJob?.status == SearchIndexJobStatus.error &&
              existingJob?.errorCode == failureCode)) {
        status = SearchIndexJobStatus.error;
        errorCode = failureCode;
      } else {
        // Keep cumulative attempts for manual retries: a finished failure
        // must not reset the automatic budget. Interrupted-job recovery stays.
        didExtract = true;
        attempts++;
        await _repository.upsertIndexJobs([
          SearchIndexJobUpdate(
            sourceType: sourceType,
            sourceId: sourceId,
            remoteId: candidate.remoteId,
            driveFileId: candidate.driveFileId,
            status: SearchIndexJobStatus.running,
            attempts: attempts,
            updatedAt: indexedAt,
          ),
        ]);
        try {
          final extracted = await loader(candidate.remoteId);
          candidate = _mergeExtractedMetadata(candidate, record, extracted);
          status = SearchIndexJobStatus.complete;
        } catch (_) {
          status = SearchIndexJobStatus.error;
          errorCode = failureCode;
        }
      }
    }
    return _PreparedMetadata(
      candidate,
      SearchIndexJobUpdate(
        sourceType: sourceType,
        sourceId: sourceId,
        remoteId: candidate.remoteId,
        driveFileId: candidate.driveFileId,
        status: status,
        attempts: attempts,
        errorCode: errorCode,
        updatedAt: indexedAt,
      ),
      didExtract: didExtract,
    );
  }

  static SearchIndexStory _mergeExtractedMetadata(
    SearchIndexStory story,
    DriveMetadataRecord record,
    BookMetadata metadata,
  ) {
    final extractedTitle = _trimToNull(metadata.title);
    final title =
        record.origin == DriveMetadataOrigin.driveFile && extractedTitle != null
        ? extractedTitle
        : story.title;
    final authors = story.authors.isEmpty
        ? _canonicalLabels(metadata.authors)
        : story.authors;
    final genres = story.genres.isEmpty
        ? _canonicalLabels(metadata.genres)
        : story.genres;
    final titleHasEvidence =
        record.origin != DriveMetadataOrigin.driveFile ||
        extractedTitle != null;
    final complete =
        titleHasEvidence && authors.isNotEmpty && genres.isNotEmpty;
    final foundMetadata =
        extractedTitle != null ||
        authors.isNotEmpty ||
        genres.isNotEmpty ||
        metadata.description.isNotEmpty;
    return SearchIndexStory(
      sourceType: story.sourceType,
      sourceId: story.sourceId,
      remoteId: story.remoteId,
      driveFileId: story.driveFileId,
      title: title,
      authors: authors,
      genres: genres,
      mimeType: story.mimeType,
      modifiedTime: story.modifiedTime,
      fileSize: story.fileSize,
      checksum: story.checksum,
      description: story.description.isNotEmpty
          ? story.description
          : metadata.description,
      coverFileId: story.coverFileId,
      coverUrl: story.coverUrl,
      coverLocalPath: story.coverLocalPath,
      lastIndexedAt: story.lastIndexedAt,
      lastSeenRunId: story.lastSeenRunId,
      metadataStatus: complete
          ? SearchMetadataStatus.complete
          : foundMetadata
          ? SearchMetadataStatus.partial
          : story.metadataStatus,
      extractorVersion: currentExtractorVersion,
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
      extractorVersion: existing?.extractorVersion,
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
    if (existing.mimeType.trim().toLowerCase() !=
        incoming.mimeType.trim().toLowerCase()) {
      return false;
    }
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

  static Iterable<List<T>> _batches<T>(
    List<T> values, {
    int size = SearchIndexRepository.maxUpsertBatchSize,
  }) sync* {
    for (var start = 0; start < values.length; start += size) {
      final end = start + size;
      yield values.sublist(start, end > values.length ? values.length : end);
    }
  }
}

class _PreparedMetadata {
  const _PreparedMetadata(this.story, this.job, {required this.didExtract});
  final SearchIndexStory story;
  final SearchIndexJobUpdate job;
  final bool didExtract;
}

class _IndexSyncFailure implements Exception {
  const _IndexSyncFailure(this.code);

  final String code;
}
