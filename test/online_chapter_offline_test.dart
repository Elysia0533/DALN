import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:online_story_reader/models/online_chapter_content.dart';
import 'package:online_story_reader/models/plugin_info.dart';
import 'package:online_story_reader/models/source_models.dart';
import 'package:online_story_reader/models/story.dart';
import 'package:online_story_reader/services/api_service.dart';
import 'package:online_story_reader/services/book_file_names.dart';
import 'package:online_story_reader/services/offline_chapter_store.dart';
import 'package:online_story_reader/services/offline_download_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

PluginInfo plugin(String id, {String type = 'novel'}) => PluginInfo(
  id: id,
  name: id,
  version: 1,
  author: '',
  description: '',
  iconUrl: '',
  downloadUrl: '',
  locale: 'vi',
  source: 'https://example.org',
  type: type,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Uint8List png;
  const title = 'Tên truyện có minh họa';
  const url = 'https://example.org/book';
  const chapterUrl = '$url/chapter-1';
  const chapters = [
    {'name': 'Chương một', 'url': chapterUrl},
  ];
  List<Page> pages(String value) => [Page(0, chapterUrl, value)];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('vbook-offline-test-');
    png = Uint8List.fromList(img.encodePng(img.Image(2, 2)));
  });
  tearDown(() async => root.delete(recursive: true));

  OfflineDownloadService service({
    Future<List<Page>> Function(String, String)? load,
    ChapterImageLoader? image,
    Future<bool> Function(PluginInfo)? prepare,
  }) => OfflineDownloadService.forTesting(
    directory: root,
    loadPages:
        load ??
        (_, _) async =>
            pages('vbook-text://<p>Trước</p><img src="/image.png"><p>Sau</p>'),
    prepareSource: prepare ?? (_) async => true,
    loadImage: image ?? (_, {required referer}) async => png,
  );

  test(
    'HTML preserves ordered text, relative/lazy images and decoded entities',
    () {
      final result = OnlineChapterContent.fromPages(
        pages(
          'vbook-text://<p>Trước &amp; sau</p><img src="blank.gif" data-src="../cover.png"><p>Kết thúc</p><script>secret()</script>',
        ),
        chapterUrl: chapterUrl,
        sourceType: 'novel',
      );
      expect(result.blocks.map((b) => b.isImage), [false, true, false]);
      expect(result.blocks[1].value, 'https://example.org/cover.png');
      expect(result.text, 'Trước & sau\n\nKết thúc');
      expect(result.isComic, isFalse);
    },
  );
  test('single-page comic is still an image and retains source type', () {
    final result = OnlineChapterContent.fromPages(
      pages('https://cdn.example.org/page'),
      chapterUrl: chapterUrl,
      sourceType: 'comic',
    );
    expect(result.isComic, isTrue);
    expect(result.blocks.single.isImage, isTrue);
  });
  test('illustration-only novel is not empty', () {
    final result = OnlineChapterContent.fromPages(
      pages('vbook-text://<img src="//cdn.example.org/p.png">'),
      chapterUrl: chapterUrl,
      sourceType: 'novel',
    );
    expect(result.hasImages, isTrue);
    expect(result.text, isEmpty);
    expect(result.isComic, isFalse);
  });
  test('legacy text and remote comic arrays remain readable', () {
    expect(
      OnlineChapterContent.decode(
        '[Ghi chú]\nVăn bản',
        chapterUrl: chapterUrl,
        sourceType: 'novel',
      ).text,
      contains('Văn bản'),
    );
    final comic = OnlineChapterContent.decode(
      '["https://example.org/1.png"]',
      chapterUrl: chapterUrl,
      sourceType: 'novel',
    );
    expect(comic.isComic, isTrue);
    expect(comic.blocks.single.isLocal, isFalse);
  });
  for (final bad in [
    '',
    '<script>only script</script>',
    '<img src="file:///etc/passwd">',
    '<img src="https://user:pass@example.org/p.png">',
  ]) {
    test('empty/unsupported HTML is rejected: ${bad.length}', () {
      expect(
        () => OnlineChapterContent.fromPages(
          pages('vbook-text://$bad'),
          chapterUrl: chapterUrl,
          sourceType: 'novel',
        ),
        throwsFormatException,
      );
    });
  }
  test('invalid/future structured data is rejected', () {
    for (final value in [
      {'schemaVersion': 2, 'kind': 'novel', 'blocks': []},
      {
        'schemaVersion': 1,
        'kind': 'novel',
        'blocks': [
          {'type': 'text', 'value': 3},
        ],
      },
    ]) {
      expect(
        () => OnlineChapterContent.decode(
          jsonEncode(value),
          chapterUrl: chapterUrl,
          sourceType: 'novel',
        ),
        throwsFormatException,
      );
    }
  });
  test('large chapters and excessive image counts are rejected', () {
    expect(
      () => OnlineChapterContent.fromPages(
        pages('vbook-text://${'a' * (OnlineChapterContent.maxTextLength + 1)}'),
        chapterUrl: chapterUrl,
        sourceType: 'novel',
      ),
      throwsFormatException,
    );
    expect(
      () => OnlineChapterContent.fromPages(
        List.generate(
          257,
          (i) => Page(i, chapterUrl, 'https://example.org/$i.png'),
        ),
        chapterUrl: chapterUrl,
        sourceType: 'comic',
      ),
      throwsFormatException,
    );
  });
  test(
    'download persists real image bytes, restarts and exports embedded EPUB',
    () async {
      var imageCalls = 0;
      final downloads = service(
        image: (source, {required referer}) async {
          imageCalls++;
          expect(source, 'https://example.org/image.png');
          expect(referer, chapterUrl);
          return png;
        },
      );
      await downloads.startBatchDownload(
        plugin: plugin('test'),
        storyTitle: title,
        storyUrl: url,
        chapters: chapters,
      );
      expect(downloads.status, DownloadStatus.completed);
      expect(imageCalls, 1);
      final stories = await downloads.getDownloadedStories();
      expect(stories.single['chapterCount'], 1);
      expect(stories.single['type'], 'novel');
      expect(
        p.basename(stories.single['folderPath'] as String),
        startsWith(title),
      );
      final restarted = service(
        load: (_, _) async => throw StateError('Network disabled'),
        image: (_, {required referer}) async =>
            throw StateError('Network disabled'),
      );
      final stored = await restarted.getDownloadedChapterContent(
        'test',
        title,
        0,
        storyUrl: url,
      );
      final content = OnlineChapterContent.decode(
        stored!,
        chapterUrl: chapterUrl,
        sourceType: 'novel',
      );
      expect(content.blocks[1].isLocal, isTrue);
      expect(await File(content.blocks[1].value).readAsBytes(), png);
      expect(
        await restarted.isChapterDownloaded('test', title, 0, storyUrl: url),
        isTrue,
      );
      final epub = await restarted.exportToEpub(
        'test',
        title,
        1,
        storyUrl: url,
      );
      expect(p.basename(epub!.path), '$title.epub');
      final zip = ZipDecoder().decodeBytes(await epub.readAsBytes());
      final imageFile = zip.files.singleWhere(
        (f) => f.name.startsWith('OEBPS/images/'),
      );
      expect(imageFile.content, png);
      final html = utf8.decode(
        zip.findFile('OEBPS/chapter_0.html')!.content as List<int>,
      );
      expect(html.indexOf('Trước'), lessThan(html.indexOf('<img')));
      expect(html.indexOf('<img'), lessThan(html.indexOf('Sau')));
      expect(html, isNot(contains('https://example.org/image.png')));
      final txt = await restarted.exportToTxt('test', title, 1, storyUrl: url);
      expect(p.basename(txt!.path), '$title.txt');
      final text = await txt.readAsString();
      expect(text, contains('Trước'));
      expect(text, contains('[Minh họa:'));
      expect(text, isNot(contains('schemaVersion')));
      final second = await restarted.exportToTxt(
        'test',
        title,
        1,
        storyUrl: url,
      );
      expect(second!.path, isNot(txt.path));
    },
  );
  test(
    'failed images do not count as downloaded and retry performs work',
    () async {
      var fail = true;
      var calls = 0;
      final downloads = service(
        image: (_, {required referer}) async {
          calls++;
          if (fail) throw const FormatException('unavailable');
          return png;
        },
      );
      await downloads.startBatchDownload(
        plugin: plugin('test'),
        storyTitle: title,
        chapters: chapters,
      );
      expect(downloads.status, DownloadStatus.error);
      expect(downloads.downloadedCount, 0);
      expect(downloads.failedChapterIndices, [0]);
      expect(calls, 3);
      expect(
        (await downloads.getDownloadedStories()).single['chapterCount'],
        0,
      );
      fail = false;
      await downloads.retryFailedDownloads();
      expect(downloads.status, DownloadStatus.completed);
      expect(downloads.downloadedCount, 1);
      expect(calls, 4);
      expect(
        await root
            .list(recursive: true)
            .any((f) => p.basename(f.path).contains('partial')),
        isFalse,
      );
    },
  );
  test('empty response and failed preparation never mark completion', () async {
    for (final downloads in [
      service(load: (_, _) async => []),
      service(prepare: (_) async => false),
    ]) {
      await downloads.startBatchDownload(
        plugin: plugin('test'),
        storyTitle: title,
        chapters: chapters,
      );
      expect(downloads.status, DownloadStatus.error);
      expect(downloads.downloadedCount, 0);
    }
  });
  test('cancel during image transfer keeps chapter uncommitted', () async {
    final started = Completer<void>();
    final bytes = Completer<Uint8List>();
    final downloads = service(
      image: (_, {required referer}) {
        started.complete();
        return bytes.future;
      },
    );
    final task = downloads.startBatchDownload(
      plugin: plugin('test'),
      storyTitle: title,
      chapters: chapters,
    );
    await started.future;
    downloads.cancelDownload();
    bytes.complete(png);
    await task;
    expect(downloads.status, DownloadStatus.paused);
    expect(downloads.downloadedCount, 0);
    expect(await downloads.isChapterDownloaded('test', title, 0), isFalse);
  });
  test(
    'same title from different sources and book URLs stays separate',
    () async {
      final downloads = service();
      for (final identity in [('a', url), ('b', url), ('a', '$url-2')]) {
        await downloads.startBatchDownload(
          plugin: plugin(identity.$1),
          storyTitle: title,
          storyUrl: identity.$2,
          chapters: chapters,
        );
        expect(downloads.status, DownloadStatus.completed);
      }
      expect((await downloads.getDownloadedStories()).length, 3);
      expect(
        await downloads.isChapterDownloaded('a', title, 0, storyUrl: '$url-2'),
        isTrue,
      );
      await expectLater(
        downloads.getDownloadedChapterContent('a', title, 0),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
  test(
    'legacy folder without TOC remains readable and exports sparse indices',
    () async {
      final folder = await Directory(p.join(root.path, title)).create();
      await File(p.join(folder.path, 'chap_4.json')).writeAsString(
        jsonEncode({
          'pluginId': 'old',
          'storyTitle': title,
          'chapterTitle': 'Chương năm',
          'content': 'Dữ liệu cũ',
        }),
      );
      final downloads = service();
      expect(await downloads.isChapterDownloaded('old', title, 4), isTrue);
      final stories = await downloads.getDownloadedStories();
      expect(stories.single['chapterCount'], 1);
      expect(stories.single['firstChapterIndex'], 4);
      final txt = await downloads.exportToTxt('old', title, 1);
      expect(await txt!.readAsString(), contains('Chương năm'));
      expect(await txt.readAsString(), contains('Dữ liệu cũ'));
    },
  );
  test(
    'old URL-only comic is readable but incomplete until images are fetched',
    () async {
      final folder = await Directory(p.join(root.path, title)).create();
      await File(p.join(folder.path, 'chap_0.json')).writeAsString(
        jsonEncode({
          'pluginId': 'old',
          'storyTitle': title,
          'content': '["https://example.org/image.png"]',
        }),
      );
      expect(await OfflineChapterStore.isComplete(folder, 0), isFalse);
      final downloads = service(
        load: (_, _) async => pages('https://example.org/image.png'),
      );
      await downloads.startBatchDownload(
        plugin: plugin('old', type: 'comic'),
        storyTitle: title,
        chapters: chapters,
      );
      expect(downloads.status, DownloadStatus.completed);
      expect(await OfflineChapterStore.isComplete(folder, 0), isTrue);
      final result = await OfflineChapterStore.read(folder, 0);
      expect(result!.isComic, isTrue);
      expect(result.blocks.single.isLocal, isTrue);
    },
  );
  test('malformed records and escaping image paths are not complete', () async {
    final folder = await Directory(p.join(root.path, 'book')).create();
    for (final raw in [
      'broken',
      '{"content":8}',
      jsonEncode({
        'content': OnlineChapterContent(
          blocks: [const ChapterBlock.image('../outside.png', isLocal: true)],
          isComic: true,
        ).encode(),
      }),
    ]) {
      await File(p.join(folder.path, 'chap_0.json')).writeAsString(raw);
      expect(await OfflineChapterStore.isComplete(folder, 0), isFalse);
    }
  });
  test('missing saved image invalidates completion', () async {
    final downloads = service();
    await downloads.startBatchDownload(
      plugin: plugin('test'),
      storyTitle: title,
      chapters: chapters,
    );
    final folder = Directory(
      (await downloads.getDownloadedStories()).single['folderPath'] as String,
    );
    final content = await OfflineChapterStore.read(folder, 0);
    await File(content!.blocks[1].value).delete();
    expect(await OfflineChapterStore.isComplete(folder, 0), isFalse);
  });
  test(
    'explicit download refreshes legacy text without deleting the old copy on failure',
    () async {
      final folder = await Directory(p.join(root.path, title)).create();
      final file = File(p.join(folder.path, 'chap_0.json'));
      await file.writeAsString(
        jsonEncode({
          'pluginId': 'old',
          'storyTitle': title,
          'content': 'Văn bản cũ đã mất ảnh',
        }),
      );
      final failed = service(
        load: (_, _) async => throw const FormatException('offline'),
      );
      await failed.startBatchDownload(
        plugin: plugin('old'),
        storyTitle: title,
        chapters: chapters,
      );
      expect(failed.status, DownloadStatus.error);
      expect(
        (await OfflineChapterStore.read(folder, 0))!.text,
        contains('Văn bản cũ'),
      );
      final repaired = service();
      await repaired.startBatchDownload(
        plugin: plugin('old'),
        storyTitle: title,
        chapters: chapters,
      );
      expect(repaired.status, DownloadStatus.completed);
      expect((await OfflineChapterStore.read(folder, 0))!.hasImages, isTrue);
    },
  );
  test('BMP offline illustration exports as EPUB-compatible PNG', () async {
    final downloads = service(
      image: (_, {required referer}) async =>
          Uint8List.fromList(img.encodeBmp(img.Image(3, 4))),
    );
    await downloads.startBatchDownload(
      plugin: plugin('test'),
      storyTitle: title,
      chapters: chapters,
    );
    final epub = await downloads.exportToEpub('test', title, 1);
    final zip = ZipDecoder().decodeBytes(await epub!.readAsBytes());
    final image = zip.files.singleWhere(
      (entry) => entry.name.startsWith('OEBPS/images/'),
    );
    expect(image.name, endsWith('.png'));
    expect(img.decodePng(image.content as List<int>)!.width, 3);
  });
  test(
    'library save retains extension identity, type and URL on readback',
    () async {
      final story = Story(
        id: 'library-test',
        title: title,
        pluginId: 'hako',
        storyUrl: url,
        fileType: 'novel',
        totalChapters: 19,
      );
      await ApiService.importLocalStory(story);
      final saved = (await ApiService.fetchPersonalStories(
        repairCovers: false,
      )).single;
      expect(saved.pluginId, 'hako');
      expect(saved.storyUrl, url);
      expect(saved.fileType, 'novel');
      expect(saved.totalChapters, 19);
    },
  );
  test('delete refuses the base directory and unrelated folders', () async {
    final downloads = service();
    await expectLater(
      downloads.deleteDownloadedStory(root.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(await root.exists(), isTrue);
  });
  test(
    'filenames preserve title, sanitize paths and reserve without overwrite',
    () async {
      expect(BookFileNames.stem('Tên / truyện: hay?'), contains('Tên'));
      expect(BookFileNames.stem('../CON'), isNot('CON'));
      expect(BookFileNames.stem('CON'), '_CON');
      expect(
        utf8.encode(BookFileNames.stem('ấ' * 200)).length,
        lessThanOrEqualTo(160),
      );
      final first = await BookFileNames.availableFile(root, title, 'txt');
      await first.writeAsString('keep');
      final second = await BookFileNames.availableFile(root, title, 'txt');
      expect(first.path, isNot(second.path));
      expect(await first.readAsString(), 'keep');
      expect(await second.exists(), isTrue);
    },
  );
}
