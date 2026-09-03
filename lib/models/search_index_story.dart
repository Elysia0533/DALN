enum SearchMetadataStatus {
  pending('pending'),
  partial('partial'),
  complete('complete'),
  missing('missing'),
  error('error');

  const SearchMetadataStatus(this.storageValue);

  final String storageValue;

  static SearchMetadataStatus fromStorage(String value) {
    for (final status in values) {
      if (status.storageValue == value) return status;
    }
    throw FormatException('Unknown search metadata status: $value');
  }
}

class SearchIndexStory {
  SearchIndexStory({
    this.databaseId,
    required this.sourceType,
    required this.sourceId,
    required this.remoteId,
    this.driveFileId,
    required this.title,
    this.mimeType = '',
    this.modifiedTime,
    this.fileSize,
    this.checksum,
    this.description = '',
    this.coverFileId,
    this.coverUrl,
    this.coverLocalPath,
    this.metadataStatus = SearchMetadataStatus.pending,
    this.lastSeenRunId,
    required this.lastIndexedAt,
    List<String> authors = const [],
    List<String> genres = const [],
  }) : authors = List.unmodifiable(authors),
       genres = List.unmodifiable(genres);

  final int? databaseId;
  final String sourceType;
  final String sourceId;
  final String remoteId;
  final String? driveFileId;
  final String title;
  final String mimeType;
  final DateTime? modifiedTime;
  final int? fileSize;
  final String? checksum;
  final String description;
  final String? coverFileId;
  final String? coverUrl;
  final String? coverLocalPath;
  final SearchMetadataStatus metadataStatus;
  final String? lastSeenRunId;
  final DateTime lastIndexedAt;
  final List<String> authors;
  final List<String> genres;
}
