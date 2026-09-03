import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/services/plugin/vbook_engine_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.vbook.reader/vbook_engine');
  late Future<dynamic> Function(MethodCall call) handler;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) => handler(call));
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('valid empty manga page remains a successful empty result', () async {
    handler = (call) async {
      expect(call.method, 'getPopularManga');
      expect(call.arguments, {'id': 'source.test', 'page': 1});
      return <String, dynamic>{'mangas': <dynamic>[], 'hasNextPage': false};
    };

    final result = await VBookEngineChannel.getPopularManga('source.test', 1);

    expect(result, isNotNull);
    expect(result!.mangas, isEmpty);
    expect(result.hasNextPage, isFalse);
  });

  test('execution timeout is propagated instead of returning null', () async {
    handler = (_) async {
      throw PlatformException(code: 'EXEC_TIMEOUT');
    };

    await expectLater(
      VBookEngineChannel.getPopularManga('source.test', 1),
      throwsA(
        isA<VBookEngineException>()
            .having((error) => error.code, 'code', 'EXEC_TIMEOUT')
            .having((error) => error.operation, 'operation', 'getPopularManga'),
      ),
    );
  });

  test(
    'parse failure is propagated instead of returning an empty list',
    () async {
      handler = (_) async {
        throw PlatformException(code: 'PARSE_ERROR');
      };

      await expectLater(
        VBookEngineChannel.getChapterList('source.test', '/story'),
        throwsA(
          isA<VBookEngineException>().having(
            (error) => error.code,
            'code',
            'PARSE_ERROR',
          ),
        ),
      );
    },
  );

  test('Promise result reports unsupported async explicitly', () async {
    handler = (_) async {
      throw PlatformException(code: 'ASYNC_UNSUPPORTED');
    };

    await expectLater(
      VBookEngineChannel.getPageList('source.test', '/chapter'),
      throwsA(
        isA<VBookEngineException>().having(
          (error) => error.code,
          'code',
          'ASYNC_UNSUPPORTED',
        ),
      ),
    );
  });

  test(
    'unexpected null native response is not treated as valid empty data',
    () async {
      handler = (_) async => null;

      await expectLater(
        VBookEngineChannel.getHomeTabs('source.test'),
        throwsA(
          isA<VBookEngineException>().having(
            (error) => error.code,
            'code',
            'INVALID_RESPONSE',
          ),
        ),
      );
    },
  );
}
