import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum PluginInstallFailure {
  invalidPluginId,
  invalidDownloadUrl,
  downloadFailed,
  archiveTooLarge,
  invalidArchive,
  tooManyEntries,
  unsafeEntryPath,
  symbolicLink,
  entryTooLarge,
  expandedArchiveTooLarge,
  suspiciousCompressionRatio,
  missingManifest,
  invalidManifest,
  unsafeDestination,
  cleanupFailed,
}

class PluginInstallException implements Exception {
  final PluginInstallFailure failure;
  final String message;

  const PluginInstallException(this.failure, this.message);

  @override
  String toString() => message;
}

@immutable
class PluginArchiveLimits {
  final int maxZipBytes;
  final int maxEntries;
  final int maxEntryBytes;
  final int maxTotalUncompressedBytes;
  final double maxCompressionRatio;
  final int maxEntryPathLength;

  const PluginArchiveLimits({
    this.maxZipBytes = 20 * 1024 * 1024,
    this.maxEntries = 512,
    this.maxEntryBytes = 16 * 1024 * 1024,
    this.maxTotalUncompressedBytes = 64 * 1024 * 1024,
    this.maxCompressionRatio = 100,
    this.maxEntryPathLength = 512,
  });
}

class PreparedPluginInstall {
  final String pluginId;
  final String stagingDirectoryPath;
  final String targetDirectoryPath;
  final Map<String, dynamic> pluginJson;
  final Directory _pluginsRoot;
  final bool targetExistedAtPreparation;
  final String _transactionFilePath;

  String? _backupDirectoryPath;
  String? _expectedPluginStateHash;
  String _phase = PluginLoader._transactionPhasePrepared;
  bool _committed = false;
  bool _completed = false;

  PreparedPluginInstall._({
    required this.pluginId,
    required this.stagingDirectoryPath,
    required this.targetDirectoryPath,
    required this.pluginJson,
    required Directory pluginsRoot,
    required this.targetExistedAtPreparation,
    required String transactionFilePath,
  }) : _pluginsRoot = pluginsRoot,
       _transactionFilePath = transactionFilePath;

  bool get isCommitted => _committed;
  bool get isCompleted => _completed;
  bool get hadExistingPlugin =>
      targetExistedAtPreparation || _backupDirectoryPath != null;

  Future<void> commit() => PluginLoader._commitPreparedInstall(this);

  Future<void> complete() => PluginLoader._completePreparedInstall(this);

  Future<void> rollback() => PluginLoader._rollbackPreparedInstall(this);

  Future<void> recordExpectedInstalledPlugin(Map<String, dynamic> pluginState) {
    return PluginLoader._recordExpectedPluginState(this, pluginState);
  }
}

@immutable
class PluginInstallRecoveryResult {
  final int finalizedTransactions;
  final int rolledBackTransactions;
  final int failedTransactions;

  const PluginInstallRecoveryResult({
    required this.finalizedTransactions,
    required this.rolledBackTransactions,
    required this.failedTransactions,
  });

  bool get hasFailures => failedTransactions > 0;
}

class _PluginInstallTransaction {
  final String pluginId;
  final String stagingName;
  final String targetName;
  final String? backupName;
  final String phase;
  final bool targetExistedAtPreparation;
  final String? expectedPluginStateHash;

  const _PluginInstallTransaction({
    required this.pluginId,
    required this.stagingName,
    required this.targetName,
    required this.backupName,
    required this.phase,
    required this.targetExistedAtPreparation,
    required this.expectedPluginStateHash,
  });
}

enum _PluginInstallRecoveryAction { finalized, rolledBack }

class _ArchivePreflight {
  final String manifestPath;
  final String archivePrefix;

  const _ArchivePreflight({
    required this.manifestPath,
    required this.archivePrefix,
  });
}

