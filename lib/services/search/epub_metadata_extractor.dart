import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data' show BytesBuilder;

import 'package:archive/archive.dart' hide ZLibDecoder;
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import '../google_drive_service.dart';
import 'book_metadata_extractor.dart';
import 'search_text_normalizer.dart';

class EpubMetadataExtractor {
  static const maxContainerBytes = 64 * 1024;
  static const maxOpfBytes = 512 * 1024;
  static const maxEntries = 4096;
  static const _containerNamespace =
      'urn:oasis:names:tc:opendocument:xmlns:container';
  static const _opfNamespace = 'http://www.idpf.org/2007/opf';
  static const _dcNamespace = 'http://purl.org/dc/elements/1.1/';

  static Future<BookMetadata> extract(String fileId) =>
      BookMetadataExtraction.run(() async {
        final bytes = await GoogleDriveService.downloadEpubMetadataFile(fileId);
        return compute(parse, bytes);
      });

  static BookMetadata parse(Uint8List bytes) {
    try {
      if (bytes.isEmpty ||
          bytes.length > GoogleDriveService.epubMetadataMaxBytes) {
        throw const FormatException('EPUB file size limit.');
      }
      final directory = ZipDirectory.read(InputStream(bytes));
      if (directory.numberOfThisDisk != 0 ||
          directory.diskWithTheStartOfTheCentralDirectory != 0 ||
          directory.fileHeaders.isEmpty ||
          directory.fileHeaders.length > maxEntries ||
          directory.totalCentralDirectoryEntries !=
              directory.fileHeaders.length) {
        throw const FormatException('Invalid EPUB directory.');
      }
      final entries = <String, ZipFileHeader>{};
      for (final header in directory.fileHeaders) {
        final name = header.filename;
        _validatePath(name, directory: name.endsWith('/'));
        final type = ((header.externalFileAttributes ?? 0) >> 16) & 0xf000;
        if (entries.containsKey(name) ||
            (header.versionMadeBy >> 8 == 3 &&
                type != 0 &&
                type != 0x8000 &&
                type != 0x4000)) {
          throw const FormatException('Ambiguous EPUB entry.');
        }
        entries[name] = header;
      }

      final container = _readXml(
        entries['META-INF/container.xml'],
        maxContainerBytes,
      );
      if (!_isElement(
        container.rootElement,
        'container',
        _containerNamespace,
      )) {
        throw const FormatException('Invalid EPUB container.');
      }
      final rootfiles = container.rootElement.childElements
          .where((node) => _isElement(node, 'rootfiles', _containerNamespace))
          .single;
      final primary = rootfiles.childElements.firstWhere(
        (node) =>
            _isElement(node, 'rootfile', _containerNamespace) &&
            node.getAttribute('media-type') == 'application/oebps-package+xml',
      );
      final opfPath = primary.getAttribute('full-path') ?? '';
      _validatePath(opfPath);
      final package = _readXml(entries[opfPath], maxOpfBytes).rootElement;
      if (!_isElement(package, 'package', _opfNamespace)) {
        throw const FormatException('Invalid EPUB package.');
      }
      final metadata = package.childElements
          .where((node) => _isElement(node, 'metadata', _opfNamespace))
          .single;
      final authors = <String, String>{};
      final genres = <String, String>{};
      final rolesByCreator = <String, List<String>>{};
      for (final meta in metadata.childElements) {
        final refines = meta.getAttribute('refines');
        if (_isElement(meta, 'meta', _opfNamespace) &&
            meta.getAttribute('property') == 'role' &&
            refines != null &&
            refines.startsWith('#')) {
          rolesByCreator
              .putIfAbsent(refines.substring(1), () => [])
              .add(meta.innerText.trim());
        }
      }
      String? title;
      var description = '';
      for (final node in metadata.childElements) {
        if (node.name.namespaceUri != _dcNamespace) continue;
        switch (node.name.local) {
          case 'title':
            title ??= _text(node, 512);
          case 'creator':
            final roles = <String>[
              if (node.getAttribute('role', namespace: _opfNamespace)
                  case final String role)
                role.trim(),
              ...rolesByCreator[node.getAttribute('id')] ?? const <String>[],
            ];
            if (roles.isEmpty || roles.contains('aut')) {
              _addLabel(authors, _text(node, 160));
            }
          case 'subject':
            _addLabel(genres, _text(node, 160));
          case 'description':
            if (description.isEmpty) description = _text(node, 8192) ?? '';
        }
      }
      return BookMetadata(
        title: title,
        authors: authors.values.toList(growable: false),
        genres: genres.values.toList(growable: false),
        description: description,
      );
    } catch (_) {
      // Parser exceptions may include XML snippets or filenames from the book.
      throw const FormatException('EPUB metadata could not be parsed.');
    }
  }

