import 'search_index_story.dart';

enum DriveMetadataOrigin { catalog, sidecar, driveFile }

class DriveMetadataRecord {
  DriveMetadataRecord({
    required this.driveFileId,
    required this.fileName,
    required this.title,
    required this.mimeType,
    this.modifiedTime,
    this.fileSize,
    this.checksum,
    this.description = '',
    this.coverFileId,
    this.coverUrl,
    this.metadataStatus = SearchMetadataStatus.partial,
    this.origin = DriveMetadataOrigin.driveFile,
    List<String> authors = const [],
    List<String> genres = const [],
  }) : authors = List.unmodifiable(authors),
       genres = List.unmodifiable(genres);

  final String driveFileId;
  final String fileName;
  final String title;
  final String mimeType;
  final DateTime? modifiedTime;
  final int? fileSize;
  final String? checksum;
  final String description;
  final String? coverFileId;
  final String? coverUrl;
  final SearchMetadataStatus metadataStatus;
  final DriveMetadataOrigin origin;
  final List<String> authors;
  final List<String> genres;
}

class DriveMetadataSnapshot {
  DriveMetadataSnapshot({
    required this.sourceId,
    required List<DriveMetadataRecord> records,
    required this.traversalComplete,
    this.warningCount = 0,
  }) : records = List.unmodifiable(records);

  final String sourceId;
  final List<DriveMetadataRecord> records;
  final bool traversalComplete;
  final int warningCount;
}
