import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:online_story_reader/models/online_chapter_content.dart';
import 'package:online_story_reader/models/plugin_info.dart';
import 'package:online_story_reader/services/chapter_image_service.dart';
import 'package:online_story_reader/services/offline_download_service.dart';
import 'package:online_story_reader/services/plugin/plugin_loader.dart';
import 'package:online_story_reader/services/plugin/vbook_engine_channel.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Flutter test uninstalls the target package at teardown. Run this only with an
// isolated test application ID/device, never over an installation with user data.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'physical Android image transport shares cookies and stores offline bytes',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Kiểm tra dữ liệu chương')),
        ),
      );
      final png = Uint8List.fromList(img.encodePng(img.Image(3, 4)));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      var protectedRequests = 0;
      var receivedCookie = false;
      var receivedReferer = false;
      final cookieName = 'vbook_media_test_${server.port}';
      server.listen((request) async {
        if (request.uri.path == '/session') {
          request.response.cookies.add(
            Cookie(cookieName, 'fixture')
              ..path = '/'
              ..httpOnly = true
              ..maxAge = 60,
          );
        } else {
          protectedRequests++;
          receivedCookie = request.cookies.any(
            (c) => c.name == cookieName && c.value == 'fixture',
          );
          receivedReferer =
              request.headers.value(HttpHeaders.refererHeader) ==
              '$base/chapter';
          if (!receivedCookie || !receivedReferer) {
            request.response.statusCode = 403;
          }
        }
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
        await request.response.close();
      });
      final root = await (await getTemporaryDirectory()).createTemp(
        'vbook-media-runtime-',
      );
      try {
        expect(
          await ChapterImageService.load(
            '$base/session',
            referer: '$base/chapter',
          ),
          png,
        );
        expect(
          await ChapterImageService.load(
            '$base/protected',
            referer: '$base/chapter',
          ),
          png,
        );
        expect(receivedCookie && receivedReferer, isTrue);
        final sourceDir = await Directory(p.join(root.path, 'plugin')).create();
        await File(p.join(sourceDir.path, 'plugin.json')).writeAsString(
          jsonEncode({
            'metadata': {
              'name': 'Runtime media fixture',
              'author': 'test',
              'version': 1,
              'source': base,
              'locale': 'vi',
              'type': 'novel',
            },
            'script': {'home': 'home.js', 'toc': 'toc.js', 'chap': 'chap.js'},
          }),
        );
        final scripts = await Directory(p.join(sourceDir.path, 'src')).create();
        await File(
          p.join(scripts.path, 'home.js'),
        ).writeAsString('function execute() { return Response.success([]); }');
        await File(
          p.join(scripts.path, 'toc.js'),
        ).writeAsString('function execute() { return Response.success([]); }');
        final chapterHtml = jsonEncode(
          '<p>Truoc</p><img src="$base/protected"><p>Sau</p>',
        );
        await File(p.join(scripts.path, 'chap.js')).writeAsString(
          'function execute() { return Response.success($chapterHtml); }',
        );
        const sourceId = 'runtime.media.fixture';
        final ready = await VBookEngineChannel.loadSource(
          sourceId,
          sourceDir.path,
        );
        expect(ready, isTrue);
        try {
          final pages = await VBookEngineChannel.getPageList(
            sourceId,
            '$base/chapter',
          );
          final content = OnlineChapterContent.fromPages(
            pages,
            chapterUrl: '$base/chapter',
            sourceType: 'novel',
          );
          expect(content.blocks.map((b) => b.isImage), [false, true, false]);
          final downloadRoot = await Directory(
            p.join(root.path, 'downloads'),
          ).create();
          final downloads = OfflineDownloadService.forTesting(
            directory: downloadRoot,
            loadPages: (_, url) =>
                VBookEngineChannel.getPageList(sourceId, url),
            prepareSource: (_) async => true,
            loadImage: ChapterImageService.load,
          );
          final plugin = PluginInfo(
            id: sourceId,
            name: 'Runtime media',
            version: 1,
            author: '',
            description: '',
            iconUrl: '',
            downloadUrl: '',
            locale: 'vi',
            source: base,
            type: 'novel',
          );
          await downloads.startBatchDownload(
            plugin: plugin,
            storyTitle: 'Runtime minh họa',
            chapters: [
              {'url': '$base/chapter', 'name': 'Minh họa'},
            ],
          );
          expect(downloads.status, DownloadStatus.completed);
          await server.close(force: true);
          final stored = await downloads.getDownloadedChapterContent(
            sourceId,
            'Runtime minh họa',
            0,
          );
          final saved = OnlineChapterContent.decode(
            stored!,
            chapterUrl: '',
            sourceType: 'novel',
          );
          expect(await File(saved.blocks[1].value).readAsBytes(), png);
          expect(
            await downloads.exportToEpub(sourceId, 'Runtime minh họa', 1),
            isNotNull,
          );
          debugPrint(
            '[RUNTIME] native cookies/referer, HTML images, offline bytes and EPUB verified; imageRequests=$protectedRequests',
          );
        } finally {
          await VBookEngineChannel.closeSource(sourceId);
        }
      } finally {
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );

  if (const bool.fromEnvironment('RUN_INSTALLED_EXTENSION_PROBE')) {
    testWidgets(
      'installed novel and comic sources return browse, TOC and chapter content',
      (tester) async {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('installed_plugins');
        final entries = raw == null ? <dynamic>[] : jsonDecode(raw) as List;
        final plugins = entries
            .map(
              (entry) =>
                  PluginInfo.fromJson(Map<String, dynamic>.from(entry as Map)),
            )
            .where(
              (plugin) =>
                  plugin.id.toLowerCase().contains('hako') ||
                  plugin.id.toLowerCase().contains('qq'),
            )
            .take(2)
            .toList();
        expect(
          plugins,
          isNotEmpty,
          reason: 'No requested real sources installed.',
        );
        for (final plugin in plugins) {
          final session = 'runtime.probe.${plugin.id}';
          try {
            expect(
              await VBookEngineChannel.loadSource(
                session,
                await PluginLoader.getPluginDir(plugin.id),
              ),
              isTrue,
            );
            final tabs = await VBookEngineChannel.getHomeTabs(session);
            final page = tabs.isEmpty
                ? await VBookEngineChannel.getLatestUpdates(session, 1)
                : await VBookEngineChannel.getMangaListByTab(
                    session,
                    tabs.first['input'] ?? '',
                    tabs.first['script'] ?? 'gen.js',
                    1,
                  );
            expect(page?.mangas, isNotEmpty);
            debugPrint(
              '[RUNTIME] source=${plugin.id} browseCount=${page!.mangas.length}',
            );
            final chapters = await VBookEngineChannel.getChapterList(
              session,
              page.mangas.first.url,
            );
            expect(chapters, isNotEmpty);
            final pages = await VBookEngineChannel.getPageList(
              session,
              chapters.first.url,
            );
            final content = OnlineChapterContent.fromPages(
              pages,
              chapterUrl: chapters.first.url,
              sourceType: plugin.type,
            );
            debugPrint(
              '[RUNTIME] source=${plugin.id} chapters=${chapters.length} blocks=${content.blocks.length} images=${content.blocks.where((b) => b.isImage).length}',
            );
            if (content.hasImages) {
              final image = content.blocks.firstWhere((b) => b.isImage);
              final bytes = await ChapterImageService.load(
                image.value,
                referer: chapters.first.url,
              );
              expect(bytes, isNotEmpty);
              debugPrint(
                '[RUNTIME] source=${plugin.id} firstImageBytes=${bytes.length}',
              );
            }
            if (plugin.id.toLowerCase().contains('hako')) {
              final matches = await VBookEngineChannel.getSearchManga(
                session,
                'Days gone',
                1,
              );
              final book = matches?.mangas
                  .where((b) => b.title.toLowerCase().trim() == 'days gone')
                  .firstOrNull;
              expect(
                book,
                isNotNull,
                reason: 'The supplied book was not returned by the source.',
              );
              final toc = await VBookEngineChannel.getChapterList(
                session,
                book!.url,
              );
              final illustration = toc.firstWhere(
                (chapter) =>
                    chapter.name.toLowerCase().contains('minh hoạ') ||
                    chapter.name.toLowerCase().contains('minh họa'),
              );
              final pages = await VBookEngineChannel.getPageList(
                session,
                illustration.url,
              );
              final illustrationContent = OnlineChapterContent.fromPages(
                pages,
                chapterUrl: illustration.url,
                sourceType: plugin.type,
              );
              expect(illustrationContent.hasImages, isTrue);
              final bytes = await ChapterImageService.load(
                illustrationContent.blocks.firstWhere((b) => b.isImage).value,
                referer: illustration.url,
              );
              debugPrint(
                '[RUNTIME] supplied Hako illustration imageBytes=${bytes.length}',
              );
            }
          } on VBookEngineException catch (error) {
            fail(
              'Source ${plugin.id}: ${error.code} during ${error.operation}',
            );
          } finally {
            await VBookEngineChannel.closeSource(session);
          }
        }
      },
    );
  }
}