  static XmlDocument _readXml(ZipFileHeader? header, int maxBytes) {
    final file = header?.file;
    final size = header?.uncompressedSize;
    if (header == null ||
        file == null ||
        size == null ||
        size < 1 ||
        size > maxBytes ||
        (header.generalPurposeBitFlag & 1) != 0 ||
        (file.flags & 1) != 0 ||
        header.compressionMethod != file.compressionMethod ||
        header.compressedSize != file.rawContent?.length) {
      throw const FormatException('Invalid EPUB metadata entry.');
    }
    final raw = file.rawContent!.toUint8List();
    List<int> data;
    if (header.compressionMethod == ZipFile.zipCompressionStore) {
      data = raw;
    } else if (header.compressionMethod == ZipFile.zipCompressionDeflate) {
      // Do not use ZipFile.content: archive 3.x inflates it without an output cap.
      final output = _BoundedMetadataSink(size);
      final decoder = ZLibDecoder(raw: true).startChunkedConversion(output);
      for (var start = 0; start < raw.length; start += 4096) {
        final end = start + 4096 < raw.length ? start + 4096 : raw.length;
        decoder.add(Uint8List.sublistView(raw, start, end));
      }
      decoder.close();
      data = output.bytes.takeBytes();
    } else {
      throw const FormatException('Unsupported EPUB compression.');
    }
    if (data.length != size || getCrc32(data) != header.crc32) {
      throw const FormatException('Corrupt EPUB metadata.');
    }
    final text = utf8.decode(data);
    if (RegExp(r'<!\s*(DOCTYPE|ENTITY)', caseSensitive: false).hasMatch(text)) {
      throw const FormatException('EPUB metadata DTD is not supported.');
    }
    return XmlDocument.parse(text);
  }

  static bool _isElement(XmlElement node, String name, String namespace) =>
      node.name.local == name && node.name.namespaceUri == namespace;

  static void _validatePath(String path, {bool directory = false}) {
    final value = directory ? path.substring(0, path.length - 1) : path;
    if (value.isEmpty ||
        value.length > 512 ||
        RegExp(r'[\\:\x00-\x1f\x7f]').hasMatch(value) ||
        value
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const FormatException('Invalid EPUB entry path.');
    }
  }

  static String? _text(XmlElement node, int limit) {
    final value = node.innerText.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (value.isEmpty ||
        value.length > limit ||
        value.contains('\ufffd') ||
        RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(value)) {
      return null;
    }
    return value;
  }

  static void _addLabel(Map<String, String> labels, String? value) {
    if (value != null && labels.length < 32) {
      labels.putIfAbsent(SearchTextNormalizer.normalize(value), () => value);
    }
  }
}

class _BoundedMetadataSink implements Sink<List<int>> {
  _BoundedMetadataSink(this.limit);
  final int limit;
  final bytes = BytesBuilder();

  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) {
      throw const FormatException('EPUB metadata inflation limit.');
    }
    bytes.add(data);
  }

  @override
  void close() {}
}
