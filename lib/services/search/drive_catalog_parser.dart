import 'dart:convert';
import 'dart:typed_data';

import '../../models/drive_metadata.dart';
import '../../models/search_index_story.dart';

class DriveCatalogParseResult {
  DriveCatalogParseResult({
    required List<DriveMetadataRecord> records,
    required this.skippedEntries,
    required this.schemaVersion,
  }) : records = List.unmodifiable(records);

  final List<DriveMetadataRecord> records;
  final int skippedEntries;
  final int? schemaVersion;
}

abstract final class DriveCatalogParser {
  static const int supportedSchemaVersion = 1;
  static const int maxCatalogBytes = 5 * 1024 * 1024;
  static const int maxCatalogEntries = 50000;

  static DriveCatalogParseResult parseBytes(
    Uint8List bytes, {
    required String expectedSourceId,
  }) {
    if (bytes.length > maxCatalogBytes) {
      throw const FormatException('Drive catalog exceeds the size limit.');
    }
    return parseDecoded(
      jsonDecode(utf8.decode(bytes)),
      expectedSourceId: expectedSourceId,
    );
  }

  static DriveCatalogParseResult parseDecoded(
    Object? decoded, {
    required String expectedSourceId,
  }) {
    final List<dynamic> rawStories;
    int? schemaVersion;

    if (decoded is List) {
      rawStories = decoded;
    } else if (decoded is Map) {
      final document = Map<String, dynamic>.from(decoded);
      schemaVersion = _readInt(document['schemaVersion']);
      if (schemaVersion != null && schemaVersion != supportedSchemaVersion) {
        throw FormatException(
          'Unsupported Drive catalog schema version: $schemaVersion',
        );
      }

      final source = document['source'];
      if (source is Map) {
        final declaredSourceId = _readString(source['rootFolderId']);
        if (declaredSourceId != null &&
            expectedSourceId.isNotEmpty &&
            declaredSourceId != expectedSourceId) {
          throw const FormatException(
            'Drive catalog source does not match its containing folder.',
          );
        }
      }

      final stories = document['stories'];
      if (stories is! List) {
        throw const FormatException(
          'Drive catalog must contain a stories array.',
        );
      }
      rawStories = stories;
    } else {
      throw const FormatException(
        'Drive catalog must be an array or a versioned object.',
      );
    }

    if (rawStories.length > maxCatalogEntries) {
      throw const FormatException('Drive catalog contains too many entries.');
    }

    final records = <DriveMetadataRecord>[];
    var skippedEntries = 0;
    for (final rawStory in rawStories) {
      if (rawStory is! Map) {
        skippedEntries++;
        continue;
      }
      final record = _parseRecord(Map<String, dynamic>.from(rawStory));
      if (record == null) {
        skippedEntries++;
      } else {
        records.add(record);
      }
    }

    return DriveCatalogParseResult(
      records: records,
      skippedEntries: skippedEntries,
      schemaVersion: schemaVersion,
    );
  }

  static DriveMetadataRecord? _parseRecord(Map<String, dynamic> map) {
    final chapterOrder = _readStringList(map['chapterOrder']);
    final driveFileId =
        _readString(map['driveFileId']) ??
        _readString(map['fileId']) ??
        (chapterOrder.isEmpty ? null : chapterOrder.first);
    if (driveFileId == null) return null;

    final fileName = _readString(map['fileName']) ?? '';
    final title =
        _readString(map['title']) ??
        _cleanFileName(fileName.isEmpty ? driveFileId : fileName);
    if (title.isEmpty) return null;

    final cover = map['cover'];
    final coverMap = cover is Map ? Map<String, dynamic>.from(cover) : null;
    final coverFileId =
        _readString(coverMap?['driveFileId']) ??
        _readString(map['coverFileId']) ??
        _readString(map['coverId']);
    final coverUrl =
        _readString(coverMap?['url']) ??
        _readString(map['coverUrl']) ??
        _readString(map['iconUrl']);
    final explicitStatus = _readString(map['metadataStatus']);
    final metadataStatus = explicitStatus == null
        ? SearchMetadataStatus.partial
        : _parseStatus(explicitStatus);
    if (metadataStatus == null) return null;

    final fileSize = _readInt(map['size']) ?? _readInt(map['fileSize']);
    return DriveMetadataRecord(
      driveFileId: driveFileId,
      fileName: fileName,
      title: title,
      mimeType:
          _readString(map['mimeType']) ??
          _mimeTypeFor(
            _readString(map['fileType']) ??
                _readString(map['type']) ??
                fileName,
          ),
      modifiedTime: DateTime.tryParse(
        _readString(map['modifiedTime']) ?? '',
      )?.toUtc(),
      fileSize: fileSize != null && fileSize >= 0 ? fileSize : null,
      checksum: _readString(map['md5Checksum']) ?? _readString(map['checksum']),
      description: _readString(map['description']) ?? '',
      coverFileId: coverFileId,
      coverUrl: coverUrl,
      metadataStatus: metadataStatus,
      origin: DriveMetadataOrigin.catalog,
      authors: _readAuthors(map),
      genres: _readStringList(map['genres']),
    );
  }

  static SearchMetadataStatus? _parseStatus(String value) {
    final normalized = value.trim().toLowerCase();
    for (final status in SearchMetadataStatus.values) {
      if (status.storageValue == normalized) return status;
    }
    return null;
  }

  static List<String> _readAuthors(Map<String, dynamic> map) {
    final authors = _readStringList(map['authors']);
    if (authors.isNotEmpty) return authors;
    final author = _readString(map['author']);
    return author == null ? const [] : [author];
  }

  static List<String> _readStringList(Object? value) {
    if (value is List) {
      return value.map(_readString).whereType<String>().toList(growable: false);
    }
    if (value is String && value.trim().isNotEmpty) {
      return value
          .split(',')
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }

  static String _mimeTypeFor(String value) {
    final extension = value.split('.').last.toLowerCase();
    return switch (extension) {
      'epub' => 'application/epub+zip',
      'pdf' => 'application/pdf',
      'txt' => 'text/plain',
      _ => '',
    };
  }

  static String _cleanFileName(String value) {
    return value
        .replaceAll(RegExp(r'\.(epub|pdf|txt)$', caseSensitive: false), '')
        .trim();
  }

  static String? _readString(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}
