import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:online_story_reader/services/google_drive_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Drive request limiter never exceeds its concurrency cap', () async {
    final limiter = RequestConcurrencyLimiter(maxConcurrency: 3);
    var activeOperations = 0;
    var peakActiveOperations = 0;

    Future<void> runTraversal() async {
      for (var index = 0; index < 20; index++) {
        await limiter.run(() async {
          activeOperations++;
          if (activeOperations > peakActiveOperations) {
            peakActiveOperations = activeOperations;
          }
          try {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          } finally {
            activeOperations--;
          }
        });
      }
    }

    await Future.wait([for (var index = 0; index < 4; index++) runTraversal()]);

    expect(peakActiveOperations, 3);
    expect(limiter.activeRequests, 0);
  });

  test('Drive pagination descends into nested folders', () async {
    final client = _folderClient({
      'root': [_folder('folder-a', 'A'), _folder('folder-b', 'B')],
      'folder-a': [
        _file('story-1', 'Alpha.epub'),
        _file('story-2', 'Beta.pdf'),
      ],
      'folder-b': [_folder('folder-c', 'C'), _file('story-3', 'Gamma.txt')],
      'folder-c': [_file('story-4', 'Delta.epub')],
    });

    final firstPage = await GoogleDriveService.fetchStoriesPageForTesting(
      client: client,
      rootFolderIds: const ['root'],
      pageSize: 2,
    );

    expect(firstPage.items.map((story) => story.driveFileId), [
      'story-1',
      'story-2',
    ]);
    expect(firstPage.hasMore, isTrue);
    expect(firstPage.nextPageToken, isNotEmpty);

    final secondPage = await GoogleDriveService.fetchStoriesPageForTesting(
      client: client,
      rootFolderIds: const ['root'],
      pageSize: 2,
      pageToken: firstPage.nextPageToken,
    );

    expect(secondPage.items.map((story) => story.driveFileId), [
      'story-3',
      'story-4',
    ]);
    expect(secondPage.hasMore, isFalse);
    expect(secondPage.nextPageToken, isNull);
  });

  test('Drive pagination preserves the remote folder cursor', () async {
    final client = _folderClient({
      'root': [
        _file('story-1', 'One.epub'),
        _file('story-2', 'Two.epub'),
        _file('story-3', 'Three.epub'),
      ],
    });

    final firstPage = await GoogleDriveService.fetchStoriesPageForTesting(
      client: client,
      rootFolderIds: const ['root'],
      pageSize: 2,
    );
    final secondPage = await GoogleDriveService.fetchStoriesPageForTesting(
      client: client,
      rootFolderIds: const ['root'],
      pageSize: 2,
      pageToken: firstPage.nextPageToken,
    );

    expect(firstPage.items.map((story) => story.driveFileId), [
      'story-1',
      'story-2',
    ]);
    expect(secondPage.items.map((story) => story.driveFileId), ['story-3']);
    expect(secondPage.hasMore, isFalse);
  });

  test('Drive pagination returns an empty page for an empty folder', () async {
    final client = _folderClient({'root-empty': []});

    final page = await GoogleDriveService.fetchStoriesPageForTesting(
      client: client,
      rootFolderIds: const ['root-empty'],
      pageSize: 10,
    );

    expect(page.items, isEmpty);
    expect(page.hasMore, isFalse);
    expect(page.nextPageToken, isNull);
  });

  test('Drive pagination reads and paginates a catalog-only folder', () async {
    final client = _folderClient(
      {
        'root-catalog': [_file('catalog-file', 'catalog.json')],
      },
      catalogs: {
        'catalog-file': {
          'stories': [
            {'id': 'catalog-1', 'driveFileId': 'file-1', 'title': 'One'},
            {'id': 'catalog-2', 'driveFileId': 'file-2', 'title': 'Two'},
          ],
        },
      },
    );

    final firstPage = await GoogleDriveService.fetchStoriesPageForTesting(
      client: client,
      rootFolderIds: const ['root-catalog'],
      pageSize: 1,
    );
    final secondPage = await GoogleDriveService.fetchStoriesPageForTesting(
      client: client,
      rootFolderIds: const ['root-catalog'],
      pageSize: 1,
      pageToken: firstPage.nextPageToken,
    );

    expect(firstPage.items.map((story) => story.driveFileId), ['file-1']);
    expect(firstPage.hasMore, isTrue);
    expect(secondPage.items.map((story) => story.driveFileId), ['file-2']);
    expect(secondPage.hasMore, isFalse);
  });

  test(
    'starting another traversal does not invalidate an existing token',
    () async {
      final client = _folderClient({
        'root-a': [_file('a-1', 'A1.epub'), _file('a-2', 'A2.epub')],
        'root-b': [_file('b-1', 'B1.epub'), _file('b-2', 'B2.epub')],
      });

      final firstA = await GoogleDriveService.fetchStoriesPageForTesting(
        client: client,
        rootFolderIds: const ['root-a'],
        pageSize: 1,
      );
      final firstB = await GoogleDriveService.fetchStoriesPageForTesting(
        client: client,
        rootFolderIds: const ['root-b'],
        pageSize: 1,
      );
      final secondA = await GoogleDriveService.fetchStoriesPageForTesting(
        client: client,
        rootFolderIds: const ['root-a'],
        pageSize: 1,
        pageToken: firstA.nextPageToken,
      );

      expect(firstA.items.single.driveFileId, 'a-1');
      expect(firstB.items.single.driveFileId, 'b-1');
      expect(secondA.items.single.driveFileId, 'a-2');
    },
  );

  test('Drive folder traversal uses bounded concurrency', () async {
    var peakActiveRequests = 0;
    final client = _folderClient(
      {
        'root-a': [_file('a-1', 'A.epub')],
        'root-b': [_file('b-1', 'B.epub')],
        'root-c': [_file('c-1', 'C.epub')],
        'root-d': [_file('d-1', 'D.epub')],
      },
      listDelay: const Duration(milliseconds: 20),
      onListRequestActive: (activeRequests) {
        if (activeRequests > peakActiveRequests) {
          peakActiveRequests = activeRequests;
        }
      },
    );

    final page = await GoogleDriveService.fetchStoriesPageForTesting(
      client: client,
      rootFolderIds: const ['root-a', 'root-b', 'root-c', 'root-d'],
      pageSize: 4,
    );

    expect(page.items.map((story) => story.driveFileId), [
      'a-1',
      'b-1',
      'c-1',
      'd-1',
    ]);
    expect(page.hasMore, isFalse);
    expect(peakActiveRequests, 3);
  });
}

