import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/services/tts_service.dart';
import 'package:online_story_reader/widgets/tts_player_container.dart';

const _flutterTtsChannel = MethodChannel('flutter_tts');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_flutterTtsChannel, (call) async {
          switch (call.method) {
            case 'getLanguages':
              return ['vi-VN', 'en-US'];
            case 'getEngines':
              return ['mock_tts_engine'];
            case 'getDefaultEngine':
              return 'mock_tts_engine';
            case 'getVoices':
              return <Map<String, String>>[];
            default:
              return 1;
          }
        });
  });

  tearDown(() async {
    await TtsService.instance.stop();
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_flutterTtsChannel, null);
  });

  for (final width in [320.0, 360.0, 393.0, 412.0]) {
    for (final textScale in [1.0, 1.3, 1.5]) {
      testWidgets(
        'TTS player fits ${width.toInt()}px portrait at text scale $textScale',
        (tester) async {
          await _pumpVisiblePlayer(
            tester,
            size: Size(width, 720),
            textScale: textScale,
          );

          expect(tester.takeException(), isNull);
          _expectPrimaryControlsVisible();
        },
      );

      testWidgets(
        'TTS player fits ${width.toInt()}px landscape at text scale $textScale',
        (tester) async {
          await _pumpVisiblePlayer(
            tester,
            size: Size(720, width),
            textScale: textScale,
          );

          expect(tester.takeException(), isNull);
          _expectPrimaryControlsVisible();
        },
      );
    }
  }

  testWidgets('TTS player controls remain tappable', (tester) async {
    var previousChapterTaps = 0;
    var nextChapterTaps = 0;
    var settingsTaps = 0;

    await _pumpVisiblePlayer(
      tester,
      size: const Size(320, 720),
      textScale: 1.5,
      onPreviousChapter: () => previousChapterTaps++,
      onNextChapter: () => nextChapterTaps++,
      onOpenSettings: () => settingsTaps++,
    );

    await tester.tap(find.byKey(const ValueKey('tts_previous_chapter')));
    await tester.pump();
    expect(previousChapterTaps, 1);

    await tester.tap(find.byKey(const ValueKey('tts_previous_paragraph')));
    await tester.pump();
    expect(TtsService.instance.currentParagraphIndex, 0);

    await tester.tap(find.byKey(const ValueKey('tts_next_paragraph')));
    await tester.pump();
    expect(TtsService.instance.currentParagraphIndex, 1);

    await tester.tap(find.byKey(const ValueKey('tts_play_pause')));
    await tester.pump();
    expect(TtsService.instance.isPaused, isTrue);

    await tester.tap(find.byKey(const ValueKey('tts_play_pause')));
    await tester.pump();
    expect(TtsService.instance.isPlaying, isTrue);

    await tester.tap(find.byKey(const ValueKey('tts_next_chapter')));
    await tester.pump();
    expect(nextChapterTaps, 1);

    await tester.tap(find.byKey(const ValueKey('tts_sleep_timer')));
    await tester.pumpAndSettle();
    expect(find.text('Hẹn giờ tắt TTS'), findsOneWidget);
    await tester.tap(find.text('Không hẹn giờ'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('tts_settings')));
    await tester.pump();
    expect(settingsTaps, 1);

    await tester.tap(find.byKey(const ValueKey('tts_close')));
    await tester.pump();
    expect(TtsService.instance.isStopped, isTrue);
  });
}

Future<void> _pumpVisiblePlayer(
  WidgetTester tester, {
  required Size size,
  required double textScale,
  VoidCallback? onPreviousChapter,
  VoidCallback? onNextChapter,
  VoidCallback? onOpenSettings,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  await TtsService.instance.speak(
    'First paragraph.\n\nSecond paragraph.\n\nThird paragraph.',
    chapterIndex: 0,
    startParagraphIndex: 1,
  );

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        );
      },
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: TtsPlayerContainer(
            textColor: Colors.black,
            onPreviousChapter: onPreviousChapter,
            onNextChapter: onNextChapter,
            onOpenSettings: onOpenSettings,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void _expectPrimaryControlsVisible() {
  expect(find.byKey(const ValueKey('tts_previous_chapter')), findsOneWidget);
  expect(find.byKey(const ValueKey('tts_previous_paragraph')), findsOneWidget);
  expect(find.byKey(const ValueKey('tts_play_pause')), findsOneWidget);
  expect(find.byKey(const ValueKey('tts_next_paragraph')), findsOneWidget);
  expect(find.byKey(const ValueKey('tts_next_chapter')), findsOneWidget);
  expect(find.byKey(const ValueKey('tts_sleep_timer')), findsOneWidget);
  expect(find.byKey(const ValueKey('tts_settings')), findsOneWidget);
  expect(find.byKey(const ValueKey('tts_close')), findsOneWidget);
}
