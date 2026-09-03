import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/drive_metadata.dart';
import '../models/search_index_story.dart';
import '../models/story.dart';
import 'app_identity_service.dart';
import 'search/drive_catalog_parser.dart';
import '../utils/app_performance_logger.dart';

class DrivePage<T> {
  final List<T> items;
  final String? nextPageToken;
  final bool hasMore;

  const DrivePage({
    required this.items,
    this.nextPageToken,
    required this.hasMore,
  });
}

class RequestConcurrencyLimiter {
  final int maxConcurrency;
  int _activeRequests = 0;
  final _queue = <Completer<void>>[];

  RequestConcurrencyLimiter({this.maxConcurrency = 3});

  int get activeRequests => _activeRequests;

  Future<T> run<T>(Future<T> Function() fn) async {
    await _acquire();
    AppPerformanceLogger.log(
      '[PERF][DRIVE] Active requests: $_activeRequests / $maxConcurrency',
    );
    try {
      return await fn();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() async {
    if (_activeRequests < maxConcurrency) {
      _activeRequests++;
      return;
    }

    final completer = Completer<void>();
    _queue.add(completer);
    await completer.future;
  }

  void _release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    } else {
      _activeRequests--;
    }
  }
}

final RequestConcurrencyLimiter _driveConcurrencyLimiter =
    RequestConcurrencyLimiter(maxConcurrency: 3);

class GoogleDriveService {
  static const String apiKey = String.fromEnvironment('GOOGLE_DRIVE_API_KEY');
  static const String defaultFolderUrl = String.fromEnvironment(
    'GOOGLE_DRIVE_FOLDER_URL',
  );
  static const String defaultFolderUrls = String.fromEnvironment(
    'GOOGLE_DRIVE_FOLDER_URLS',
  );
  static const List<String> demoFolderUrls = [
    'https://drive.google.com/drive/folders/1JqHqueAhOcybtFQixX1PTypmq0MB7Mrx?usp=sharing',
    'https://drive.google.com/drive/folders/135QOQhnFAvSHoqbnr8aZmXbuFnZ3DBJJ?usp=drive_link',
    'https://drive.google.com/drive/folders/1h8xikg-VhsrSW-J5UBb5xLstn03L86tU?usp=drive_link',
    'https://drive.google.com/drive/folders/1X0mttYF0vCqT2ky1MQxpwPufksQoenj9?usp=drive_link',
    'https://drive.google.com/drive/folders/1JdFVB8f_7j6KvWb4DJIZsmFWZmokuSFh',
    'https://drive.google.com/drive/folders/10qaC4oMuVDtc6i8reqOEgGYf9MkgeS1V',
  ];

  static const String _folderMimeType = 'application/vnd.google-apps.folder';
  static const Set<String> _supportedExtensions = {'epub', 'pdf', 'txt'};
  static const Set<String> _imageExtensions = {'jpg', 'jpeg', 'png', 'webp'};
  static const int _maxScanDepth = 4;
  static const int _maxInfoJsonBytes = 1024 * 1024;
  static final Map<String, _DriveTraversalState> _pageStates = {};
  static int _pageTokenCounter = 0;
  static String? _androidApiKey;
  static Future<String>? _androidApiKeyFuture;
  static Future<Map<String, String>>? _googleApiHeadersFuture;

