import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/models/search_index_story.dart';
import 'package:online_story_reader/services/search/drive_catalog_parser.dart';

void main() {
  test('parses a versioned Drive catalog without losing revision metadata', () {
    final result = DriveCatalogParser.parseBytes(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'schemaVersion': 1,
            'source': {'rootFolderId': 'root'},
            'stories': [
              {
                'driveFileId': 'file-1',
                'fileName': 'Story.epub',
                'title': 'Story title',
                'authors': ['Author A', 'Author B'],
                'genres': ['Fantasy'],
                'modifiedTime': '2026-09-01T10:15:00Z',
                'size': '4096',
                'md5Checksum': 'checksum-1',
                'metadataStatus': 'complete',
                'cover': {
                  'driveFileId': 'cover-1',
                  'url': 'https://example.invalid/cover.jpg',
                },
              },
            ],
          }),
        ),
      ),
      expectedSourceId: 'root',
    );

    expect(result.schemaVersion, 1);
    expect(result.skippedEntries, 0);
    expect(result.records, hasLength(1));
    final record = result.records.single;
    expect(record.driveFileId, 'file-1');
    expect(record.title, 'Story title');
    expect(record.authors, const ['Author A', 'Author B']);
    expect(record.genres, const ['Fantasy']);
    expect(record.modifiedTime, DateTime.utc(2026, 9, 1, 10, 15));
    expect(record.fileSize, 4096);
    expect(record.checksum, 'checksum-1');
    expect(record.coverFileId, 'cover-1');
    expect(record.metadataStatus, SearchMetadataStatus.complete);
  });

  test('keeps legacy catalog compatibility and skips malformed entries', () {
    final result = DriveCatalogParser.parseDecoded([
      {'fileId': 'legacy-file', 'title': 'Legacy story'},
      {'title': 'Missing identity'},
      'not-an-object',
    ], expectedSourceId: 'root');

    expect(result.schemaVersion, isNull);
    expect(result.records.single.driveFileId, 'legacy-file');
    expect(result.skippedEntries, 2);
  });

  test('rejects unsupported schemas and a mismatched source folder', () {
    expect(
      () => DriveCatalogParser.parseDecoded({
        'schemaVersion': 2,
        'stories': <Object>[],
      }, expectedSourceId: 'root'),
      throwsFormatException,
    );
    expect(
      () => DriveCatalogParser.parseDecoded({
        'schemaVersion': 1,
        'source': {'rootFolderId': 'another-root'},
        'stories': <Object>[],
      }, expectedSourceId: 'root'),
      throwsFormatException,
    );
  });
}
