import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:online_story_reader/models/online_chapter_content.dart';
import 'package:online_story_reader/models/plugin_info.dart';
import 'package:online_story_reader/screens/download_manager_screen.dart';
import 'package:online_story_reader/screens/online_chapter_reader_screen.dart';
import 'package:online_story_reader/screens/profile_screen.dart';
import 'package:online_story_reader/services/offline_download_service.dart';
import 'package:online_story_reader/theme/reading_settings_provider.dart';
import 'package:online_story_reader/theme/theme_provider.dart';
import 'package:online_story_reader/theme/user_provider.dart';
import 'package:online_story_reader/widgets/chapter_image.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends ReadingSettingsProvider {
  @override
  TextStyle get bodyTextStyle => const TextStyle(fontSize: 18, height: 1.5);
}

class _Downloads extends Fake implements OfflineDownloadService {
  final Map<int, Completer<String?>> pending = {};
  bool hold = false;
  @override
  Future<String?> getDownloadedChapterContent(
    String pluginId,
    String title,
    int index, {
    String? storyUrl,
    String chapterUrl = '',
    String sourceType = 'novel',
  }) {
    if (hold) return (pending[index] ??= Completer<String?>()).future;
    return Future.value(content(index));
  }

  String content(int index) => OnlineChapterContent(
    blocks: [
      ChapterBlock.text('Nội dung chương $index'),
      const ChapterBlock.image('https://example.org/illustration.png'),
      const ChapterBlock.text('Sau minh họa'),
    ],
    isComic: false,
  ).encode();
}

class _ManagerDownloads extends OfflineDownloadService {
  DownloadStatus observed = DownloadStatus.idle;
  int reads = 0;
  @override
  DownloadStatus get status => observed;
  void finish() {
    observed = DownloadStatus.completed;
    notifyListeners();
  }

  _ManagerDownloads()
    : super.forTesting(
        directory: Directory('unused'),
        loadPages: (_, _) async => [],
        prepareSource: (_) async => true,
        loadImage: (_, {required referer}) async => Uint8List(0),
      );
  @override
  Future<String> get publicStoragePath async => '/Download/VBook';
  @override
  Future<List<Map<String, dynamic>>> getDownloadedStories() async {
    reads++;
    return [];
  }
}

final _plugin = PluginInfo(
  id: 'test',
  name: 'Nguồn có tên rất dài để kiểm tra giao diện',
  version: 1,
  author: '',
  description: '',
  iconUrl: '',
  downloadUrl: '',
  locale: 'vi',
  source: 'https://example.org',
  type: 'novel',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.vbook.reader/vbook_engine'),
      (call) async {
        if (call.method == 'getImageBytes') {
          return Uint8List.fromList(img.encodePng(img.Image(20, 30)));
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
      call,
    ) async {
      if (call.method == 'getLanguages') return ['vi-VN'];
      if (call.method == 'getEngines') return <String>[];
      if (call.method == 'getVoices') return <Map<String, String>>[];
      return 1;
    });
  });

  Widget app(Widget screen, double scale) => MultiProvider(
    providers: [
      ChangeNotifierProvider<ReadingSettingsProvider>(
        create: (_) => _Settings(),
      ),
      ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ChangeNotifierProvider(create: (_) => UserProvider()),
    ],
    child: MaterialApp(
      theme: ThemeProvider.darkTheme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: screen,
    ),
  );

  OnlineChapterReaderScreen reader(_Downloads downloads) =>
      OnlineChapterReaderScreen(
        plugin: _plugin,
        downloads: downloads,
        storyTitle: 'Tên tác phẩm',
        storyUrl: 'https://example.org/book',
        chapterUrl: 'https://example.org/chapter/0',
        chapterTitle: 'Chương đầu tiên với tên rất dài',
        allChapters: List.generate(
          19,
          (i) => ChapterNav(
            url: 'https://example.org/chapter/$i',
            name: 'Chương $i',
          ),
        ),
      );

  for (final width in [320.0, 360.0, 393.0, 412.0]) {
    for (final scale in [1.0, 1.45, 1.5]) {
      for (final landscape in [false, true]) {
        final size = landscape ? Size(800, width) : Size(width, 800);
        testWidgets('reader controls and images fit $size scale $scale', (
          tester,
        ) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(app(reader(_Downloads()), scale));
          await tester.pumpAndSettle();
          expect(find.byTooltip('Mục lục chương (Mở từ trái)').hitTestable(), findsOneWidget);
          expect(find.byTooltip('Nghe đọc TTS').hitTestable(), findsOneWidget);
          expect(find.byTooltip('Chương sau').hitTestable(), findsOneWidget);
          expect(find.byType(ChapterImage), findsOneWidget);
        });
      }
      testWidgets('download header fits $width scale $scale', (tester) async {
        final downloads = _ManagerDownloads();
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          app(DownloadManagerScreen(downloads: downloads), scale),
        );
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Truyện đã lưu ngoại tuyến'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
      testWidgets('profile shelf fits $width scale $scale', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(app(const ProfileScreen(), scale));
        await tester.pumpAndSettle();
        expect(find.text('Kệ sách của bạn'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('download list refreshes automatically after completion', (
    tester,
  ) async {
    final downloads = _ManagerDownloads();
    await tester.pumpWidget(
      app(DownloadManagerScreen(downloads: downloads), 1),
    );
    await tester.pumpAndSettle();
    final before = downloads.reads;
    downloads.finish();
    await tester.pumpAndSettle();
    expect(downloads.reads, before + 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('older chapter response cannot overwrite next chapter', (
    tester,
  ) async {
    final downloads = _Downloads()..hold = true;
    await tester.pumpWidget(app(reader(downloads), 1));
    await tester.pump();
    await tester.tap(find.byTooltip('Chương sau'));
    await tester.pump();
    downloads.pending[1]!.complete(downloads.content(1));
    await tester.pumpAndSettle();
    downloads.pending[0]!.complete(downloads.content(0));
    await tester.pumpAndSettle();
    expect(find.text('Nội dung chương 1'), findsOneWidget);
    expect(find.text('Nội dung chương 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