  static String? extractFolderId(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    if (!trimmed.startsWith('http') && !trimmed.contains('/')) {
      return trimmed;
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;

    if (uri.pathSegments.contains('folders')) {
      final index = uri.pathSegments.indexOf('folders');
      if (index + 1 < uri.pathSegments.length) {
        return uri.pathSegments[index + 1];
      }
    }

    final id = uri.queryParameters['id'];
    if (id != null && id.trim().isNotEmpty) return id.trim();

    return null;
  }

  static Future<List<Story>> fetchStoriesFromConfiguredFolder({
    Iterable<String> extraFolderUrls = const [],
  }) async {
    final folderUrls = {
      ..._configuredFolderUrls(),
      ...extraFolderUrls,
    }.toList();
    if (folderUrls.isEmpty) {
      throw Exception(
        'Thiếu GOOGLE_DRIVE_FOLDER_URL hoặc GOOGLE_DRIVE_FOLDER_URLS. Hãy truyền link thư mục Drive bằng --dart-define.',
      );
    }
    return fetchStoriesFromFolders(folderUrls);
  }

  static Future<List<Story>> fetchStoriesFromFolders(
    Iterable<String> folderUrls,
  ) async {
    await _requireApiKey();

    final inputs = folderUrls
        .map((folderUrl) => folderUrl.trim())
        .where((folderUrl) => folderUrl.isNotEmpty)
        .toList();
    if (inputs.isEmpty) {
      throw Exception('Vui lòng nhập ít nhất một link hoặc ID thư mục Drive.');
    }

    final results = await Future.wait(
      inputs.map((folderUrl) async {
        try {
          return _FolderScanResult(
            stories: await fetchStoriesFromFolder(folderUrl),
          );
        } catch (e) {
          return _FolderScanResult(error: '$folderUrl: $e');
        }
      }),
    );

    final stories = _dedupeStories([
      for (final result in results) ...result.stories,
    ]);
    final errors = [
      for (final result in results)
        if (result.error != null) result.error!,
    ];
    if (stories.isEmpty && errors.isNotEmpty) {
      throw Exception(errors.join('\n'));
    }
    return stories;
  }

  static Future<List<Story>> fetchStoriesFromFolder(String folderUrl) async {
    final folderId = extractFolderId(folderUrl);
    if (folderId == null) {
      throw Exception('URL hoặc ID thư mục Google Drive không hợp lệ');
    }
    final requestApiKey = await _requireApiKey();

    final rootFiles = await _listChildren(
      folderId,
      requestApiKey: requestApiKey,
    );

    final catalogFile = _findCatalogFile(rootFiles);
    if (catalogFile != null) {
      try {
        final catalogStories = await _readCatalogStories(catalogFile.id);
        return catalogStories;
      } catch (_) {}
    }

    return _scanFolderStories(rootFiles, requestApiKey: requestApiKey);
  }

  static List<String> parseFolderInputs(String value) {
    return value
        .split(RegExp(r'[\n,;|]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList();
  }

  static List<String> _configuredFolderUrls() {
    return {
      ...demoFolderUrls,
      ...parseFolderInputs(defaultFolderUrls),
      ...parseFolderInputs(defaultFolderUrl),
    }.toList();
  }

  static List<Story> _dedupeStories(List<Story> stories) {
    final seen = <String>{};
    final result = <Story>[];

    for (final story in stories) {
      final key = story.driveFileId.isNotEmpty ? story.driveFileId : story.id;
      if (key.isEmpty || seen.add(key)) {
        result.add(story);
      }
    }

    return result;
  }

  static Future<List<Story>> _readCatalogStories(
    String fileId, {
    String? requestApiKey,
    http.Client? client,
    bool includeRestrictionHeaders = true,
  }) async {
    final Uint8List bytes;
    if (client == null) {
      bytes = await downloadFileBytes(fileId);
    } else {
      final catalogUrl = getApiDownloadUrl(
        fileId,
        requestApiKey: requestApiKey,
      );
      if (catalogUrl.isEmpty) {
        throw Exception('Thiếu GOOGLE_DRIVE_API_KEY để tải catalog.json.');
      }
      final uri = Uri.parse(catalogUrl);
      final headers = includeRestrictionHeaders
          ? await _headersForUri(uri)
          : const <String, String>{};
      final response = await client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw Exception(_driveApiError(response.statusCode, response.body));
      }
      bytes = response.bodyBytes;
    }
    final decoded = json.decode(utf8.decode(bytes));

    final List<dynamic> items;
    if (decoded is List) {
      items = decoded;
    } else if (decoded is Map<String, dynamic> && decoded['stories'] is List) {
      items = decoded['stories'] as List<dynamic>;
    } else {
      throw Exception('catalog.json phải là mảng hoặc có field stories');
    }

    return items
        .whereType<Map>()
        .map((item) => _storyFromCatalogMap(Map<String, dynamic>.from(item)))
        .whereType<Story>()
        .toList();
  }

  static Story? _storyFromCatalogMap(Map<String, dynamic> map) {
    final chapterOrder = _readStringList(map['chapterOrder']);
    final driveFileId =
        _readString(map['driveFileId']) ??
        _readString(map['fileId']) ??
        (chapterOrder.isNotEmpty ? chapterOrder.first : null);
    if (driveFileId == null || driveFileId.isEmpty) return null;

    final coverFileId =
        _readString(map['coverFileId']) ?? _readString(map['coverId']);
    final iconUrl =
        _readString(map['iconUrl']) ??
        _readString(map['coverUrl']) ??
        (coverFileId == null ? '' : getCoverImageUrl(coverFileId));

    final title = _readString(map['title']) ?? _cleanFileName(driveFileId);
    final storyId = _readString(map['id']) ?? driveFileId;
    final totalChapters =
        _readInt(map['totalChapters']) ??
        (chapterOrder.isNotEmpty ? chapterOrder.length : 1);
    final fileType =
        _readString(map['fileType']) ?? _readString(map['type']) ?? '';

    return Story(
      id: storyId,
      title: title,
      titleEng: _readString(map['titleEng']) ?? '',
      description: _readString(map['description']) ?? '',
      author: _readString(map['author']) ?? '',
      genres: _readStringList(map['genres']),
      totalChapters: totalChapters < 1 ? 1 : totalChapters,
      iconUrl: iconUrl,
      driveFileId: driveFileId,
      isFromDrive: true,
      isLocal: false,
      fileType: fileType.toLowerCase(),
    );
  }

  static Future<List<Story>> _scanFolderStories(
    List<_DriveFile> rootFiles, {
    required String requestApiKey,
    int depth = 0,
  }) async {
    final results = await Future.wait(
      rootFiles.map(
        (item) => _scanDriveItem(item, depth, requestApiKey: requestApiKey),
      ),
    );
    return _dedupeStories([for (final result in results) ...result]);
  }

  static Future<List<Story>> _scanDriveItem(
    _DriveFile item,
    int depth, {
    required String requestApiKey,
  }) async {
    if (!item.isFolder) {
      return item.isStoryFile ? [_storyFromDriveFile(item)] : const [];
    }

    final stories = <Story>[];
    final children = await _listChildren(item.id, requestApiKey: requestApiKey);
    final catalogFile = _findCatalogFile(children);
    if (catalogFile != null) {
      try {
        stories.addAll(await _readCatalogStories(catalogFile.id));
      } catch (_) {}
    }

    final ebookFiles = children.where((file) => file.isStoryFile).toList();
    final info = await _readOptionalInfoJson(children);
    final coverFile = _findCoverFile(children);

    if (ebookFiles.isNotEmpty) {
      final folderTitle = _readString(info['title']) ?? item.name;
      for (final file in ebookFiles) {
        final hasMultipleVolumes = ebookFiles.length > 1;
        final cleanFileName = _cleanFileName(file.name);
        final displayTitle = hasMultipleVolumes
            ? '$folderTitle - $cleanFileName'
            : folderTitle;

        stories.add(
          _storyFromDriveFile(
            file,
            title: displayTitle,
            fallbackThumbnail: coverFile == null
                ? item.thumbnailLink
                : getCoverImageUrl(coverFile.id),
            metadata: info,
          ),
        );
      }
    }

    if (depth + 1 < _maxScanDepth) {
      final subFolders = children.where((file) => file.isFolder).toList();
      if (subFolders.isNotEmpty) {
        stories.addAll(
          await _scanFolderStories(
            subFolders,
            requestApiKey: requestApiKey,
            depth: depth + 1,
          ),
        );
      }
    }

    return stories;
  }

  static Future<Map<String, dynamic>> _readOptionalInfoJson(
    List<_DriveFile> files,
  ) async {
    final infoFile = _findNamedFile(files, 'info.json');
    if (infoFile == null) return const {};

    try {
      final bytes = await downloadFileBytes(infoFile.id);
      final decoded = json.decode(utf8.decode(bytes));
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}

    return const {};
  }

  static Story _storyFromDriveFile(
    _DriveFile file, {
    String? title,
    String? fallbackThumbnail,
    Map<String, dynamic> metadata = const {},
  }) {
    final coverFileId =
        _readString(metadata['coverFileId']) ??
        _readString(metadata['coverId']);
    final iconUrl =
        _readString(metadata['iconUrl']) ??
        _readString(metadata['coverUrl']) ??
        (coverFileId == null ? null : getCoverImageUrl(coverFileId)) ??
        fallbackThumbnail ??
        file.thumbnailLink;
    final totalChapters = _readInt(metadata['totalChapters']) ?? 1;

    return Story(
      id: file.id,
      title:
          title ?? _readString(metadata['title']) ?? _cleanFileName(file.name),
      titleEng: _readString(metadata['titleEng']) ?? '',
      description: _readString(metadata['description']) ?? '',
      author: _readString(metadata['author']) ?? '',
      genres: _readStringList(metadata['genres']),
      totalChapters: totalChapters < 1 ? 1 : totalChapters,
      iconUrl: iconUrl,
      driveFileId: file.id,
      isFromDrive: true,
      isLocal: false,
      fileType: file.extension,
    );
  }

  static Future<DriveMetadataSnapshot> fetchMetadataIndexSnapshot(
    String folderUrl,
  ) async {
    final folderId = extractFolderId(folderUrl);
    if (folderId == null) {
      throw Exception('URL hoặc ID thư mục Google Drive không hợp lệ');
    }
    final requestApiKey = await _requireApiKey();
    return _fetchMetadataIndexSnapshot(
      rootFolderId: folderId,
      requestApiKey: requestApiKey,
    );
  }

  @visibleForTesting
  static Future<DriveMetadataSnapshot> fetchMetadataIndexSnapshotForTesting({
    required http.Client client,
    required String rootFolderId,
  }) {
    return _fetchMetadataIndexSnapshot(
      rootFolderId: rootFolderId,
      requestApiKey: 'test-api-key',
      client: client,
      includeRestrictionHeaders: false,
    );
  }

  static Future<DriveMetadataSnapshot> _fetchMetadataIndexSnapshot({
    required String rootFolderId,
    required String requestApiKey,
    http.Client? client,
    bool includeRestrictionHeaders = true,
  }) async {
    final pendingFolders = ListQueue<_DriveMetadataFolder>.of([
      _DriveMetadataFolder(id: rootFolderId, name: '', depth: 0),
    ]);
    final seenFolderIds = <String>{rootFolderId};
    final fileRecords = <String, DriveMetadataRecord>{};
    final storyFiles = <String, _DriveFile>{};
    final catalogRecords = <String, DriveMetadataRecord>{};
    var warningCount = 0;

    while (pendingFolders.isNotEmpty) {
      final folders = <_DriveMetadataFolder>[];
      while (folders.length < _driveConcurrencyLimiter.maxConcurrency &&
          pendingFolders.isNotEmpty) {
        folders.add(pendingFolders.removeFirst());
      }

      final childGroups = await Future.wait([
        for (final folder in folders)
          _listAllChildren(
            folder.id,
            requestApiKey: requestApiKey,
            client: client,
            includeRestrictionHeaders: includeRestrictionHeaders,
          ),
      ]);

      for (var index = 0; index < folders.length; index++) {
        final folder = folders[index];
        final children = childGroups[index];
        for (final child in children.where((file) => file.isFolder)) {
          if (folder.depth < _maxScanDepth &&
              child.id.isNotEmpty &&
              seenFolderIds.add(child.id)) {
            pendingFolders.add(
              _DriveMetadataFolder(
                id: child.id,
                name: child.name,
                depth: folder.depth + 1,
              ),
            );
          }
        }

        final files = children.where((file) => file.isStoryFile).toList();
        final coverFile = _findCoverFile(children);
        Map<String, dynamic> sidecar = const {};
        final infoFile = _findNamedFile(children, 'info.json');
        if (infoFile != null) {
          try {
            final bytes = await _readMetadataFileBytes(
              infoFile.id,
              requestApiKey: requestApiKey,
              maxBytes: _maxInfoJsonBytes,
              client: client,
              includeRestrictionHeaders: includeRestrictionHeaders,
            );
            final decoded = jsonDecode(utf8.decode(bytes));
            if (decoded is! Map) {
              throw const FormatException('info.json must contain an object.');
            }
            sidecar = Map<String, dynamic>.from(decoded);
          } catch (_) {
            warningCount++;
          }
        }

        for (final file in files) {
          storyFiles[file.id] = file;
          fileRecords[file.id] = _metadataRecordFromDriveFile(
            file,
            folderName: folder.name,
            siblingCount: files.length,
            sidecar: sidecar,
            coverFile: coverFile,
          );
        }

        final catalogFile = _findCatalogFile(children);
        if (catalogFile != null) {
          try {
            final bytes = await _readMetadataFileBytes(
              catalogFile.id,
              requestApiKey: requestApiKey,
              maxBytes: DriveCatalogParser.maxCatalogBytes,
              client: client,
              includeRestrictionHeaders: includeRestrictionHeaders,
            );
            final parsed = DriveCatalogParser.parseBytes(
              bytes,
              expectedSourceId: folder.id,
            );
            warningCount += parsed.skippedEntries;
            for (final record in parsed.records) {
              if (catalogRecords.containsKey(record.driveFileId)) {
                warningCount++;
                continue;
              }
              catalogRecords[record.driveFileId] = record;
            }
          } catch (_) {
            warningCount++;
          }
        }
      }
    }

    for (final entry in catalogRecords.entries) {
      final driveFile = storyFiles[entry.key];
      final fallback = fileRecords[entry.key];
      if (driveFile == null || fallback == null) {
        warningCount++;
        continue;
      }
      fileRecords[entry.key] = _mergeCatalogRecord(
        entry.value,
        driveFile: driveFile,
        fallback: fallback,
      );
    }

    final records = fileRecords.values.toList()
      ..sort((left, right) {
        final titleOrder = left.title.toLowerCase().compareTo(
          right.title.toLowerCase(),
        );
        return titleOrder != 0
            ? titleOrder
            : left.driveFileId.compareTo(right.driveFileId);
      });
    return DriveMetadataSnapshot(
      sourceId: rootFolderId,
      records: records,
      traversalComplete: true,
      warningCount: warningCount,
    );
  }

  static DriveMetadataRecord _metadataRecordFromDriveFile(
    _DriveFile file, {
    required String folderName,
    required int siblingCount,
    required Map<String, dynamic> sidecar,
    required _DriveFile? coverFile,
  }) {
    final sidecarTitle = _readString(sidecar['title']);
    final baseTitle =
        sidecarTitle ??
        (folderName.trim().isEmpty ? _cleanFileName(file.name) : folderName);
    final title =
        siblingCount > 1 && (sidecarTitle != null || folderName.isNotEmpty)
        ? '$baseTitle - ${_cleanFileName(file.name)}'
        : baseTitle;
    final coverFileId =
        _readString(sidecar['coverFileId']) ??
        _readString(sidecar['coverId']) ??
        coverFile?.id;
    final coverUrl =
        _readString(sidecar['iconUrl']) ??
        _readString(sidecar['coverUrl']) ??
        (coverFileId == null ? null : getCoverImageUrl(coverFileId)) ??
        _readString(file.thumbnailLink);

    return DriveMetadataRecord(
      driveFileId: file.id,
      fileName: file.name,
      title: title,
      mimeType: _effectiveMimeType(file),
      modifiedTime: file.modifiedTime,
      fileSize: file.fileSize,
      checksum: file.md5Checksum,
      description: _readString(sidecar['description']) ?? '',
      coverFileId: coverFileId,
      coverUrl: coverUrl,
      metadataStatus: sidecar.isEmpty
          ? SearchMetadataStatus.missing
          : _readMetadataStatus(sidecar['metadataStatus']) ??
                SearchMetadataStatus.partial,
      origin: sidecar.isEmpty
          ? DriveMetadataOrigin.driveFile
          : DriveMetadataOrigin.sidecar,
      authors: _readAuthors(sidecar),
      genres: _readStringList(sidecar['genres']),
    );
  }

  static DriveMetadataRecord _mergeCatalogRecord(
    DriveMetadataRecord catalog, {
    required _DriveFile? driveFile,
    required DriveMetadataRecord? fallback,
  }) {
    return DriveMetadataRecord(
      driveFileId: catalog.driveFileId,
      fileName: catalog.fileName.isNotEmpty
          ? catalog.fileName
          : driveFile?.name ?? fallback?.fileName ?? '',
      title: catalog.title,
      mimeType: driveFile == null
          ? catalog.mimeType
          : _effectiveMimeType(driveFile),
      modifiedTime: driveFile?.modifiedTime ?? catalog.modifiedTime,
      fileSize: driveFile?.fileSize ?? catalog.fileSize,
      checksum: driveFile?.md5Checksum ?? catalog.checksum,
      description: catalog.description,
      coverFileId: catalog.coverFileId ?? fallback?.coverFileId,
      coverUrl:
          catalog.coverUrl ??
          fallback?.coverUrl ??
          _readString(driveFile?.thumbnailLink),
      metadataStatus: catalog.metadataStatus,
      origin: DriveMetadataOrigin.catalog,
      authors: catalog.authors,
      genres: catalog.genres,
    );
  }

  static Future<Uint8List> _readMetadataFileBytes(
    String fileId, {
    required String requestApiKey,
    required int maxBytes,
    http.Client? client,
    required bool includeRestrictionHeaders,
  }) async {
    if (client == null) {
      return downloadFileBytes(fileId, maxBytes: maxBytes);
    }

    return _driveConcurrencyLimiter.run(() async {
      final uri = Uri.parse(
        getApiDownloadUrl(fileId, requestApiKey: requestApiKey),
      );
      final headers = includeRestrictionHeaders
          ? await _headersForUri(uri)
          : const <String, String>{};
      final response = await client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw Exception(_driveApiError(response.statusCode, response.body));
      }
      if ((response.contentLength ?? response.bodyBytes.length) > maxBytes) {
        throw const FormatException('Drive metadata file is too large.');
      }
      return response.bodyBytes;
    });
  }

  static String _effectiveMimeType(_DriveFile file) {
    final mimeType = file.mimeType.trim();
    if (mimeType.isNotEmpty && mimeType != 'application/octet-stream') {
      return mimeType;
    }
    return switch (file.extension) {
      'epub' => 'application/epub+zip',
      'pdf' => 'application/pdf',
      'txt' => 'text/plain',
      _ => mimeType,
    };
  }

  static SearchMetadataStatus? _readMetadataStatus(Object? value) {
    final statusValue = _readString(value)?.toLowerCase();
    if (statusValue == null) return null;
    for (final status in SearchMetadataStatus.values) {
      if (status.storageValue == statusValue) return status;
    }
    return null;
  }

  static List<String> _readAuthors(Map<String, dynamic> metadata) {
    final authors = _readStringList(metadata['authors']);
    if (authors.isNotEmpty) return authors;
    final author = _readString(metadata['author']);
    return author == null ? const [] : [author];
  }

  static Future<DrivePage<Story>> fetchStoriesPage({
    int pageSize = 20,
    String? pageToken,
    Iterable<String> extraFolderUrls = const [],
  }) async {
    final requestApiKey = await _requireApiKey();
    return _fetchStoriesPage(
      pageSize: pageSize,
      pageToken: pageToken,
      folderUrls: {..._configuredFolderUrls(), ...extraFolderUrls},
      requestApiKey: requestApiKey,
    );
  }

  @visibleForTesting
  static Future<DrivePage<Story>> fetchStoriesPageForTesting({
    required http.Client client,
    required Iterable<String> rootFolderIds,
    int pageSize = 20,
    String? pageToken,
  }) {
    return _fetchStoriesPage(
      pageSize: pageSize,
      pageToken: pageToken,
      folderUrls: rootFolderIds,
      requestApiKey: 'test-api-key',
      client: client,
      includeRestrictionHeaders: false,
    );
  }

  static Future<DrivePage<Story>> _fetchStoriesPage({
    required int pageSize,
    required String? pageToken,
    required Iterable<String> folderUrls,
    required String requestApiKey,
    http.Client? client,
    bool includeRestrictionHeaders = true,
  }) async {
    if (requestApiKey.trim().isEmpty) {
      throw Exception(
        'Thiếu GOOGLE_DRIVE_API_KEY. Hãy truyền API key bằng --dart-define.',
      );
    }

    final effectivePageSize = pageSize.clamp(1, 1000);
    AppPerformanceLogger.log(
      '[PERF][DRIVE] fetch page start '
      '(pageSize: $effectivePageSize, continuation: ${pageToken != null})',
    );
    final stopwatch = Stopwatch()..start();

    final _DriveTraversalState state;
    if (pageToken == null) {
      final rootFolderIds = folderUrls
          .map(extractFolderId)
          .whereType<String>()
          .where((folderId) => folderId.isNotEmpty)
          .toSet();
      if (rootFolderIds.isEmpty) {
        return const DrivePage(items: [], hasMore: false);
      }
      state = _DriveTraversalState.fromRoots(rootFolderIds);
    } else {
      final savedState = _pageStates[pageToken];
      if (savedState == null) {
        throw Exception(
          'Phiên tải danh sách Drive đã hết hạn. Hãy làm mới danh sách.',
        );
      }
      state = savedState.copy();
    }

    final stories = <Story>[];
    while (stories.length < effectivePageSize &&
        (state.pendingStories.isNotEmpty || state.pendingFolders.isNotEmpty)) {
      while (stories.length < effectivePageSize &&
          state.pendingStories.isNotEmpty) {
        stories.add(state.pendingStories.removeFirst());
      }
      if (stories.length >= effectivePageSize || state.pendingFolders.isEmpty) {
        break;
      }

      final remaining = effectivePageSize - stories.length;
      final cursors = <_DriveFolderCursor>[];
      while (cursors.length < _driveConcurrencyLimiter.maxConcurrency &&
          state.pendingFolders.isNotEmpty) {
        cursors.add(state.pendingFolders.removeFirst());
      }
      final filePages = await Future.wait([
        for (final cursor in cursors)
          _listChildrenPage(
            cursor.folderId,
            pageSize: remaining,
            pageToken: cursor.apiPageToken,
            requestApiKey: requestApiKey,
            client: client,
            includeRestrictionHeaders: includeRestrictionHeaders,
          ),
      ]);
      final continuations = <_DriveFolderCursor>[];

      for (var index = 0; index < cursors.length; index++) {
        final cursor = cursors[index];
        final filePage = filePages[index];
        for (final file in filePage.files) {
          if (file.isFolder) {
            if (cursor.depth < _maxScanDepth &&
                file.id.isNotEmpty &&
                state.seenFolderIds.add(file.id)) {
              state.pendingFolders.add(
                _DriveFolderCursor(folderId: file.id, depth: cursor.depth + 1),
              );
            }
            continue;
          }
          if (file.isCatalogFile) {
            try {
              final catalogStories = await _readCatalogStories(
                file.id,
                requestApiKey: requestApiKey,
                client: client,
                includeRestrictionHeaders: includeRestrictionHeaders,
              );
              for (final story in catalogStories) {
                _queueStory(state, story);
              }
            } catch (error) {
              AppPerformanceLogger.log(
                '[PERF][DRIVE] catalog skipped '
                '(errorType: ${error.runtimeType})',
              );
            }
            continue;
          }
          if (file.isStoryFile) {
            _queueStory(state, _storyFromDriveFile(file));
          }
        }

        if (filePage.hasNextPage) {
          continuations.add(cursor.withApiPageToken(filePage.nextPageToken));
        }
      }

      for (final continuation in continuations.reversed) {
        state.pendingFolders.addFirst(continuation);
      }
    }

    if (pageToken != null) {
      _pageStates.remove(pageToken);
    }
    final hasMore =
        state.pendingStories.isNotEmpty || state.pendingFolders.isNotEmpty;
    final nextPageToken = hasMore ? _storePageState(state) : null;
    stopwatch.stop();
    AppPerformanceLogger.log(
      '[PERF][DRIVE] fetch page complete '
      '(${stories.length} items in ${stopwatch.elapsedMilliseconds}ms, '
      'hasMore: $hasMore)',
    );

    return DrivePage(
      items: stories,
      nextPageToken: nextPageToken,
      hasMore: hasMore,
    );
  }

  static String _storePageState(_DriveTraversalState state) {
    while (_pageStates.length >= 8) {
      _pageStates.remove(_pageStates.keys.first);
    }
    final token = 'drive-page-${++_pageTokenCounter}';
    _pageStates[token] = state;
    return token;
  }

  static void _queueStory(_DriveTraversalState state, Story story) {
    final storyId = story.driveFileId.isNotEmpty ? story.driveFileId : story.id;
    if (storyId.isNotEmpty && state.seenStoryIds.add(storyId)) {
      state.pendingStories.add(story);
    }
  }

  static Future<_DriveFilePage> _listChildrenPage(
    String folderId, {
    int pageSize = 50,
    String? pageToken,
    required String requestApiKey,
    http.Client? client,
    bool includeRestrictionHeaders = true,
  }) async {
    return _driveConcurrencyLimiter.run(() async {
      final query = "'$folderId' in parents and trashed = false";
      final params = <String, String>{
        'q': query,
        'key': requestApiKey,
        'pageSize': pageSize.toString(),
        'orderBy': 'folder,name',
        'fields':
            'nextPageToken,files(id,name,mimeType,thumbnailLink,modifiedTime,size,md5Checksum)',
      };
      if (pageToken != null && pageToken.isNotEmpty) {
        params['pageToken'] = pageToken;
      }

      final uri = Uri.https('www.googleapis.com', '/drive/v3/files', params);
      final headers = includeRestrictionHeaders
          ? await _headersForUri(uri)
          : const <String, String>{};
      final response =
          await (client == null
                  ? http.get(uri, headers: headers)
                  : client.get(uri, headers: headers))
              .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception(_driveApiError(response.statusCode, response.body));
      }

      final data = json.decode(utf8.decode(response.bodyBytes));
      final items = data['files'] as List<dynamic>? ?? [];
      final files = items
          .whereType<Map>()
          .map((item) => _DriveFile.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      final nextToken = data['nextPageToken']?.toString();

      return _DriveFilePage(
        files: files,
        nextPageToken: nextToken,
        hasNextPage: nextToken != null && nextToken.isNotEmpty,
      );
    });
  }

  static Future<List<_DriveFile>> _listAllChildren(
    String folderId, {
    required String requestApiKey,
    http.Client? client,
    bool includeRestrictionHeaders = true,
  }) async {
    final files = <_DriveFile>[];
    String? pageToken;
    do {
      final page = await _listChildrenPage(
        folderId,
        pageSize: 1000,
        pageToken: pageToken,
        requestApiKey: requestApiKey,
        client: client,
        includeRestrictionHeaders: includeRestrictionHeaders,
      );
      files.addAll(page.files);
      pageToken = page.nextPageToken;
    } while (pageToken != null && pageToken.isNotEmpty);
    return files;
  }

  static Future<List<_DriveFile>> _listChildren(
    String folderId, {
    required String requestApiKey,
  }) {
    return _listAllChildren(folderId, requestApiKey: requestApiKey);
  }

  static _DriveFile? _findNamedFile(List<_DriveFile> files, String name) {
    final lowerName = name.toLowerCase();
    for (final file in files) {
      if (!file.isFolder && file.name.toLowerCase() == lowerName) return file;
    }
    return null;
  }

  static _DriveFile? _findCatalogFile(List<_DriveFile> files) {
    return _findNamedFile(files, 'catalog.vbook.json') ??
        _findNamedFile(files, 'catalog.json');
  }

  static _DriveFile? _findCoverFile(List<_DriveFile> files) {
    final imageFiles = files.where((file) => file.isImageFile).toList();
    if (imageFiles.isEmpty) return null;

    for (final file in imageFiles) {
      final lower = file.name.toLowerCase();
      if (lower.startsWith('cover.') ||
          lower.startsWith('folder.') ||
          lower.startsWith('poster.') ||
          lower.startsWith('thumbnail.') ||
          lower.startsWith('thumb.') ||
          lower.startsWith('front.')) {
        return file;
      }
    }

    for (final file in imageFiles) {
      final lower = file.name.toLowerCase();
      if (lower.contains('cover') ||
          lower.contains('poster') ||
          lower.contains('thumbnail') ||
          lower.contains('thumb')) {
        return file;
      }
    }

    if (imageFiles.length == 1) return imageFiles.first;
    return null;
  }

  static bool _isSupportedStoryName(String name) {
    final ext = name.split('.').last.toLowerCase();
    return _supportedExtensions.contains(ext);
  }

  static String _cleanFileName(String name) {
    return name.replaceAll(
      RegExp(r'\.(epub|pdf|txt)$', caseSensitive: false),
      '',
    );
  }

  static String? _readString(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return null;
    return text;
  }

  static int? _readInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static List<String> _readStringList(dynamic value) {
    if (value is List) {
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList();
    }
    if (value is String && value.trim().isNotEmpty) {
      return value
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList();
    }
    return const [];
  }

  static String get _availableApiKey {
    final dartDefineApiKey = apiKey.trim();
    if (dartDefineApiKey.isNotEmpty) return dartDefineApiKey;
    return _androidApiKey?.trim() ?? '';
  }

  static Future<String> _requireApiKey() async {
    final availableApiKey = _availableApiKey;
    if (availableApiKey.isNotEmpty) return availableApiKey;

    _androidApiKeyFuture ??= AppIdentityService.googleDriveApiKey();
    final configuredApiKey = (await _androidApiKeyFuture!).trim();
    if (configuredApiKey.isNotEmpty) {
      _androidApiKey = configuredApiKey;
      return configuredApiKey;
    }

    _androidApiKeyFuture = null;
    throw Exception(
      'Thiếu GOOGLE_DRIVE_API_KEY. Hãy cấu hình key trong .env trên Android '
      'hoặc truyền bằng --dart-define.',
    );
  }

  static String getThumbnailUrl(String fileId) {
    return 'https://drive.google.com/thumbnail?id=$fileId&sz=w512';
  }

  static String getCoverImageUrl(String fileId) {
    return getDownloadUrl(fileId);
  }

  static List<String> coverImageCandidates(String imagePath) {
    final trimmed = imagePath.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('http')) {
      return trimmed.isEmpty ? const [] : [trimmed];
    }

    if (!trimmed.contains('drive.google.com') &&
        !trimmed.contains('googleapis.com')) {
      return [trimmed];
    }

    final fileId = extractFileId(trimmed);
    if (fileId == null || fileId.isEmpty) return [trimmed];

    final isThumbnail = trimmed.contains('drive.google.com/thumbnail');
    final isMedia =
        trimmed.contains('www.googleapis.com/drive/v3/files') &&
        trimmed.contains('alt=media');
    final directUrl = getCoverImageUrl(fileId);
    final userContentUrl = getUserContentDownloadUrl(fileId);
    final apiMediaUrl = getApiDownloadUrl(fileId);
    final thumbnailUrl = getThumbnailUrl(fileId);

    if (isMedia) {
      return _uniqueNonEmpty([
        directUrl,
        userContentUrl,
        thumbnailUrl,
        trimmed,
      ]);
    }
    if (isThumbnail) {
      return _uniqueNonEmpty([trimmed, directUrl, userContentUrl, apiMediaUrl]);
    }
    return _uniqueNonEmpty([
      directUrl,
      userContentUrl,
      thumbnailUrl,
      apiMediaUrl,
      trimmed,
    ]);
  }

