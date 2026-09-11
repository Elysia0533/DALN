import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../google_drive_service.dart';
import 'book_metadata_extractor.dart';
import 'search_text_normalizer.dart';

typedef TxtMetadataLoader = Future<TxtMetadata> Function(String fileId);

class TxtMetadata extends BookMetadata {
  const TxtMetadata({super.title, super.authors, super.genres});
}

class TxtMetadataExtractor {
  static Future<TxtMetadata> extract(String fileId) =>
      BookMetadataExtraction.run(() async {
        final bytes = await GoogleDriveService.downloadTextMetadataPrefix(
          fileId,
        );
        return compute(parse, bytes);
      });

  static TxtMetadata parse(Uint8List bytes) {
    if (bytes.length > GoogleDriveService.textMetadataPrefixBytes) {
      throw const FormatException('TXT metadata prefix exceeds its limit.');
    }
    // UTF-8/BOM only. Do not guess a legacy encoding and persist mojibake.
    var text = utf8
        .decode(bytes, allowMalformed: true)
        .replaceFirst('\ufeff', '');
    if (text.contains('\u0000')) {
      throw const FormatException('Unsupported TXT encoding.');
    }
    if (bytes.length == GoogleDriveService.textMetadataPrefixBytes) {
      final end = text.lastIndexOf('\n');
      text = end < 0 ? '' : text.substring(0, end);
    }

    String? title;
    final authors = <String, String>{};
    final genres = <String, String>{};
    for (final rawLine in const LineSplitter().convert(text).take(128)) {
      final line = rawLine.trim();
      if (line.length > 1024 || line.contains('\ufffd')) continue;
      final normalized = SearchTextNormalizer.normalize(line);
      if (RegExp(r'^(chuong|chapter|hoi)\s+\d').hasMatch(normalized)) break;
      final colon = line.indexOf(':');
      if (colon < 1) continue;
      final label = SearchTextNormalizer.normalize(line.substring(0, colon));
      final value = line.substring(colon + 1).trim();
      if (value.isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) continue;
      switch (label) {
        case 'title' || 'ten truyen' || 'ten tac pham' || 'tac pham':
          if (value.length <= 512) title ??= value;
        case 'author' || 'authors' || 'tac gia':
          _addLabels(authors, value, RegExp(r'[;|]'));
        case 'genre' || 'genres' || 'the loai':
          _addLabels(genres, value, RegExp(r'[,;|]'));
      }
    }
    return TxtMetadata(
      title: title,
      authors: authors.values.toList(growable: false),
      genres: genres.values.toList(growable: false),
    );
  }

  static void _addLabels(
    Map<String, String> target,
    String value,
    RegExp split,
  ) {
    for (final part in value.split(split)) {
      final original = part.trim();
      final key = SearchTextNormalizer.normalize(original);
      if (key.isNotEmpty && original.length <= 160 && target.length < 32) {
        target.putIfAbsent(key, () => original);
      }
    }
  }
}
