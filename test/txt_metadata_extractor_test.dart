import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/services/google_drive_service.dart';
import 'package:online_story_reader/services/search/txt_metadata_extractor.dart';

void main() {
  TxtMetadata parse(String text) =>
      TxtMetadataExtractor.parse(Uint8List.fromList(utf8.encode(text)));

  test(
    'Vietnamese UTF-8 BOM headers preserve original labels in an isolate',
    () async {
      final result = await compute(
        TxtMetadataExtractor.parse,
        Uint8List.fromList(
          utf8.encode(
            '\ufeffTên truyện: Bầu Trời Xanh\r\nTác giả: Nguyễn An\r\n'
            'Thể loại: Tiên Hiệp, Fantasy; Tiên hiệp\r\n',
          ),
        ),
      );
      expect(result.title, 'Bầu Trời Xanh');
      expect(result.authors, ['Nguyễn An']);
      expect(result.genres, ['Tiên Hiệp', 'Fantasy']);
    },
  );

  test(
    'English headers support multiple authors without splitting comma names',
    () {
      final result = parse(
        'TITLE: Book\nAuthors: Smith, John; Jane Doe | Smith, John\nGenres: Novel|Drama',
      );
      expect(result.title, 'Book');
      expect(result.authors, ['Smith, John', 'Jane Doe']);
      expect(result.genres, ['Novel', 'Drama']);
    },
  );

  test('no headers means no inferred title author or genre', () {
    final result = parse(
      'The famous author tells a fantasy story.\nUnlabelled title',
    );
    expect(result.title, isNull);
    expect(result.authors, isEmpty);
    expect(result.genres, isEmpty);
  });

  test('chapter body cannot supply book metadata', () {
    final result = parse(
      'Tên truyện: Truyện\nChương 1: Mở đầu\nTác giả: Nhân vật',
    );
    expect(result.title, 'Truyện');
    expect(result.authors, isEmpty);
  });

  test('only the bounded header section is parsed', () {
    final result = parse(
      '${List.filled(128, 'Preface').join('\n')}\nAuthor: Too late',
    );
    expect(result.authors, isEmpty);
  });

  test(
    'oversized values are ignored instead of truncated into invented metadata',
    () {
      final result = parse(
        'Title: ${'x' * 513}\nAuthor: ${'a' * 161}\nGenre: Novel',
      );
      expect(result.title, isNull);
      expect(result.authors, isEmpty);
      expect(result.genres, ['Novel']);
    },
  );

  test('UTF-8 errors cannot be persisted as a label', () {
    final result = TxtMetadataExtractor.parse(
      Uint8List.fromList([
        ...utf8.encode('Author: '),
        0xff,
        ...utf8.encode('\nGenre: Novel'),
      ]),
    );
    expect(result.authors, isEmpty);
    expect(result.genres, ['Novel']);
  });

  test('unsupported UTF-16 is explicit rather than guessed', () {
    expect(
      () =>
          TxtMetadataExtractor.parse(Uint8List.fromList([0xff, 0xfe, 0x41, 0])),
      throwsFormatException,
    );
  });

  test('a header cut by the byte cap is not saved', () {
    final bytes = Uint8List(GoogleDriveService.textMetadataPrefixBytes);
    bytes.fillRange(0, bytes.length, 32);
    final suffix = utf8.encode('\nAuthor: Incomplete');
    bytes.setRange(bytes.length - suffix.length, bytes.length, suffix);
    expect(TxtMetadataExtractor.parse(bytes).authors, isEmpty);
  });

  test('oversized input is rejected and label count is bounded', () {
    expect(
      () => TxtMetadataExtractor.parse(
        Uint8List(GoogleDriveService.textMetadataPrefixBytes + 1),
      ),
      throwsFormatException,
    );
    expect(
      parse('Genres: ${List.generate(40, (i) => 'Genre $i').join(',')}').genres,
      hasLength(32),
    );
  });
}