  static String? extractFileId(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    if (!trimmed.startsWith('http') && !trimmed.contains('/')) return trimmed;

    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;

    final id = uri.queryParameters['id'];
    if (id != null && id.trim().isNotEmpty) return id.trim();

    if (uri.pathSegments.contains('d')) {
      final index = uri.pathSegments.indexOf('d');
      if (index + 1 < uri.pathSegments.length) {
        return uri.pathSegments[index + 1];
      }
    }

    if (uri.pathSegments.contains('files')) {
      final index = uri.pathSegments.indexOf('files');
      if (index + 1 < uri.pathSegments.length) {
        return uri.pathSegments[index + 1];
      }
    }

    return null;
  }

  static String getDownloadUrl(String fileId) {
    return 'https://drive.google.com/uc?export=download&id=$fileId';
  }

  static String getUserContentDownloadUrl(String fileId) {
    return 'https://drive.usercontent.google.com/download?id=$fileId&export=download&authuser=0';
  }

  static String getApiDownloadUrl(String fileId, {String? requestApiKey}) {
    final effectiveApiKey = (requestApiKey ?? _availableApiKey).trim();
    if (effectiveApiKey.isEmpty) return '';
    return Uri.https('www.googleapis.com', '/drive/v3/files/$fileId', {
      'alt': 'media',
      'key': effectiveApiKey,
    }).toString();
  }

