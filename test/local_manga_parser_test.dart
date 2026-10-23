import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/services/local_manga_parser.dart';
import 'package:path/path.dart' as p;

void main() {
  group('LocalMangaParser Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('manga_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('naturalCompare sorts numbers correctly', () {
      final list = ['chap 10', 'chap 1', 'chap 2', 'chap 20'];
      list.sort(LocalMangaParser.naturalCompare);
      expect(list, ['chap 1', 'chap 2', 'chap 10', 'chap 20']);
    });

    test('parses directory with subfolders of images without chapter.json', () async {
      final chap1 = Directory(p.join(tempDir.path, 'Chap 1'))..createSync();
      final chap2 = Directory(p.join(tempDir.path, 'Chap 2'))..createSync();

      File(p.join(chap1.path, '001.jpg')).writeAsStringSync('fake-image-1');
      File(p.join(chap1.path, '002.png')).writeAsStringSync('fake-image-2');
      File(p.join(chap2.path, '001.webp')).writeAsStringSync('fake-image-3');

      final info = await LocalMangaParser.parse(directoryPath: tempDir.path);
      expect(info, isNotNull);
      expect(info!.chapters.length, 2);
      expect(info.chapters[0].title, 'Chap 1');
      expect(info.chapters[0].imageFiles.length, 2);
      expect(info.chapters[1].title, 'Chap 2');
      expect(info.chapters[1].imageFiles.length, 1);
    });

    test('parses directory with chapter.json list structure', () async {
      final folderA = Directory(p.join(tempDir.path, 'folder_1'))..createSync();
      final folderB = Directory(p.join(tempDir.path, 'folder_2'))..createSync();

      File(p.join(folderA.path, 'p1.jpg')).writeAsStringSync('fake');
      File(p.join(folderB.path, 'p2.jpg')).writeAsStringSync('fake');

      final chapterJson = File(p.join(tempDir.path, 'chapter.json'));
      chapterJson.writeAsStringSync(jsonEncode([
        {'title': 'Hồi 1: Khởi nguyên', 'folder': 'folder_1'},
        {'title': 'Hồi 2: Gặp gỡ', 'folder': 'folder_2'},
      ]));

      final info = await LocalMangaParser.parse(chapterJsonFilePath: chapterJson.path);
      expect(info, isNotNull);
      expect(info!.chapters.length, 2);
      expect(info.chapters[0].title, 'Hồi 1: Khởi nguyên');
      expect(info.chapters[1].title, 'Hồi 2: Gặp gỡ');
    });

    test('parses directory with chapter.json map structure', () async {
      final chapDir = Directory(p.join(tempDir.path, '01'))..createSync();
      File(p.join(chapDir.path, 'page1.jpg')).writeAsStringSync('fake');

      final chapterJson = File(p.join(tempDir.path, 'chapter.json'));
      chapterJson.writeAsStringSync(jsonEncode({
        'title': 'Bộ Truyện Tranh Cũ',
        'author': 'Oda',
        'chapters': [
          {'name': 'Chương 1', 'path': '01'}
        ]
      }));

      final info = await LocalMangaParser.parse(directoryPath: tempDir.path);
      expect(info, isNotNull);
      expect(info!.title, 'Bộ Truyện Tranh Cũ');
      expect(info.author, 'Oda');
      expect(info.chapters.length, 1);
      expect(info.chapters[0].title, 'Chương 1');
    });
  });
}
