import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:online_story_reader/models/drive_metadata.dart';
import 'package:online_story_reader/models/search_index_story.dart';
import 'package:online_story_reader/services/google_drive_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'metadata snapshot prefers catalog and never downloads book content',
    () async {
      final downloadedFileIds = <String>[];
      var requestedChecksumField = false;
      final client = _metadataClient(
        folders: {
          'root': [_folder('book-folder', 'Book folder')],
          'book-folder': [
            _file(
              'story-1',
              'Fallback.epub',
              modifiedTime: '2026-09-01T10:15:00Z',
              size: '8192',
              checksum: 'drive-checksum',
            ),
            _file('cover-1', 'cover.jpg', mimeType: 'image/jpeg'),
            _file('info-1', 'info.json', mimeType: 'application/json'),
            _file(
              'catalog-1',
              'catalog.vbook.json',
              mimeType: 'application/json',
            ),
          ],
        },
        downloads: {
          'info-1': {'title': 'Sidecar title', 'author': 'Sidecar author'},
          'catalog-1': {
            'schemaVersion': 1,
            'source': {'rootFolderId': 'book-folder'},
            'stories': [
              {
                'driveFileId': 'story-1',
                'title': 'Catalog title',
                'authors': ['Catalog author'],
                'genres': ['Fantasy'],
                'metadataStatus': 'complete',
                'cover': {'driveFileId': 'cover-1'},
              },
            ],
          },
        },
        onDownload: downloadedFileIds.add,
        onFields: (fields) {
          requestedChecksumField = fields.contains('md5Checksum');
        },
        remotePageSize: 2,
      );

      final snapshot =
          await GoogleDriveService.fetchMetadataIndexSnapshotForTesting(
            client: client,
            rootFolderId: 'root',
          );

      expect(snapshot.sourceId, 'root');
      expect(snapshot.traversalComplete, isTrue);
      expect(snapshot.warningCount, 0);
      expect(snapshot.records, hasLength(1));
      final record = snapshot.records.single;
      expect(record.origin, DriveMetadataOrigin.catalog);
      expect(record.driveFileId, 'story-1');
      expect(record.title, 'Catalog title');
      expect(record.authors, const ['Catalog author']);
      expect(record.genres, const ['Fantasy']);
      expect(record.modifiedTime, DateTime.utc(2026, 9, 1, 10, 15));
      expect(record.fileSize, 8192);
      expect(record.checksum, 'drive-checksum');
      expect(record.coverFileId, 'cover-1');
      expect(record.metadataStatus, SearchMetadataStatus.complete);
      expect(downloadedFileIds, containsAll(<String>['info-1', 'catalog-1']));
      expect(downloadedFileIds, isNot(contains('story-1')));
      expect(requestedChecksumField, isTrue);
    },
  );

  test(
    'stale catalog entries do not resurrect files deleted from Drive',
    () async {
      final client = _metadataClient(
        folders: {
          'root': [
            _file('story-present', 'Present.epub'),
            _file('catalog-1', 'catalog.json', mimeType: 'application/json'),
          ],
        },
        downloads: {
          'catalog-1': {
            'schemaVersion': 1,
            'source': {'rootFolderId': 'root'},
            'stories': [
              {
                'driveFileId': 'story-present',
                'title': 'Present',
                'metadataStatus': 'complete',
              },
              {
                'driveFileId': 'story-deleted',
                'title': 'Deleted',
                'metadataStatus': 'complete',
              },
            ],
          },
        },
      );

      final snapshot =
          await GoogleDriveService.fetchMetadataIndexSnapshotForTesting(
            client: client,
            rootFolderId: 'root',
          );

      expect(snapshot.traversalComplete, isTrue);
      expect(snapshot.warningCount, 1);
      expect(snapshot.records.map((record) => record.driveFileId), const [
        'story-present',
      ]);
    },
  );
}

MockClient _metadataClient({
  required Map<String, List<Map<String, dynamic>>> folders,
  Map<String, Object?> downloads = const {},
  void Function(String fileId)? onDownload,
  void Function(String fields)? onFields,
  int? remotePageSize,
}) {
  return MockClient((request) async {
    expect(request.url.host, 'www.googleapis.com');
    expect(request.url.queryParameters['key'], 'test-api-key');

    if (request.url.queryParameters['alt'] == 'media') {
      final fileId = request.url.pathSegments.last;
      onDownload?.call(fileId);
      final data = downloads[fileId];
      if (data == null) return http.Response('Not found', 404);
      return http.Response(
        jsonEncode(data),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }

    onFields?.call(request.url.queryParameters['fields'] ?? '');
    final query = request.url.queryParameters['q'] ?? '';
    final folderId = RegExp(
      r"^'([^']+)' in parents",
    ).firstMatch(query)?.group(1);
    if (folderId == null) return http.Response('Invalid query', 400);
    final allFiles = folders[folderId] ?? <Map<String, dynamic>>[];
    final requestedPageSize =
        int.tryParse(request.url.queryParameters['pageSize'] ?? '') ?? 1000;
    final pageSize = remotePageSize == null
        ? requestedPageSize
        : remotePageSize < requestedPageSize
        ? remotePageSize
        : requestedPageSize;
    final pageToken = request.url.queryParameters['pageToken'];
    final offset = pageToken == null
        ? 0
        : int.parse(pageToken.replaceFirst('offset-', ''));
    final files = allFiles.skip(offset).take(pageSize).toList(growable: false);
    final nextOffset = offset + files.length;
    return http.Response(
      jsonEncode({
        'files': files,
        if (nextOffset < allFiles.length) 'nextPageToken': 'offset-$nextOffset',
      }),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  });
}

Map<String, dynamic> _folder(String id, String name) {
  return {
    'id': id,
    'name': name,
    'mimeType': 'application/vnd.google-apps.folder',
  };
}

Map<String, dynamic> _file(
  String id,
  String name, {
  String mimeType = 'application/octet-stream',
  String? modifiedTime,
  String? size,
  String? checksum,
}) {
  final result = <String, dynamic>{
    'id': id,
    'name': name,
    'mimeType': mimeType,
  };
  if (modifiedTime != null) result['modifiedTime'] = modifiedTime;
  if (size != null) result['size'] = size;
  if (checksum != null) result['md5Checksum'] = checksum;
  return result;
}