  static List<String> _uniqueNonEmpty(List<String> values) {
    final seen = <String>{};
    return values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty && seen.add(value))
        .toList();
  }

  static Future<Uint8List> downloadFileBytes(
    String fileId, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    int? maxBytes,
  }) async {
    final requestApiKey = await _requireApiKey();

    final urls = _uniqueNonEmpty([
      getApiDownloadUrl(fileId, requestApiKey: requestApiKey),
      getDownloadUrl(fileId),
      getUserContentDownloadUrl(fileId),
    ]);
    Object? lastError;

    for (final url in urls) {
      try {
        return await _downloadBytesFromUrl(
          url,
          onProgress: onProgress,
          maxBytes: maxBytes,
        );
      } catch (e) {
        lastError = e;
      }
    }

    throw Exception('Lỗi khi tải file từ Drive: $lastError');
  }

  static Future<File> downloadFileToFile(
    String fileId,
    File outputFile, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    final requestApiKey = await _requireApiKey();

    await outputFile.parent.create(recursive: true);
    final tempFile = File('${outputFile.path}.download');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    final urls = _uniqueNonEmpty([
      getApiDownloadUrl(fileId, requestApiKey: requestApiKey),
      getDownloadUrl(fileId),
      getUserContentDownloadUrl(fileId),
    ]);
    Object? lastError;

    for (final url in urls) {
      try {
        await _downloadUrlToFile(url, tempFile, onProgress: onProgress);
        if (await outputFile.exists()) {
          await outputFile.delete();
        }
        return tempFile.rename(outputFile.path);
      } catch (e) {
        lastError = e;
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      }
    }

    throw Exception('Lỗi khi tải file từ Drive: $lastError');
  }

  static Future<Uint8List> _downloadBytesFromUrl(
    String url, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    int? maxBytes,
    String? cookie,
  }) async {
    final uri = Uri.parse(url);
    final request = http.Request('GET', uri);
    request.headers.addAll(await _headersForUri(uri));
    if (cookie != null && cookie.isNotEmpty) {
      request.headers['Cookie'] = cookie;
    }
    final response = await request.send().timeout(const Duration(seconds: 25));

    if (response.statusCode == 200) {
      if (_isHtmlResponse(response.headers)) {
        final htmlBytes = await response.stream.toBytes();
        final confirmUrl = _readDriveConfirmUrl(url, htmlBytes);
        if (confirmUrl != null) {
          return _downloadBytesFromUrl(
            confirmUrl,
            onProgress: onProgress,
            maxBytes: maxBytes,
            cookie: _cookieFromHeaders(response.headers),
          );
        }
        throw Exception('Drive trả về trang HTML thay vì nội dung file.');
      }

      final chunks = <int>[];
      var receivedBytes = 0;
      final totalBytes = response.contentLength;
      if (maxBytes != null && totalBytes != null && totalBytes > maxBytes) {
        throw Exception('File quá lớn để tải nền cho tác vụ này.');
      }

      await for (final chunk in response.stream) {
        chunks.addAll(chunk);
        receivedBytes += chunk.length;
        if (maxBytes != null && receivedBytes > maxBytes) {
          throw Exception('File quá lớn để tải nền cho tác vụ này.');
        }
        onProgress?.call(receivedBytes, totalBytes);
      }

      final bytes = Uint8List.fromList(chunks);
      if (_looksLikeHtml(bytes)) {
        throw Exception('Drive trả về trang HTML thay vì nội dung file.');
      }
      return bytes;
    }

    final errorBody = await response.stream.bytesToString();
    throw Exception('Lỗi khi tải file từ Drive: $errorBody');
  }

  static Future<void> _downloadUrlToFile(
    String url,
    File outputFile, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    String? cookie,
  }) async {
    final uri = Uri.parse(url);
    final request = http.Request('GET', uri);
    request.headers.addAll(await _headersForUri(uri));
    if (cookie != null && cookie.isNotEmpty) {
      request.headers['Cookie'] = cookie;
    }
    final response = await request.send().timeout(const Duration(seconds: 25));

    if (response.statusCode == 200) {
      if (_isHtmlResponse(response.headers)) {
        final htmlBytes = await response.stream.toBytes();
        final confirmUrl = _readDriveConfirmUrl(url, htmlBytes);
        if (confirmUrl != null) {
          return _downloadUrlToFile(
            confirmUrl,
            outputFile,
            onProgress: onProgress,
            cookie: _cookieFromHeaders(response.headers),
          );
        }
        throw Exception('Drive trả về trang HTML thay vì nội dung file.');
      }

      final sink = outputFile.openWrite();
      var receivedBytes = 0;
      final totalBytes = response.contentLength;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          receivedBytes += chunk.length;
          onProgress?.call(receivedBytes, totalBytes);
        }
      } finally {
        await sink.close();
      }
      return;
    }

    final errorBody = await response.stream.bytesToString();
    throw Exception('Lỗi khi tải file từ Drive: $errorBody');
  }

  static bool _isHtmlResponse(Map<String, String> headers) {
    return (headers['content-type'] ?? '').toLowerCase().contains('text/html');
  }

  static Future<Map<String, String>> _headersForUri(Uri uri) async {
    if (uri.host != 'www.googleapis.com') return const {};
    _googleApiHeadersFuture ??=
        AppIdentityService.googleApiKeyRestrictionHeaders();
    return _googleApiHeadersFuture!;
  }

  static String _driveApiError(int statusCode, String responseBody) {
    final lower = responseBody.toLowerCase();
    if (statusCode == 403 &&
        (lower.contains('api key') ||
            lower.contains('android') ||
            lower.contains('referer') ||
            lower.contains('credential'))) {
      return 'Không tải được thư mục Drive. API key có thể chưa được phép dùng cho app Android này. '
          'Hãy kiểm tra package name, SHA-1 signing certificate và API restriction trong Google Cloud.';
    }
    return 'Không tải được thư mục Drive: $responseBody';
  }

  static String? _cookieFromHeaders(Map<String, String> headers) {
    final raw = headers['set-cookie'];
    if (raw == null || raw.isEmpty) return null;
    return raw
        .split(',')
        .map((part) => part.split(';').first.trim())
        .where((part) => part.contains('='))
        .join('; ');
  }

  static String? _readDriveConfirmUrl(String baseUrl, Uint8List htmlBytes) {
    final html = utf8
        .decode(htmlBytes, allowMalformed: true)
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");

    final linkPatterns = [
      RegExp(
        r'''href=["']([^"']*(?:uc\?export=download|drive\.usercontent\.google\.com/download)[^"']*confirm=[^"']*)["']''',
        caseSensitive: false,
      ),
      RegExp(
        r'"downloadUrl"\s*:\s*"([^"]+confirm=[^"]+)"',
        caseSensitive: false,
      ),
    ];

    for (final pattern in linkPatterns) {
      final match = pattern.firstMatch(html);
      final rawUrl = match?.group(1);
      if (rawUrl != null && rawUrl.isNotEmpty) {
        return _resolveDriveUrl(baseUrl, rawUrl.replaceAll(r'\/', '/'));
      }
    }

    final actionMatch = RegExp(
      r'''<form[^>]+action=["']([^"']+)["']''',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    if (actionMatch == null) return null;

    final params = <String, String>{};
    final inputPattern = RegExp(
      r'''<input[^>]+name=["']([^"']+)["'][^>]+value=["']([^"']*)["']''',
      caseSensitive: false,
      dotAll: true,
    );
    for (final match in inputPattern.allMatches(html)) {
      final name = match.group(1);
      final value = match.group(2);
      if (name != null && value != null) params[name] = value;
    }

    if (!params.containsKey('confirm')) return null;
    final actionUrl = _resolveDriveUrl(baseUrl, actionMatch.group(1)!);
    final uri = Uri.parse(actionUrl);
    return uri
        .replace(queryParameters: {...uri.queryParameters, ...params})
        .toString();
  }

  static String _resolveDriveUrl(String baseUrl, String rawUrl) {
    if (rawUrl.startsWith('//')) return 'https:$rawUrl';
    return Uri.parse(baseUrl).resolve(rawUrl).toString();
  }

  static bool _looksLikeHtml(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    final sampleLength = bytes.length < 512 ? bytes.length : 512;
    final sample = utf8
        .decode(bytes.sublist(0, sampleLength), allowMalformed: true)
        .trimLeft()
        .toLowerCase();
    return sample.startsWith('<!doctype html') || sample.startsWith('<html');
  }
}

