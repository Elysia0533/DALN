import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/services/google_drive_service.dart';
import 'package:online_story_reader/services/search/epub_metadata_extractor.dart';

import 'support/epub_metadata_fixture.dart';

void main() {
  test(
    'deflated OPF is parsed in an isolate without changing original Vietnamese text',
    () async {
      final result = await compute(
        EpubMetadataExtractor.parse,
        epubMetadataFixture(),
      );
      expect(result.title, 'Trời Xanh');
      expect(result.authors, ['Nguyễn An']);
      expect(result.genres, ['Tiên Hiệp']);
      expect(result.description, 'A short description.');
    },
  );

  test(
    'stored EPUB 2 metadata after 512 KiB is found using the complete archive',
    () {
      final bytes = epubMetadataFixture(
        compress: false,
        extraEntries: {'OPS/chapter.xhtml': List.filled(600 * 1024, 65)},
        opf:
            '<package xmlns="http://www.idpf.org/2007/opf" version="2.0">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">$sampleOpfMetadata</metadata></package>',
      );
      expect(bytes.length, greaterThan(512 * 1024));
      expect(EpubMetadataExtractor.parse(bytes).title, 'Trời Xanh');
      expect(
        () => EpubMetadataExtractor.parse(
          Uint8List.sublistView(bytes, 0, 512 * 1024),
        ),
        throwsFormatException,
      );
    },
  );

  test('EPUB 2 and 3 explicit non-author creator roles are excluded', () {
    final metadata = EpubMetadataExtractor.parse(
      epubMetadataFixture(
        metadata: '''
<dc:title>Book</dc:title>
<dc:creator xmlns:opf="http://www.idpf.org/2007/opf" opf:role="ill">Artist</dc:creator>
<dc:creator id="editor">Editor</dc:creator><meta refines="#editor" property="role">edt</meta>
<dc:creator id="author">Author</dc:creator><meta refines="#author" property="role">aut</meta>
<dc:creator>Author</dc:creator><dc:subject>Fantasy</dc:subject><dc:subject>fantasy</dc:subject>
''',
      ),
    );
    expect(metadata.authors, ['Author']);
    expect(metadata.genres, ['Fantasy']);
  });

  test(
    'publisher contributor and arbitrary XML names are not author or genre evidence',
    () {
      final result = EpubMetadataExtractor.parse(
        epubMetadataFixture(
          metadata: '''
<dc:title>Only title</dc:title><dc:publisher>Publisher</dc:publisher>
<dc:contributor>Translator</dc:contributor><creator>Wrong namespace</creator>
''',
        ),
      );
      expect(result.title, 'Only title');
      expect(result.authors, isEmpty);
      expect(result.genres, isEmpty);
    },
  );

  test('empty metadata does not invent a title or author', () {
    final result = EpubMetadataExtractor.parse(
      epubMetadataFixture(metadata: ''),
    );
    expect(result.title, isNull);
    expect(result.authors, isEmpty);
    expect(result.genres, isEmpty);
  });

  test('metadata fields and relation counts are bounded', () {
    final result = EpubMetadataExtractor.parse(
      epubMetadataFixture(
        metadata:
            '<dc:title>${'a' * 513}</dc:title><dc:description>${'a' * 8193}</dc:description>'
            '${List.generate(40, (i) => '<dc:subject>Genre $i</dc:subject>').join()}',
      ),
    );
    expect(result.title, isNull);
    expect(result.description, isEmpty);
    expect(result.genres, hasLength(32));
  });

  for (final path in [
    '../book.opf',
    '/OPS/book.opf',
    'https://example.test/book.opf',
    'OPS//book.opf',
  ]) {
    test('container rejects an unsafe OPF reference $path', () {
      final bytes = epubMetadataFixture(
        container:
            '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
            '<rootfile full-path="$path" media-type="application/oebps-package+xml"/>'
            '</rootfiles></container>',
      );
      expect(() => EpubMetadataExtractor.parse(bytes), throwsFormatException);
    });
  }

  test(
    'missing or malformed ZIP container and OPF fail without leaking XML',
    () {
      final invalid = [
        Uint8List(10),
        epubMetadataFixture(includeContainer: false),
        epubMetadataFixture(includeOpf: false),
        epubMetadataFixture(opf: '<private-metadata>'),
        epubMetadataFixture(container: '<container/>'),
      ];
      for (final bytes in invalid) {
        expect(
          () => EpubMetadataExtractor.parse(bytes),
          throwsA(
            predicate(
              (error) =>
                  error is FormatException &&
                  !error.toString().contains('private-metadata'),
            ),
          ),
        );
      }
    },
  );

  test('DTDs are refused before XML parsing', () {
    final bytes = epubMetadataFixture(
      opf:
          '<!DOCTYPE package [<!ENTITY external SYSTEM "file:///not-read">]><package>&external;</package>',
    );
    expect(() => EpubMetadataExtractor.parse(bytes), throwsFormatException);
  });

  test(
    'wrong CRC encrypted metadata and unsupported compression are rejected',
    () {
      final bytes = epubMetadataFixture();
      for (final corrupt in [
        corruptEpubEntry(bytes, 'OPS/book.opf', crc: 1),
        corruptEpubEntry(bytes, 'OPS/book.opf', flags: 1),
        corruptEpubEntry(bytes, 'OPS/book.opf', method: 12),
      ]) {
        expect(
          () => EpubMetadataExtractor.parse(corrupt),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'inflation is bounded even when the declared uncompressed size is forged',
    () {
      final bytes = epubMetadataFixture(
        metadata: '<dc:description>${'A' * (1024 * 1024)}</dc:description>',
      );
      expect(bytes.length, lessThan(64 * 1024));
      final forged = corruptEpubEntry(bytes, 'OPS/book.opf', size: 128);
      expect(() => EpubMetadataExtractor.parse(forged), throwsFormatException);
    },
  );

  test('file container OPF and entry-count limits are enforced', () {
    expect(
      () => EpubMetadataExtractor.parse(
        Uint8List(GoogleDriveService.epubMetadataMaxBytes + 1),
      ),
      throwsFormatException,
    );
    expect(
      () => EpubMetadataExtractor.parse(
        epubMetadataFixture(
          container: 'a' * (EpubMetadataExtractor.maxContainerBytes + 1),
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => EpubMetadataExtractor.parse(
        epubMetadataFixture(opf: 'a' * (EpubMetadataExtractor.maxOpfBytes + 1)),
      ),
      throwsFormatException,
    );
    final crowded = epubMetadataFixture(
      extraEntries: {
        for (var i = 0; i < EpubMetadataExtractor.maxEntries; i++)
          'OPS/$i': [65],
      },
    );
    expect(() => EpubMetadataExtractor.parse(crowded), throwsFormatException);
  });

  test(
    'duplicate and traversal ZIP entries are refused without filesystem extraction',
    () {
      final bytes = epubMetadataFixture(
        extraEntries: {'OPS/dupe.opf': utf8.encode('Ignored')},
      );
      final duplicate = corruptEpubEntry(
        bytes,
        'OPS/dupe.opf',
        rename: 'OPS/book.opf',
      );
      expect(
        () => EpubMetadataExtractor.parse(duplicate),
        throwsFormatException,
      );
      expect(
        () => EpubMetadataExtractor.parse(
          epubMetadataFixture(
            extraEntries: {
              '../outside': [65],
            },
          ),
        ),
        throwsFormatException,
      );
    },
  );

  test('unrelated chapter content is neither inflated nor CRC-checked', () {
    final bytes = epubMetadataFixture(
      extraEntries: {'OPS/chapter.xhtml': utf8.encode('BOOK BODY')},
    );
    final corruptChapter = corruptEpubEntry(
      bytes,
      'OPS/chapter.xhtml',
      crc: 1,
      size: 1024 * 1024 * 1024,
    );
    expect(EpubMetadataExtractor.parse(corruptChapter).title, 'Trời Xanh');
  });
}