MockClient _folderClient(
  Map<String, List<Map<String, dynamic>>> folders, {
  Map<String, Object?> catalogs = const {},
  Duration listDelay = Duration.zero,
  void Function(int activeRequests)? onListRequestActive,
}) {
  var activeListRequests = 0;
  return MockClient((request) async {
    expect(request.url.host, 'www.googleapis.com');
    expect(request.url.queryParameters['key'], 'test-api-key');

    if (request.url.queryParameters['alt'] == 'media') {
      final fileId = request.url.pathSegments.last;
      final catalog = catalogs[fileId];
      if (catalog == null) return http.Response('Not found', 404);
      return http.Response(
        jsonEncode(catalog),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }

    final query = request.url.queryParameters['q'] ?? '';
    final folderId = RegExp(
      r"^'([^']+)' in parents",
    ).firstMatch(query)?.group(1);
    if (folderId == null) {
      return http.Response('Invalid query', 400);
    }

    activeListRequests++;
    onListRequestActive?.call(activeListRequests);
    try {
      if (listDelay > Duration.zero) {
        await Future<void>.delayed(listDelay);
      }
      final allFiles = folders[folderId] ?? const <Map<String, dynamic>>[];
      final pageSize = int.parse(
        request.url.queryParameters['pageSize'] ?? '50',
      );
      final remoteToken = request.url.queryParameters['pageToken'];
      final offset = remoteToken == null
          ? 0
          : int.parse(remoteToken.replaceFirst('offset-', ''));
      final files = allFiles.skip(offset).take(pageSize).toList();
      final nextOffset = offset + files.length;

      return http.Response(
        jsonEncode({
          'files': files,
          if (nextOffset < allFiles.length)
            'nextPageToken': 'offset-$nextOffset',
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    } finally {
      activeListRequests--;
    }
  });
}

Map<String, dynamic> _folder(String id, String name) {
  return {
    'id': id,
    'name': name,
    'mimeType': 'application/vnd.google-apps.folder',
  };
}

Map<String, dynamic> _file(String id, String name) {
  return {'id': id, 'name': name, 'mimeType': 'application/octet-stream'};
}
