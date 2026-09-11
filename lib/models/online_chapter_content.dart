import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'source_models.dart';

class ChapterBlock {
  const ChapterBlock.text(this.value) : isImage = false, isLocal = false;
  const ChapterBlock.image(this.value, {this.isLocal = false}) : isImage = true;

  final String value;
  final bool isImage;
  final bool isLocal;

  Map<String, Object> toJson() => {
    'type': isImage ? 'image' : 'text',
    'value': value,
    if (isLocal) 'local': true,
  };
}

class OnlineChapterContent {
  const OnlineChapterContent({required this.blocks, required this.isComic});

  static const maxTextLength = 2 * 1024 * 1024;
  static const maxImages = 256;
  final List<ChapterBlock> blocks;
  final bool isComic;

  String get text =>
      blocks.where((b) => !b.isImage).map((b) => b.value).join('\n\n');
  bool get hasImages => blocks.any((b) => b.isImage);

  String encode() => jsonEncode({
    'schemaVersion': 1,
    'kind': isComic ? 'comic' : 'novel',
    'blocks': blocks.map((b) => b.toJson()).toList(growable: false),
  });

  factory OnlineChapterContent.fromPages(
    List<Page> pages, {
    required String chapterUrl,
    required String sourceType,
  }) {
    final blocks = <ChapterBlock>[];
    for (final page in pages) {
      final raw = page.imageUrl.isNotEmpty ? page.imageUrl : page.url;
      if (raw.startsWith('vbook-text://')) {
        blocks.addAll(
          _parseText(raw.substring('vbook-text://'.length), chapterUrl),
        );
      } else if (_imageSource(raw, chapterUrl) case final String image) {
        blocks.add(ChapterBlock.image(image));
      } else {
        blocks.addAll(_parseText(raw, chapterUrl));
      }
    }
    _validateBlocks(blocks);
    return OnlineChapterContent(
      blocks: blocks,
      isComic: sourceType.trim().toLowerCase() == 'comic',
    );
  }

  factory OnlineChapterContent.decode(
    String stored, {
    required String chapterUrl,
    required String sourceType,
  }) {
    final trimmed = stored.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        // Old plain-text chapters can start with a bracket.
      }
      if (decoded is Map && decoded.containsKey('schemaVersion')) {
        if (decoded['schemaVersion'] != 1 ||
            decoded['blocks'] is! List ||
            !['comic', 'novel'].contains(decoded['kind'])) {
          throw const FormatException('Unsupported offline chapter format.');
        }
        final blocks = <ChapterBlock>[];
        for (final value in decoded['blocks'] as List) {
          if (value is! Map ||
              value['value'] is! String ||
              !['image', 'text'].contains(value['type'])) {
            throw const FormatException('Invalid offline chapter block.');
          }
          blocks.add(
            value['type'] == 'image'
                ? ChapterBlock.image(
                    value['value'] as String,
                    isLocal: value['local'] == true,
                  )
                : ChapterBlock.text(value['value'] as String),
          );
        }
        _validateBlocks(blocks);
        return OnlineChapterContent(
          blocks: blocks,
          isComic: decoded['kind'] == 'comic',
        );
      }
      if (decoded is List) {
        final blocks = <ChapterBlock>[];
        for (final entry in decoded) {
          final image = entry is String
              ? _imageSource(entry, chapterUrl)
              : null;
          if (image == null) {
            throw const FormatException('Invalid legacy image page.');
          }
          blocks.add(ChapterBlock.image(image));
        }
        _validateBlocks(blocks);
        return OnlineChapterContent(blocks: blocks, isComic: true);
      }
    }
    return OnlineChapterContent.fromPages(
      [Page(0, chapterUrl, 'vbook-text://$stored')],
      chapterUrl: chapterUrl,
      sourceType: sourceType,
    );
  }

  static List<ChapterBlock> _parseText(String value, String chapterUrl) {
    if (value.length > maxTextLength) {
      throw const FormatException('Chapter text size limit.');
    }
    if (!RegExp(r'<\s*(?:/?[a-zA-Z]|!--)').hasMatch(value)) {
      final text = value.trim();
      return text.isEmpty ? [] : [ChapterBlock.text(text)];
    }
    final document = html.parseFragment(value);
    final blocks = <ChapterBlock>[];
    final buffer = StringBuffer();
    void flush() {
      final text = buffer
          .toString()
          .replaceAll('\u00a0', ' ')
          .replaceAll(RegExp(r'[ \t]+\n'), '\n')
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .trim();
      if (text.isNotEmpty) blocks.add(ChapterBlock.text(text));
      buffer.clear();
    }

    void visit(dom.Node node) {
      if (node is dom.Text) {
        buffer.write(node.data);
        return;
      }
      if (node is dom.Element) {
        final tag = node.localName;
        if (['script', 'style', 'iframe', 'noscript', 'svg'].contains(tag)) {
          return;
        }
        if (tag == 'img') {
          flush();
          final raw =
              node.attributes['data-src'] ??
              node.attributes['data-original'] ??
              node.attributes['data-lazy-src'] ??
              node.attributes['src'] ??
              '';
          final image = _imageSource(raw, chapterUrl, allowRelative: true);
          if (image == null) {
            throw const FormatException('Unsupported chapter image.');
          }
          blocks.add(ChapterBlock.image(image));
          return;
        }
        if (tag == 'br') {
          buffer.writeln();
          return;
        }
        final block = [
          'p',
          'div',
          'section',
          'h1',
          'h2',
          'h3',
          'li',
          'blockquote',
          'figure',
        ].contains(tag);
        if (block && buffer.isNotEmpty) buffer.writeln();
        for (final child in node.nodes) {
          visit(child);
        }
        if (block) buffer.writeln();
      } else {
        for (final child in node.nodes) {
          visit(child);
        }
      }
    }

    visit(document);
    flush();
    return blocks;
  }

  static String? _imageSource(
    String raw,
    String base, {
    bool allowRelative = false,
  }) {
    final value = raw.trim();
    if (value.startsWith('data:image/') ||
        value.startsWith('vbook-base64://')) {
      return value;
    }
    if (value.isEmpty || RegExp(r'[\s<>]').hasMatch(value)) return null;
    var uri = Uri.tryParse(value);
    if (uri == null) return null;
    if (!uri.hasScheme && (allowRelative || value.startsWith('//'))) {
      uri = Uri.tryParse(base)?.resolveUri(uri);
    }
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.toString();
  }

  static void _validateBlocks(List<ChapterBlock> blocks) {
    if (blocks.isEmpty ||
        blocks.any((b) => b.value.trim().isEmpty) ||
        blocks.where((b) => b.isImage).length > maxImages ||
        blocks
                .where((b) => !b.isImage)
                .fold<int>(0, (n, b) => n + b.value.length) >
            maxTextLength) {
      throw const FormatException('Empty or oversized chapter content.');
    }
  }
}
