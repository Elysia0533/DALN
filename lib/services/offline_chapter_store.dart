import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/online_chapter_content.dart';
import 'book_file_names.dart';
import 'chapter_image_service.dart';

typedef ChapterImageLoader =
    Future<Uint8List> Function(String url, {required String referer});

class OfflineChapterStore {
  static const maxChapterBytes = 128 * 1024 * 1024;

  static Future<OnlineChapterContent?> read(
    Directory folder,
    int index, {
    String chapterUrl = '',
    String sourceType = 'novel',
  }) async {
    if (index < 0) throw ArgumentError('Invalid chapter index.');
    final file = File(p.join(folder.path, 'chap_$index.json'));
    if (!await file.exists()) return null;
    await _requireRegularFile(folder, file, maxChapterBytes);
    final data = jsonDecode(await file.readAsString());
    if (data is! Map || data['content'] is! String) {
      throw const FormatException('Invalid saved chapter.');
    }
    final content = OnlineChapterContent.decode(
      data['content'] as String,
      chapterUrl: chapterUrl.isNotEmpty
          ? chapterUrl
          : (data['chapterUrl'] as String? ?? ''),
      sourceType: sourceType,
    );
    final blocks = <ChapterBlock>[];
    for (final block in content.blocks) {
      if (!block.isLocal) {
        blocks.add(block);
        continue;
      }
      if (!block.isImage || p.isAbsolute(block.value)) {
        throw const FormatException('Invalid saved image path.');
      }
      final image = File(p.normalize(p.join(folder.path, block.value)));
      await _requireRegularFile(folder, image, ChapterImageService.maxBytes);
      blocks.add(ChapterBlock.image(image.path, isLocal: true));
    }
    return OnlineChapterContent(blocks: blocks, isComic: content.isComic);
  }

  static Future<bool> isComplete(
    Directory folder,
    int index, {
    bool requireCurrentFormat = false,
  }) async {
    try {
      final content = await read(folder, index);
      if (requireCurrentFormat && content != null) {
        final record = jsonDecode(
          await File(p.join(folder.path, 'chap_$index.json')).readAsString(),
        );
        if (record is! Map || record['schemaVersion'] != 2) return false;
      }
      return content != null &&
          content.blocks.every((b) => !b.isImage || b.isLocal);
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    } on TypeError {
      return false;
    }
  }

  static Future<void> write({
    required Directory folder,
    required int index,
    required String pluginId,
    required String storyTitle,
    required String chapterTitle,
    required String chapterUrl,
    required OnlineChapterContent content,
    required ChapterImageLoader loadImage,
    required bool Function() isCancelled,
  }) async {
    if (index < 0) throw ArgumentError('Invalid chapter index.');
    final id = const Uuid().v4();
    final staging = Directory(p.join(folder.path, '.partial-$id'));
    final media = Directory(p.join(folder.path, 'images-$id'));
    final record = File(p.join(folder.path, 'chap_$index.json'));
    final temporary = File('${record.path}.$id.partial');
    var committed = false;
    try {
      final blocks = <ChapterBlock>[];
      var totalBytes = 0;
      var imageIndex = 0;
      for (final block in content.blocks) {
        if (isCancelled()) {
          throw const FileSystemException('Download cancelled.');
        }
        if (!block.isImage) {
          blocks.add(block);
          continue;
        }
        final bytes = await loadImage(block.value, referer: chapterUrl);
        totalBytes += bytes.length;
        if (bytes.length > ChapterImageService.maxBytes ||
            totalBytes > maxChapterBytes) {
          throw const FormatException('Chapter image size limit.');
        }
        final extension = ChapterImageService.extensionFor(bytes);
        if (!await staging.exists()) await staging.create();
        final name =
            '${BookFileNames.stem(chapterTitle)}-${++imageIndex}.$extension';
        await File(p.join(staging.path, name)).writeAsBytes(bytes, flush: true);
        blocks.add(
          ChapterBlock.image(p.posix.join('images-$id', name), isLocal: true),
        );
      }
      if (isCancelled()) throw const FileSystemException('Download cancelled.');
      if (await staging.exists()) await staging.rename(media.path);
      final saved = OnlineChapterContent(
        blocks: blocks,
        isComic: content.isComic,
      );
      await temporary.writeAsString(
        jsonEncode({
          'schemaVersion': 2,
          'pluginId': pluginId,
          'storyTitle': storyTitle,
          'chapterTitle': chapterTitle,
          'chapterIndex': index,
          'chapterUrl': chapterUrl,
          'content': saved.encode(),
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
        flush: true,
      );
      if (isCancelled()) throw const FileSystemException('Download cancelled.');
      await temporary.rename(record.path);
      committed = true;
    } finally {
      if (await temporary.exists()) await temporary.delete();
      if (await staging.exists()) await _removeOwnedDirectory(folder, staging);
      if (!committed && await media.exists()) {
        await _removeOwnedDirectory(folder, media);
      }
    }
  }

  static Future<void> _requireRegularFile(
    Directory folder,
    File file,
    int maxBytes,
  ) async {
    final root = p.normalize(p.absolute(folder.path));
    final target = p.normalize(p.absolute(file.path));
    if (!p.isWithin(root, target) ||
        await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const FormatException('Invalid saved file.');
    }
    final resolvedRoot = await folder.resolveSymbolicLinks();
    final resolvedFile = await file.resolveSymbolicLinks();
    final size = await file.length();
    if (!p.isWithin(resolvedRoot, resolvedFile) ||
        size <= 0 ||
        size > maxBytes) {
      throw const FormatException('Invalid saved file.');
    }
  }

  static Future<void> _removeOwnedDirectory(
    Directory folder,
    Directory directory,
  ) async {
    final root = await folder.resolveSymbolicLinks();
    final target = await directory.resolveSymbolicLinks();
    if (!p.isWithin(root, target) ||
        p.dirname(target) != root ||
        await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const FileSystemException('Unsafe download cleanup.');
    }
    await directory.delete(recursive: true);
  }
}