class PluginLoader {
  static const PluginArchiveLimits defaultArchiveLimits = PluginArchiveLimits();
  static const int _transactionVersion = 1;
  static const int _maxTransactionBytes = 64 * 1024;
  static const String _transactionPrefix = '.transaction-';
  static const String _transactionPhasePrepared = 'prepared';
  static const String _transactionPhaseCommitting = 'committing';
  static const String _transactionPhaseCommitted = 'committed';
  static const String _transactionPhaseRollingBack = 'rolling_back';
  static const String _transactionPhaseRolledBack = 'rolled_back';
  static final Random _secureRandom = Random.secure();
  static final Set<String> _activeTransactionPaths = <String>{};
  static final Map<String, Future<PluginInstallRecoveryResult>>
  _activeRecoveries = <String, Future<PluginInstallRecoveryResult>>{};
  static final RegExp _pluginIdPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
  );
  static final RegExp _windowsReservedName = RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
    caseSensitive: false,
  );

  static String validatePluginId(String rawPluginId) {
    final pluginId = rawPluginId.trim();
    final firstComponent = pluginId.split('.').first;
    final invalid =
        pluginId.isEmpty ||
        pluginId != rawPluginId ||
        pluginId.contains('..') ||
        pluginId.contains('/') ||
        pluginId.contains('\\') ||
        pluginId.contains(':') ||
        pluginId.contains('\u0000') ||
        pluginId.endsWith('.') ||
        p.posix.isAbsolute(pluginId) ||
        p.windows.isAbsolute(pluginId) ||
        !_pluginIdPattern.hasMatch(pluginId) ||
        _windowsReservedName.hasMatch(firstComponent);

    if (invalid) {
      throw const PluginInstallException(
        PluginInstallFailure.invalidPluginId,
        'ID extension không hợp lệ. Chỉ dùng chữ, số, dấu chấm, gạch ngang và gạch dưới; không dùng đường dẫn hoặc "..".',
      );
    }
    return pluginId;
  }

  static Future<PreparedPluginInstall> prepareInstallFromUrl(
    String url, {
    String? customId,
    Directory? pluginsRoot,
    Directory? temporaryRoot,
    PluginArchiveLimits limits = defaultArchiveLimits,
    http.Client? client,
  }) async {
    if (customId != null) {
      validatePluginId(customId);
    }

    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException {
      throw const PluginInstallException(
        PluginInstallFailure.invalidDownloadUrl,
        'URL tải extension không đúng định dạng.',
      );
    }
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const PluginInstallException(
        PluginInstallFailure.invalidDownloadUrl,
        'URL tải extension phải là HTTP/HTTPS hợp lệ, có host và không chứa thông tin đăng nhập.',
      );
    }

    final tempBase = temporaryRoot ?? await getTemporaryDirectory();
    await tempBase.create(recursive: true);
    final downloadDir = await tempBase.createTemp('vbook-plugin-install-');
    final zipFile = File(p.join(downloadDir.path, 'plugin.zip'));
    final effectiveClient = client ?? http.Client();

    try {
      final request = http.Request('GET', uri);
      final response = await effectiveClient
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw PluginInstallException(
          PluginInstallFailure.downloadFailed,
          'Không thể tải extension (HTTP ${response.statusCode}).',
        );
      }
      final contentLength = response.contentLength;
      if (contentLength != null && contentLength > limits.maxZipBytes) {
        throw PluginInstallException(
          PluginInstallFailure.archiveTooLarge,
          'File ZIP vượt quá giới hạn ${_formatMiB(limits.maxZipBytes)}.',
        );
      }

      var downloadedBytes = 0;
      final sink = zipFile.openWrite();
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          downloadedBytes += chunk.length;
          if (downloadedBytes > limits.maxZipBytes) {
            throw PluginInstallException(
              PluginInstallFailure.archiveTooLarge,
              'File ZIP vượt quá giới hạn ${_formatMiB(limits.maxZipBytes)}.',
            );
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      final prepared = await prepareInstallFromZipFile(
        zipFile,
        customId: customId,
        pluginsRoot: pluginsRoot,
        limits: limits,
      );
      try {
        await _deleteTemporaryTree(downloadDir);
      } catch (error) {
        await prepared.rollback();
        throw PluginInstallException(
          PluginInstallFailure.cleanupFailed,
          'Không thể dọn file tải tạm của extension: $error',
        );
      }
      return prepared;
    } on PluginInstallException {
      await _tryDeleteTemporaryTree(downloadDir);
      rethrow;
    } catch (error) {
      await _tryDeleteTemporaryTree(downloadDir);
      throw PluginInstallException(
        PluginInstallFailure.downloadFailed,
        'Không thể tải hoặc chuẩn bị extension: $error',
      );
    } finally {
      if (client == null) {
        effectiveClient.close();
      }
    }
  }

  static Future<PreparedPluginInstall> prepareInstallFromZipFile(
    File zipFile, {
    String? customId,
    Directory? pluginsRoot,
    PluginArchiveLimits limits = defaultArchiveLimits,
  }) async {
    if (customId != null) {
      validatePluginId(customId);
    }

    final zipLength = await zipFile.length();
    if (zipLength > limits.maxZipBytes) {
      throw PluginInstallException(
        PluginInstallFailure.archiveTooLarge,
        'File ZIP vượt quá giới hạn ${_formatMiB(limits.maxZipBytes)}.',
      );
    }
    if (zipLength == 0) {
      throw const PluginInstallException(
        PluginInstallFailure.invalidArchive,
        'File ZIP extension rỗng.',
      );
    }

    final bytes = await zipFile.readAsBytes();
    late final _ArchivePreflight preflight;
    late final Archive archive;
    try {
      final directory = ZipDirectory.read(InputStream(bytes));
      preflight = _preflightArchive(directory, limits);
      archive = ZipDecoder().decodeBytes(bytes);
    } on PluginInstallException {
      rethrow;
    } catch (error) {
      throw PluginInstallException(
        PluginInstallFailure.invalidArchive,
        'File ZIP extension không hợp lệ: $error',
      );
    }

    Directory? stagingDirectory;
    PreparedPluginInstall? prepared;
    try {
      final manifestFile = archive.files.firstWhere(
        (file) =>
            _normalizeArchiveEntry(file.name, limits) == preflight.manifestPath,
      );
      final manifestBytes = _archiveFileBytes(manifestFile, limits);
      final dynamic decodedManifest = jsonDecode(
        utf8.decode(manifestBytes, allowMalformed: false),
      );
      if (decodedManifest is! Map<String, dynamic>) {
        throw const PluginInstallException(
          PluginInstallFailure.invalidManifest,
          'plugin.json phải là một JSON object hợp lệ.',
        );
      }

      final manifestPluginId = _manifestPluginId(decodedManifest);
      final pluginId = validatePluginId(
        customId ??
            manifestPluginId ??
            'plugin_${DateTime.now().microsecondsSinceEpoch}',
      );
      final root = await _resolvePluginsRoot(pluginsRoot);
      final targetDirectory = Directory(_safeChildPath(root.path, pluginId));
      final targetType = await FileSystemEntity.type(
        targetDirectory.path,
        followLinks: false,
      );
      if (targetType != FileSystemEntityType.notFound &&
          targetType != FileSystemEntityType.directory) {
        throw const PluginInstallException(
          PluginInstallFailure.unsafeDestination,
          'Đích cài extension hiện có không phải thư mục an toàn.',
        );
      }

      stagingDirectory = await root.createTemp('.install-$pluginId-');
      _requirePathInside(root.path, stagingDirectory.path);
      final transactionFilePath = await _unusedChildPath(
        root,
        '$_transactionPrefix$pluginId-',
      );
      prepared = PreparedPluginInstall._(
        pluginId: pluginId,
        stagingDirectoryPath: stagingDirectory.path,
        targetDirectoryPath: targetDirectory.path,
        pluginJson: Map<String, dynamic>.unmodifiable(decodedManifest),
        pluginsRoot: root,
        targetExistedAtPreparation:
            targetType == FileSystemEntityType.directory,
        transactionFilePath: transactionFilePath,
      );
      _activeTransactionPaths.add(_normalizedPath(transactionFilePath));
      await _writeTransaction(prepared);

      var actualExpandedBytes = 0;
      final extractedPaths = <String>{};
      for (final file in archive) {
        final archivePath = _normalizeArchiveEntry(file.name, limits);
        final relativePath = _relativeToArchivePrefix(
          archivePath,
          preflight.archivePrefix,
        );
        if (relativePath == null || relativePath.isEmpty) {
          continue;
        }

        final outputPath = p.normalize(
          p.joinAll([stagingDirectory.path, ...relativePath.split('/')]),
        );
        _requirePathInside(stagingDirectory.path, outputPath);
        final comparableOutputPath = Platform.isWindows
            ? outputPath.toLowerCase()
            : outputPath;
        if (!extractedPaths.add(comparableOutputPath)) {
          throw PluginInstallException(
            PluginInstallFailure.unsafeEntryPath,
            'File ZIP chứa đường dẫn trùng lặp: $relativePath',
          );
        }

        if (file.isSymbolicLink) {
          throw const PluginInstallException(
            PluginInstallFailure.symbolicLink,
            'File ZIP không được chứa symbolic link.',
          );
        }
        if (!file.isFile) {
          await Directory(outputPath).create(recursive: true);
          continue;
        }

        final data = _archiveFileBytes(file, limits);
        actualExpandedBytes += data.length;
        if (actualExpandedBytes > limits.maxTotalUncompressedBytes) {
          throw PluginInstallException(
            PluginInstallFailure.expandedArchiveTooLarge,
            'Dữ liệu giải nén vượt quá giới hạn ${_formatMiB(limits.maxTotalUncompressedBytes)}.',
          );
        }
        final outputFile = File(outputPath);
        await outputFile.parent.create(recursive: true);
        await outputFile.writeAsBytes(data, flush: true);
      }

      if (!await File(p.join(stagingDirectory.path, 'plugin.json')).exists()) {
        throw const PluginInstallException(
          PluginInstallFailure.missingManifest,
          'Không tìm thấy plugin.json ở thư mục gốc của extension.',
        );
      }

      return prepared;
    } on PluginInstallException {
      if (prepared != null) {
        await prepared.rollback();
      } else if (stagingDirectory != null) {
        await _deletePathInsideRoot(
          stagingDirectory.path,
          rootOverride: pluginsRoot,
        );
      }
      rethrow;
    } catch (error) {
      if (prepared != null) {
        await prepared.rollback();
      } else if (stagingDirectory != null) {
        await _deletePathInsideRoot(
          stagingDirectory.path,
          rootOverride: pluginsRoot,
        );
      }
      throw PluginInstallException(
        PluginInstallFailure.invalidArchive,
        'Không thể giải nén extension: $error',
      );
    } finally {
      await archive.clear();
    }
  }

  static Future<String> getPluginDir(
    String pluginId, {
    Directory? pluginsRoot,
  }) async {
    final safePluginId = validatePluginId(pluginId);
    final root = await _resolvePluginsRoot(pluginsRoot);
    return _safeChildPath(root.path, safePluginId);
  }

  static Future<void> deletePlugin(
    String pluginId, {
    Directory? pluginsRoot,
  }) async {
    final safePluginId = validatePluginId(pluginId);
    final root = await _resolvePluginsRoot(pluginsRoot);
    final pluginPath = _safeChildPath(root.path, safePluginId);
    await _deleteEntityNoFollow(root.path, pluginPath);
  }

  static Future<PluginInstallRecoveryResult> recoverInterruptedInstalls({
    Directory? pluginsRoot,
    Map<String, Map<String, dynamic>> installedPluginStates = const {},
  }) async {
    final root = await _resolvePluginsRoot(pluginsRoot);
    final rootKey = _normalizedPath(root.path);
    final activeRecovery = _activeRecoveries[rootKey];
    if (activeRecovery != null) {
      return activeRecovery;
    }

    final recovery = _recoverInterruptedInstallsInRoot(
      root,
      installedPluginStates,
    );
    _activeRecoveries[rootKey] = recovery;
    try {
      return await recovery;
    } finally {
      if (identical(_activeRecoveries[rootKey], recovery)) {
        _activeRecoveries.remove(rootKey);
      }
    }
  }

  @visibleForTesting
  static void forgetActiveTransactionsForTesting() {
    _activeTransactionPaths.clear();
  }

  static Future<List<String>> getInstalledPluginPaths({
    Directory? pluginsRoot,
  }) async {
    try {
      final root = await _resolvePluginsRoot(pluginsRoot);
      final paths = <String>[];
      await for (final entity in root.list(followLinks: false)) {
        if (entity is Directory && !p.basename(entity.path).startsWith('.')) {
          paths.add(entity.path);
        }
      }
      return paths;
    } catch (error) {
      debugPrint('getInstalledPluginPaths error: $error');
      return [];
    }
  }

  static _ArchivePreflight _preflightArchive(
    ZipDirectory directory,
    PluginArchiveLimits limits,
  ) {
    final headers = directory.fileHeaders;
    if (headers.length > limits.maxEntries) {
      throw PluginInstallException(
        PluginInstallFailure.tooManyEntries,
        'File ZIP có quá nhiều entry (${headers.length}/${limits.maxEntries}).',
      );
    }

    var totalUncompressedBytes = 0;
    final normalizedPaths = <String>{};
    final manifestPaths = <String>[];

    for (final header in headers) {
      if ((header.generalPurposeBitFlag & 0x1) != 0) {
        throw const PluginInstallException(
          PluginInstallFailure.invalidArchive,
          'Không hỗ trợ file ZIP extension được mã hóa.',
        );
      }

      final archivePath = _normalizeArchiveEntry(header.filename, limits);
      final comparablePath = Platform.isWindows
          ? archivePath.toLowerCase()
          : archivePath;
      if (!normalizedPaths.add(comparablePath)) {
        throw PluginInstallException(
          PluginInstallFailure.unsafeEntryPath,
          'File ZIP chứa entry trùng lặp: $archivePath',
        );
      }

      final unixFileType =
          ((header.externalFileAttributes ?? 0) >> 16) & 0xF000;
      final madeOnUnix = header.versionMadeBy >> 8 == 3;
      if (madeOnUnix && unixFileType == 0xA000) {
        throw const PluginInstallException(
          PluginInstallFailure.symbolicLink,
          'File ZIP không được chứa symbolic link.',
        );
      }
      if (madeOnUnix &&
          unixFileType != 0 &&
          unixFileType != 0x4000 &&
          unixFileType != 0x8000) {
        throw const PluginInstallException(
          PluginInstallFailure.symbolicLink,
          'File ZIP chứa loại filesystem entry không được hỗ trợ.',
        );
      }

      final isDirectory =
          archivePath.endsWith('/') || (madeOnUnix && unixFileType == 0x4000);
      final uncompressedSize = header.uncompressedSize ?? 0;
      final compressedSize = header.compressedSize ?? 0;
      if (uncompressedSize < 0 || compressedSize < 0) {
        throw const PluginInstallException(
          PluginInstallFailure.invalidArchive,
          'File ZIP chứa kích thước entry không hợp lệ.',
        );
      }
      if (!isDirectory && uncompressedSize > limits.maxEntryBytes) {
        throw PluginInstallException(
          PluginInstallFailure.entryTooLarge,
          'Entry "$archivePath" vượt quá giới hạn ${_formatMiB(limits.maxEntryBytes)}.',
        );
      }

      totalUncompressedBytes += uncompressedSize;
      if (totalUncompressedBytes > limits.maxTotalUncompressedBytes) {
        throw PluginInstallException(
          PluginInstallFailure.expandedArchiveTooLarge,
          'Dữ liệu giải nén vượt quá giới hạn ${_formatMiB(limits.maxTotalUncompressedBytes)}.',
        );
      }
      if (!isDirectory && uncompressedSize > 0) {
        if (compressedSize == 0 ||
            uncompressedSize / compressedSize > limits.maxCompressionRatio) {
          throw PluginInstallException(
            PluginInstallFailure.suspiciousCompressionRatio,
            'Entry "$archivePath" có tỉ lệ nén vượt quá giới hạn ${limits.maxCompressionRatio.toStringAsFixed(0)}:1.',
          );
        }
      }

      if (!isDirectory && p.posix.basename(archivePath) == 'plugin.json') {
        manifestPaths.add(archivePath);
      }
    }

    if (manifestPaths.isEmpty) {
      throw const PluginInstallException(
        PluginInstallFailure.missingManifest,
        'Không tìm thấy plugin.json trong file ZIP extension.',
      );
    }
    manifestPaths.sort(
      (left, right) =>
          left.split('/').length.compareTo(right.split('/').length),
    );
    final shallowestDepth = manifestPaths.first.split('/').length;
    final shallowestManifests = manifestPaths
        .where((path) => path.split('/').length == shallowestDepth)
        .toList();
    if (shallowestManifests.length != 1) {
      throw const PluginInstallException(
        PluginInstallFailure.invalidManifest,
        'File ZIP chứa nhiều plugin.json cùng cấp và không thể xác định extension chính.',
      );
    }

    final manifestPath = shallowestManifests.single;
    final slashIndex = manifestPath.lastIndexOf('/');
    final prefix = slashIndex < 0
        ? ''
        : manifestPath.substring(0, slashIndex + 1);
    return _ArchivePreflight(manifestPath: manifestPath, archivePrefix: prefix);
  }

  static String _normalizeArchiveEntry(
    String rawPath,
    PluginArchiveLimits limits,
  ) {
    if (rawPath.isEmpty || rawPath.contains('\u0000')) {
      throw const PluginInstallException(
        PluginInstallFailure.unsafeEntryPath,
        'File ZIP chứa đường dẫn entry rỗng hoặc không hợp lệ.',
      );
    }
    final unified = rawPath.replaceAll('\\', '/');
    if (unified.length > limits.maxEntryPathLength ||
        unified.startsWith('/') ||
        unified.startsWith('//') ||
        p.posix.isAbsolute(unified) ||
        p.windows.isAbsolute(rawPath) ||
        RegExp(r'^[A-Za-z]:').hasMatch(unified)) {
      throw PluginInstallException(
        PluginInstallFailure.unsafeEntryPath,
        'File ZIP chứa đường dẫn tuyệt đối hoặc quá dài: $rawPath',
      );
    }

    final hasTrailingSlash = unified.endsWith('/');
    final segments = unified.split('/');
    if (hasTrailingSlash) {
      segments.removeLast();
    }
    if (segments.isEmpty ||
        segments.any(
          (segment) =>
              segment.isEmpty ||
              segment == '.' ||
              segment == '..' ||
              segment.contains(':'),
        )) {
      throw PluginInstallException(
        PluginInstallFailure.unsafeEntryPath,
        'File ZIP chứa đường dẫn traversal hoặc không hợp lệ: $rawPath',
      );
    }

    final normalized = segments.join('/');
    return hasTrailingSlash ? '$normalized/' : normalized;
  }

  static List<int> _archiveFileBytes(
    ArchiveFile file,
    PluginArchiveLimits limits,
  ) {
    final content = file.content;
    if (content is! List<int>) {
      throw const PluginInstallException(
        PluginInstallFailure.invalidArchive,
        'Không thể đọc dữ liệu entry trong file ZIP.',
      );
    }
    if (content.length > limits.maxEntryBytes || content.length != file.size) {
      throw PluginInstallException(
        PluginInstallFailure.entryTooLarge,
        'Kích thước thực tế của entry "${file.name}" không hợp lệ.',
      );
    }
    return content;
  }

  static String? _manifestPluginId(Map<String, dynamic> manifest) {
    final directId = manifest['id']?.toString().trim();
    if (directId != null && directId.isNotEmpty) {
      return directId;
    }
    final metadata = manifest['metadata'];
    if (metadata is Map) {
      final metadataId = metadata['id']?.toString().trim();
      if (metadataId != null && metadataId.isNotEmpty) {
        return metadataId;
      }
    }

    final nameCandidates = <dynamic>[
      manifest['name'],
      if (metadata is Map) metadata['name'],
    ];
    for (final candidate in nameCandidates) {
      final name = candidate?.toString().trim();
      if (name == null || name.isEmpty) {
        continue;
      }
      try {
        return validatePluginId(name);
      } on PluginInstallException {
        // A display name is optional as an ID; unsafe names use a generated ID.
      }
    }
    return null;
  }

  static String? _relativeToArchivePrefix(String path, String prefix) {
    if (prefix.isEmpty) {
      return path;
    }
    if (!path.startsWith(prefix)) {
      return null;
    }
    return path.substring(prefix.length);
  }

  static Future<Directory> _resolvePluginsRoot(Directory? override) async {
    final requestedRoot =
        override ??
        Directory(
          p.join(
            (await getApplicationDocumentsDirectory()).path,
            'vbook_plugins',
          ),
        );
    final absoluteRoot = Directory(p.normalize(requestedRoot.absolute.path));
    var type = await FileSystemEntity.type(
      absoluteRoot.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      await absoluteRoot.create(recursive: true);
      type = FileSystemEntityType.directory;
    }
    if (type != FileSystemEntityType.directory) {
      throw const PluginInstallException(
        PluginInstallFailure.unsafeDestination,
        'Plugin root không phải thư mục an toàn.',
      );
    }
    final resolvedRoot = await absoluteRoot.resolveSymbolicLinks();
    return Directory(p.normalize(resolvedRoot));
  }

  static String _safeChildPath(String rootPath, String childName) {
    final childPath = p.normalize(p.join(rootPath, childName));
    _requirePathInside(rootPath, childPath);
    return childPath;
  }

  static void _requirePathInside(String rootPath, String candidatePath) {
    final normalizedRoot = p.normalize(p.absolute(rootPath));
    final normalizedCandidate = p.normalize(p.absolute(candidatePath));
    if (!p.isWithin(normalizedRoot, normalizedCandidate)) {
      throw const PluginInstallException(
        PluginInstallFailure.unsafeDestination,
        'Đường dẫn cài đặt nằm ngoài plugin root.',
      );
    }
  }

  static Future<PluginInstallRecoveryResult> _recoverInterruptedInstallsInRoot(
    Directory root,
    Map<String, Map<String, dynamic>> installedPluginStates,
  ) async {
    var finalizedTransactions = 0;
    var rolledBackTransactions = 0;
    var failedTransactions = 0;

    await for (final entity in root.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!name.startsWith(_transactionPrefix)) {
        continue;
      }

      final transactionPath = _safeChildPath(root.path, name);
      if (_activeTransactionPaths.contains(_normalizedPath(transactionPath))) {
        continue;
      }

      try {
        final entityType = await FileSystemEntity.type(
          transactionPath,
          followLinks: false,
        );
        if (entityType != FileSystemEntityType.file) {
          throw const PluginInstallException(
            PluginInstallFailure.unsafeDestination,
            'Transaction journal không phải file an toàn.',
          );
        }

        final transaction = await _readTransaction(File(transactionPath));
        final action = await _recoverInterruptedTransaction(
          root,
          transactionPath,
          transaction,
          installedPluginStates[transaction.pluginId],
        );
        if (action == _PluginInstallRecoveryAction.finalized) {
          finalizedTransactions++;
        } else {
          rolledBackTransactions++;
        }
      } catch (error) {
        failedTransactions++;
        debugPrint(
          '[PluginLoader] Interrupted install recovery failed '
          '(${error.runtimeType}).',
        );
      }
    }

    return PluginInstallRecoveryResult(
      finalizedTransactions: finalizedTransactions,
      rolledBackTransactions: rolledBackTransactions,
      failedTransactions: failedTransactions,
    );
  }

  static Future<_PluginInstallRecoveryAction> _recoverInterruptedTransaction(
    Directory root,
    String transactionPath,
    _PluginInstallTransaction transaction,
    Map<String, dynamic>? installedPluginState,
  ) async {
    final stagingPath = _safeChildPath(root.path, transaction.stagingName);
    final targetPath = _safeChildPath(root.path, transaction.targetName);
    final backupPath = transaction.backupName == null
        ? null
        : _safeChildPath(root.path, transaction.backupName!);

    if (transaction.phase == _transactionPhaseRolledBack) {
      if (backupPath != null) {
        throw const PluginInstallException(
          PluginInstallFailure.cleanupFailed,
          'Rollback journal còn chứa backup không nhất quán.',
        );
      }
      await _deleteEntityNoFollow(root.path, stagingPath);
      await _deleteEntityNoFollow(root.path, transactionPath);
      return _PluginInstallRecoveryAction.rolledBack;
    }

    if (transaction.phase == _transactionPhaseRollingBack) {
      await _rollbackInterruptedTransaction(
        root: root,
        transactionPath: transactionPath,
        transaction: transaction,
        stagingPath: stagingPath,
        targetPath: targetPath,
        backupPath: backupPath,
      );
      return _PluginInstallRecoveryAction.rolledBack;
    }

    final targetType = await FileSystemEntity.type(
      targetPath,
      followLinks: false,
    );
    final expectedHash = transaction.expectedPluginStateHash;
    final installedStateMatches =
        expectedHash != null &&
        installedPluginState != null &&
        _pluginStateHash(installedPluginState) == expectedHash;

    if (transaction.phase != _transactionPhasePrepared &&
        installedStateMatches &&
        targetType == FileSystemEntityType.directory) {
      await _deleteEntityNoFollow(root.path, stagingPath);
      if (backupPath != null) {
        await _deleteEntityNoFollow(root.path, backupPath);
      }
      await _deleteEntityNoFollow(root.path, transactionPath);
      return _PluginInstallRecoveryAction.finalized;
    }

    await _rollbackInterruptedTransaction(
      root: root,
      transactionPath: transactionPath,
      transaction: transaction,
      stagingPath: stagingPath,
      targetPath: targetPath,
      backupPath: backupPath,
    );
    return _PluginInstallRecoveryAction.rolledBack;
  }

  static Future<void> _rollbackInterruptedTransaction({
    required Directory root,
    required String transactionPath,
    required _PluginInstallTransaction transaction,
    required String stagingPath,
    required String targetPath,
    required String? backupPath,
  }) async {
    if (transaction.phase == _transactionPhasePrepared) {
      await _deleteEntityNoFollow(root.path, stagingPath);
      await _deleteEntityNoFollow(root.path, transactionPath);
      return;
    }

    final backupType = backupPath == null
        ? FileSystemEntityType.notFound
        : await FileSystemEntity.type(backupPath, followLinks: false);
    final targetType = await FileSystemEntity.type(
      targetPath,
      followLinks: false,
    );
    final stagingType = await FileSystemEntity.type(
      stagingPath,
      followLinks: false,
    );
    final hadExistingPlugin =
        transaction.targetExistedAtPreparation || backupPath != null;

    if (hadExistingPlugin) {
      if (backupType == FileSystemEntityType.directory) {
        if (targetType != FileSystemEntityType.notFound &&
            targetType != FileSystemEntityType.directory) {
          throw const PluginInstallException(
            PluginInstallFailure.cleanupFailed,
            'Không thể khôi phục plugin qua đích không an toàn.',
          );
        }
      } else if (backupType != FileSystemEntityType.notFound) {
        throw const PluginInstallException(
          PluginInstallFailure.cleanupFailed,
          'Backup plugin không phải thư mục an toàn.',
        );
      } else {
        final noRenameBegan =
            transaction.phase == _transactionPhaseCommitting &&
            targetType == FileSystemEntityType.directory &&
            stagingType == FileSystemEntityType.directory;
        final backupAlreadyRestored =
            transaction.phase == _transactionPhaseRollingBack &&
            targetType == FileSystemEntityType.directory &&
            (stagingType == FileSystemEntityType.directory ||
                stagingType == FileSystemEntityType.notFound);
        if (!noRenameBegan && !backupAlreadyRestored) {
          throw const PluginInstallException(
            PluginInstallFailure.cleanupFailed,
            'Không thể xác định an toàn bản plugin cần khôi phục.',
          );
        }
      }
    } else {
      if (targetType != FileSystemEntityType.notFound &&
          targetType != FileSystemEntityType.directory) {
        throw const PluginInstallException(
          PluginInstallFailure.cleanupFailed,
          'Không thể dọn đích plugin không an toàn.',
        );
      }
    }

    var recoveryTransaction = transaction;
    if (transaction.phase != _transactionPhaseRollingBack) {
      recoveryTransaction = _PluginInstallTransaction(
        pluginId: transaction.pluginId,
        stagingName: transaction.stagingName,
        targetName: transaction.targetName,
        backupName: transaction.backupName,
        phase: _transactionPhaseRollingBack,
        targetExistedAtPreparation: transaction.targetExistedAtPreparation,
        expectedPluginStateHash: transaction.expectedPluginStateHash,
      );
      await _appendTransactionRecord(
        File(transactionPath),
        _transactionRecord(recoveryTransaction),
      );
    }

    if (hadExistingPlugin) {
      if (backupType == FileSystemEntityType.directory) {
        await _deleteEntityNoFollow(root.path, targetPath);
        await Directory(backupPath!).rename(targetPath);
      }
    } else {
      await _deleteEntityNoFollow(root.path, targetPath);
    }

    await _deleteEntityNoFollow(root.path, stagingPath);
    final rolledBackTransaction = _PluginInstallTransaction(
      pluginId: recoveryTransaction.pluginId,
      stagingName: recoveryTransaction.stagingName,
      targetName: recoveryTransaction.targetName,
      backupName: null,
      phase: _transactionPhaseRolledBack,
      targetExistedAtPreparation:
          recoveryTransaction.targetExistedAtPreparation,
      expectedPluginStateHash: recoveryTransaction.expectedPluginStateHash,
    );
    await _appendTransactionRecord(
      File(transactionPath),
      _transactionRecord(rolledBackTransaction),
    );
    await _deleteEntityNoFollow(root.path, transactionPath);
  }

  static Future<_PluginInstallTransaction> _readTransaction(File file) async {
    final length = await file.length();
    if (length <= 0 || length > _maxTransactionBytes) {
      throw const PluginInstallException(
        PluginInstallFailure.invalidManifest,
        'Transaction journal có kích thước không hợp lệ.',
      );
    }

    final contents = await file.readAsString(encoding: utf8);
    Map<String, dynamic>? latestRecord;
    for (final line in const LineSplitter().convert(contents)) {
      if (line.trim().isEmpty) {
        continue;
      }
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) {
          latestRecord = decoded;
        }
      } on FormatException {
        // A process may stop during the final append; the previous line is valid.
      }
    }
    if (latestRecord == null) {
      throw const PluginInstallException(
        PluginInstallFailure.invalidManifest,
        'Transaction journal không có record hợp lệ.',
      );
    }
    return _decodeTransaction(latestRecord);
  }

  static _PluginInstallTransaction _decodeTransaction(
    Map<String, dynamic> record,
  ) {
    final version = record['version'];
    final rawPluginId = record['pluginId'];
    final stagingName = record['stagingName'];
    final targetName = record['targetName'];
    final backupName = record['backupName'];
    final phase = record['phase'];
    final targetExisted = record['targetExisted'];
    final expectedStateHash = record['expectedStateHash'];
    if (version != _transactionVersion ||
        rawPluginId is! String ||
        stagingName is! String ||
        targetName is! String ||
        (backupName != null && backupName is! String) ||
        phase is! String ||
        targetExisted is! bool ||
        (expectedStateHash != null && expectedStateHash is! String)) {
      throw const PluginInstallException(
        PluginInstallFailure.invalidManifest,
        'Transaction journal thiếu field hợp lệ.',
      );
    }

    final pluginId = validatePluginId(rawPluginId);
    final validPhases = <String>{
      _transactionPhasePrepared,
      _transactionPhaseCommitting,
      _transactionPhaseCommitted,
      _transactionPhaseRollingBack,
      _transactionPhaseRolledBack,
    };
    final validExpectedHash =
        expectedStateHash == null ||
        RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedStateHash);
    if (targetName != pluginId ||
        !_isTransactionChildName(stagingName, '.install-$pluginId-') ||
        (backupName != null &&
            !_isTransactionChildName(backupName, '.backup-$pluginId-')) ||
        !validPhases.contains(phase) ||
        !validExpectedHash ||
        (phase == _transactionPhasePrepared && backupName != null) ||
        (phase == _transactionPhaseRolledBack && backupName != null)) {
      throw const PluginInstallException(
        PluginInstallFailure.invalidManifest,
        'Transaction journal chứa dữ liệu không hợp lệ.',
      );
    }

    return _PluginInstallTransaction(
      pluginId: pluginId,
      stagingName: stagingName,
      targetName: targetName,
      backupName: backupName as String?,
      phase: phase,
      targetExistedAtPreparation: targetExisted,
      expectedPluginStateHash: expectedStateHash as String?,
    );
  }

  static bool _isTransactionChildName(String name, String requiredPrefix) {
    return name.startsWith(requiredPrefix) &&
        name.length > requiredPrefix.length &&
        p.posix.basename(name) == name &&
        p.windows.basename(name) == name &&
        name != '.' &&
        name != '..';
  }

  static Future<void> _recordExpectedPluginState(
    PreparedPluginInstall prepared,
    Map<String, dynamic> pluginState,
  ) async {
    if (prepared._completed || prepared._committed) {
      throw StateError(
        'Không thể đổi trạng thái mong đợi sau khi commit extension.',
      );
    }
    final previousHash = prepared._expectedPluginStateHash;
    prepared._expectedPluginStateHash = _pluginStateHash(pluginState);
    try {
      await _writeTransaction(prepared);
    } catch (_) {
      prepared._expectedPluginStateHash = previousHash;
      rethrow;
    }
  }

  static Future<void> _writeTransaction(PreparedPluginInstall prepared) async {
    final rootPath = prepared._pluginsRoot.path;
    _requirePathInside(rootPath, prepared._transactionFilePath);
    await _appendTransactionRecord(
      File(prepared._transactionFilePath),
      <String, dynamic>{
        'version': _transactionVersion,
        'pluginId': prepared.pluginId,
        'stagingName': p.basename(prepared.stagingDirectoryPath),
        'targetName': p.basename(prepared.targetDirectoryPath),
        'backupName': prepared._backupDirectoryPath == null
            ? null
            : p.basename(prepared._backupDirectoryPath!),
        'phase': prepared._phase,
        'targetExisted': prepared.targetExistedAtPreparation,
        'expectedStateHash': prepared._expectedPluginStateHash,
      },
    );
  }

  static Map<String, dynamic> _transactionRecord(
    _PluginInstallTransaction transaction,
  ) {
    return <String, dynamic>{
      'version': _transactionVersion,
      'pluginId': transaction.pluginId,
      'stagingName': transaction.stagingName,
      'targetName': transaction.targetName,
      'backupName': transaction.backupName,
      'phase': transaction.phase,
      'targetExisted': transaction.targetExistedAtPreparation,
      'expectedStateHash': transaction.expectedPluginStateHash,
    };
  }

  static Future<void> _appendTransactionRecord(
    File transactionFile,
    Map<String, dynamic> record,
  ) async {
    final type = await FileSystemEntity.type(
      transactionFile.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const PluginInstallException(
        PluginInstallFailure.unsafeDestination,
        'Transaction journal không phải file an toàn.',
      );
    }

    final line = '${jsonEncode(record)}\n';
    final existingLength = type == FileSystemEntityType.file
        ? await transactionFile.length()
        : 0;
    if (existingLength + utf8.encode(line).length > _maxTransactionBytes) {
      throw const PluginInstallException(
        PluginInstallFailure.cleanupFailed,
        'Transaction journal vượt quá giới hạn kích thước.',
      );
    }
    await transactionFile.writeAsString(
      line,
      mode: type == FileSystemEntityType.file
          ? FileMode.append
          : FileMode.write,
      flush: true,
    );
  }

  static String _pluginStateHash(Map<String, dynamic> pluginState) {
    final canonicalJson = jsonEncode(_canonicalizeJson(pluginState));
    return sha256.convert(utf8.encode(canonicalJson)).toString();
  }

  static Object? _canonicalizeJson(Object? value) {
    if (value is Map) {
      final keys = value.keys.toList();
      if (keys.any((key) => key is! String)) {
        throw const FormatException('JSON object key must be a string.');
      }
      final sortedKeys = keys.cast<String>()..sort();
      return <String, Object?>{
        for (final key in sortedKeys) key: _canonicalizeJson(value[key]),
      };
    }
    if (value is List) {
      return value.map(_canonicalizeJson).toList(growable: false);
    }
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    throw const FormatException('Unsupported JSON value.');
  }

  static String _normalizedPath(String path) => p.normalize(p.absolute(path));

  static Future<void> _commitPreparedInstall(
    PreparedPluginInstall prepared,
  ) async {
    if (prepared._completed) {
      throw StateError('Giao dịch cài extension đã kết thúc.');
    }
    if (prepared._committed) {
      return;
    }

    _requirePathInside(
      prepared._pluginsRoot.path,
      prepared.stagingDirectoryPath,
    );
    _requirePathInside(
      prepared._pluginsRoot.path,
      prepared.targetDirectoryPath,
    );
    final stagingType = await FileSystemEntity.type(
      prepared.stagingDirectoryPath,
      followLinks: false,
    );
    if (stagingType != FileSystemEntityType.directory) {
      throw const PluginInstallException(
        PluginInstallFailure.unsafeDestination,
        'Thư mục staging của extension không còn hợp lệ.',
      );
    }

    final targetType = await FileSystemEntity.type(
      prepared.targetDirectoryPath,
      followLinks: false,
    );
    if (targetType != FileSystemEntityType.notFound &&
        targetType != FileSystemEntityType.directory) {
      throw const PluginInstallException(
        PluginInstallFailure.unsafeDestination,
        'Không thể thay thế đích cài extension không an toàn.',
      );
    }

    String? backupPath;
    if (targetType == FileSystemEntityType.directory) {
      backupPath = await _unusedChildPath(
        prepared._pluginsRoot,
        '.backup-${prepared.pluginId}-',
      );
    }
    prepared._backupDirectoryPath = backupPath;
    prepared._phase = _transactionPhaseCommitting;
    await _writeTransaction(prepared);

    try {
      if (backupPath != null) {
        await Directory(prepared.targetDirectoryPath).rename(backupPath);
      }
      await Directory(
        prepared.stagingDirectoryPath,
      ).rename(prepared.targetDirectoryPath);
      prepared._committed = true;
      prepared._phase = _transactionPhaseCommitted;
      await _writeTransaction(prepared);
    } catch (_) {
      if (!prepared._committed && backupPath != null) {
        final backupType = await FileSystemEntity.type(
          backupPath,
          followLinks: false,
        );
        final currentTargetType = await FileSystemEntity.type(
          prepared.targetDirectoryPath,
          followLinks: false,
        );
        if (backupType == FileSystemEntityType.directory &&
            currentTargetType == FileSystemEntityType.notFound) {
          try {
            await Directory(backupPath).rename(prepared.targetDirectoryPath);
            prepared._backupDirectoryPath = null;
          } catch (_) {
            // The journal retains enough state for the next startup recovery.
          }
        }
      }
      rethrow;
    }
  }

  static Future<void> _completePreparedInstall(
    PreparedPluginInstall prepared,
  ) async {
    if (prepared._completed) {
      return;
    }
    if (!prepared._committed) {
      throw StateError('Không thể hoàn tất extension chưa được commit.');
    }

    try {
      final backupPath = prepared._backupDirectoryPath;
      if (backupPath != null) {
        await _deleteEntityNoFollow(prepared._pluginsRoot.path, backupPath);
        prepared._backupDirectoryPath = null;
      }
      await _deleteEntityNoFollow(
        prepared._pluginsRoot.path,
        prepared._transactionFilePath,
      );
      prepared._completed = true;
    } finally {
      _activeTransactionPaths.remove(
        _normalizedPath(prepared._transactionFilePath),
      );
    }
  }

  static Future<void> _rollbackPreparedInstall(
    PreparedPluginInstall prepared,
  ) async {
    if (prepared._completed) {
      return;
    }

    prepared._phase = _transactionPhaseRollingBack;
    try {
      await _writeTransaction(prepared);
    } catch (_) {
      // Cleanup must still proceed if the recovery marker cannot be appended.
    }

    try {
      final backupPath = prepared._backupDirectoryPath;
      final backupType = backupPath == null
          ? FileSystemEntityType.notFound
          : await FileSystemEntity.type(backupPath, followLinks: false);
      if (backupType == FileSystemEntityType.directory) {
        await _deleteEntityNoFollow(
          prepared._pluginsRoot.path,
          prepared.targetDirectoryPath,
        );
        await Directory(backupPath!).rename(prepared.targetDirectoryPath);
        prepared._backupDirectoryPath = null;
      } else if (backupType != FileSystemEntityType.notFound) {
        throw const PluginInstallException(
          PluginInstallFailure.cleanupFailed,
          'Backup plugin không phải thư mục an toàn.',
        );
      } else if (prepared._committed) {
        await _deleteEntityNoFollow(
          prepared._pluginsRoot.path,
          prepared.targetDirectoryPath,
        );
      }

      await _deleteEntityNoFollow(
        prepared._pluginsRoot.path,
        prepared.stagingDirectoryPath,
      );
      prepared._committed = false;
      prepared._phase = _transactionPhaseRolledBack;
      try {
        await _writeTransaction(prepared);
      } catch (_) {
        // The filesystem is already rolled back; remove the old journal below.
      }
      await _deleteEntityNoFollow(
        prepared._pluginsRoot.path,
        prepared._transactionFilePath,
      );
      prepared._completed = true;
    } finally {
      _activeTransactionPaths.remove(
        _normalizedPath(prepared._transactionFilePath),
      );
    }
  }

  static Future<void> _deletePathInsideRoot(
    String path, {
    Directory? rootOverride,
  }) async {
    final root = await _resolvePluginsRoot(rootOverride);
    await _deleteEntityNoFollow(root.path, path);
  }

  static Future<void> _deleteEntityNoFollow(
    String boundaryPath,
    String entityPath,
  ) async {
    _requirePathInside(boundaryPath, entityPath);
    final type = await FileSystemEntity.type(entityPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return;
    }
    if (type == FileSystemEntityType.link) {
      await Link(entityPath).delete();
      return;
    }
    if (type == FileSystemEntityType.file) {
      await File(entityPath).delete();
      return;
    }
    if (type != FileSystemEntityType.directory) {
      throw const PluginInstallException(
        PluginInstallFailure.cleanupFailed,
        'Không thể dọn filesystem entry không được hỗ trợ.',
      );
    }

    await for (final child in Directory(entityPath).list(followLinks: false)) {
      await _deleteEntityNoFollow(boundaryPath, child.path);
    }
    await Directory(entityPath).delete();
  }

  static Future<String> _unusedChildPath(Directory root, String prefix) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      final suffix =
          '${DateTime.now().microsecondsSinceEpoch}-${_secureRandom.nextInt(1 << 32)}';
      final candidate = _safeChildPath(root.path, '$prefix$suffix');
      final type = await FileSystemEntity.type(candidate, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return candidate;
      }
    }
    throw const PluginInstallException(
      PluginInstallFailure.unsafeDestination,
      'Không thể tạo đường dẫn giao dịch cài extension duy nhất.',
    );
  }

  static Future<void> _deleteTemporaryTree(Directory directory) async {
    final parent = directory.parent;
    await _deleteEntityNoFollow(parent.path, directory.path);
  }

  static Future<void> _tryDeleteTemporaryTree(Directory directory) async {
    try {
      await _deleteTemporaryTree(directory);
    } catch (error) {
      debugPrint('Temporary plugin download cleanup failed: $error');
    }
  }

  static String _formatMiB(int bytes) {
    final value = bytes / (1024 * 1024);
    return '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)} MiB';
  }
}