class _FolderScanResult {
  final List<Story> stories;
  final String? error;

  const _FolderScanResult({this.stories = const [], this.error});
}

class _DriveMetadataFolder {
  final String id;
  final String name;
  final int depth;

  const _DriveMetadataFolder({
    required this.id,
    required this.name,
    required this.depth,
  });
}

class _DriveFolderCursor {
  final String folderId;
  final int depth;
  final String? apiPageToken;

  const _DriveFolderCursor({
    required this.folderId,
    required this.depth,
    this.apiPageToken,
  });

  _DriveFolderCursor withApiPageToken(String? value) {
    return _DriveFolderCursor(
      folderId: folderId,
      depth: depth,
      apiPageToken: value,
    );
  }
}

class _DriveTraversalState {
  final ListQueue<_DriveFolderCursor> pendingFolders;
  final ListQueue<Story> pendingStories;
  final Set<String> seenFolderIds;
  final Set<String> seenStoryIds;

  _DriveTraversalState({
    required this.pendingFolders,
    required this.pendingStories,
    required this.seenFolderIds,
    required this.seenStoryIds,
  });

  factory _DriveTraversalState.fromRoots(Iterable<String> rootFolderIds) {
    final roots = rootFolderIds.toSet();
    return _DriveTraversalState(
      pendingFolders: ListQueue.of(
        roots.map(
          (folderId) => _DriveFolderCursor(folderId: folderId, depth: 0),
        ),
      ),
      pendingStories: ListQueue<Story>(),
      seenFolderIds: roots,
      seenStoryIds: <String>{},
    );
  }

