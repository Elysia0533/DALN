enum SearchIndexRunStatus {
  indexing('indexing'),
  ready('ready'),
  partial('partial'),
  error('error');

  const SearchIndexRunStatus(this.storageValue);

  final String storageValue;

  static SearchIndexRunStatus fromStorage(String value) {
    for (final status in values) {
      if (status.storageValue == value) return status;
    }
    throw FormatException('Unknown search index run status: $value');
  }
}

enum SearchIndexStatus { notStarted, indexing, ready, partial, error }

class SearchIndexState {
  const SearchIndexState({
    required this.status,
    required this.indexedCount,
    this.totalCount,
    this.lastIndexedAt,
    this.errorCode,
  });

  const SearchIndexState.notStarted()
    : status = SearchIndexStatus.notStarted,
      indexedCount = 0,
      totalCount = null,
      lastIndexedAt = null,
      errorCode = null;

  final SearchIndexStatus status;
  final int indexedCount;
  final int? totalCount;
  final DateTime? lastIndexedAt;
  final String? errorCode;
}

class SearchIndexRunRecord {
  const SearchIndexRunRecord({
    required this.runId,
    required this.sourceType,
    required this.sourceId,
    required this.status,
    required this.indexedCount,
    this.totalCount,
    required this.startedAt,
    this.completedAt,
    this.errorCode,
  });

  final String runId;
  final String sourceType;
  final String sourceId;
  final SearchIndexRunStatus status;
  final int indexedCount;
  final int? totalCount;
  final DateTime startedAt;
  final DateTime? completedAt;
  final String? errorCode;
}

enum SearchIndexJobStatus {
  pending('pending'),
  running('running'),
  complete('complete'),
  error('error');

  const SearchIndexJobStatus(this.storageValue);

  final String storageValue;

  static SearchIndexJobStatus fromStorage(String value) {
    for (final status in values) {
      if (status.storageValue == value) return status;
    }
    throw FormatException('Unknown search index job status: $value');
  }
}

class SearchIndexJobUpdate {
  const SearchIndexJobUpdate({
    required this.sourceType,
    required this.sourceId,
    required this.remoteId,
    this.driveFileId,
    required this.status,
    this.attempts = 0,
    this.errorCode,
    required this.updatedAt,
  });

  final String sourceType;
  final String sourceId;
  final String remoteId;
  final String? driveFileId;
  final SearchIndexJobStatus status;
  final int attempts;
  final String? errorCode;
  final DateTime updatedAt;
}