  _DriveTraversalState copy() {
    return _DriveTraversalState(
      pendingFolders: ListQueue.of(pendingFolders),
      pendingStories: ListQueue.of(pendingStories),
      seenFolderIds: Set.of(seenFolderIds),
      seenStoryIds: Set.of(seenStoryIds),
    );
  }
}

class _DriveFilePage {
  final List<_DriveFile> files;
  final String? nextPageToken;
  final bool hasNextPage;

  _DriveFilePage({
    required this.files,
    this.nextPageToken,
    required this.hasNextPage,
  });
}

class _DriveFile {
  final String id;
  final String name;
  final String mimeType;
  final String thumbnailLink;
  final DateTime? modifiedTime;
  final int? fileSize;
  final String? md5Checksum;

  const _DriveFile({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.thumbnailLink,
    this.modifiedTime,
    this.fileSize,
    this.md5Checksum,
  });

  bool get isFolder => mimeType == GoogleDriveService._folderMimeType;
  bool get isCatalogFile {
    final lowerName = name.toLowerCase();
    return !isFolder &&
        (lowerName == 'catalog.vbook.json' || lowerName == 'catalog.json');
  }

  bool get isStoryFile => GoogleDriveService._isSupportedStoryName(name);
  String get extension => name.split('.').last.toLowerCase();
  bool get isImageFile =>
      GoogleDriveService._imageExtensions.contains(extension);

  factory _DriveFile.fromJson(Map<String, dynamic> json) {
    return _DriveFile(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      mimeType: json['mimeType']?.toString() ?? '',
      thumbnailLink: json['thumbnailLink']?.toString() ?? '',
      modifiedTime: DateTime.tryParse(
        json['modifiedTime']?.toString() ?? '',
      )?.toUtc(),
      fileSize: GoogleDriveService._readInt(json['size']),
      md5Checksum: GoogleDriveService._readString(json['md5Checksum']),
    );
  }
}
