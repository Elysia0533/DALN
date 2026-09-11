import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/models/plugin_info.dart';
import 'package:online_story_reader/models/search_capabilities.dart';
import 'package:online_story_reader/models/source_models.dart';
import 'package:online_story_reader/services/plugin/vbook_engine_channel.dart';
import 'package:online_story_reader/services/search/extension_search_runner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final plugin = PluginInfo(
    id: 'source.test',
    name: 'Source',
    author: '',
    source: 'https://example.invalid',
    iconUrl: '',
    description: '',
    type: 'novel',
    locale: 'vi',
    version: 1,
    downloadUrl: '',
    scripts: const {'search': 'search.js'},
    searchCapabilities: SearchCapabilities(
      supportsKeyword: true,
      supportsPagination: true,
    ),
  );
  MangasPage empty() => MangasPage([], false);

  test('no more than two actual extension requests run concurrently', () async {
    final active = <Completer<MangasPage>>[];
    var peak = 0;
    var running = 0;
    final runner = ExtensionSearchRunner(
      execute: (_, _, _) async {
        running++;
        if (running > peak) peak = running;
        final completer = Completer<MangasPage>();
        active.add(completer);
        try {
          return await completer.future;
        } finally {
          running--;
        }
      },
    );
    final futures = [
      for (var i = 0; i < 5; i++)
        runner.search(plugin, 'book', 1, isCurrent: () => true),
    ];
    expect(active, hasLength(2));
    for (var i = 0; i < 5; i++) {
      active[i].complete(empty());
      await Future<void>.delayed(Duration.zero);
    }
    await Future.wait(futures);
    expect(peak, 2);
    expect(running, 0);
  });

  test(
    'timeouts retain native permits and expired queued searches never start',
    () async {
      final active = <Completer<MangasPage>>[];
      final runner = ExtensionSearchRunner(
        timeout: const Duration(milliseconds: 30),
        execute: (_, _, _) {
          final completer = Completer<MangasPage>();
          active.add(completer);
          return completer.future;
        },
      );
      final checks = [
        for (var i = 0; i < 3; i++)
          expectLater(
            runner.search(plugin, 'old', 1, isCurrent: () => true),
            throwsA(isA<TimeoutException>()),
          ),
      ];
      await Future.wait(checks);
      expect(active, hasLength(2));
      final next = runner.search(plugin, 'new', 1, isCurrent: () => true);
      expect(active, hasLength(2));
      active[0].complete(empty());
      active[1].complete(empty());
      await Future<void>.delayed(Duration.zero);
      expect(active, hasLength(3));
      active.last.complete(empty());
      await next;
    },
  );

  test('stale queued query is cancelled without starting an engine', () async {
    final active = <Completer<MangasPage>>[];
    final runner = ExtensionSearchRunner(
      execute: (_, _, _) {
        final completer = Completer<MangasPage>();
        active.add(completer);
        return completer.future;
      },
    );
    final first = runner.search(plugin, 'first', 1, isCurrent: () => true);
    final second = runner.search(plugin, 'second', 1, isCurrent: () => true);
    var current = true;
    final third = expectLater(
      runner.search(plugin, 'stale', 1, isCurrent: () => current),
      throwsA(
        isA<VBookEngineException>().having(
          (e) => e.code,
          'code',
          'EXEC_CANCELLED',
        ),
      ),
    );
    current = false;
    active[0].complete(empty());
    active[1].complete(empty());
    await Future.wait([first, second, third]);
    expect(active, hasLength(2));
  });

  const channel = MethodChannel('com.vbook.reader/vbook_engine');
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  for (final fail in [false, true]) {
    test(
      'isolated session is closed and preserves reader source id (failure=$fail)',
      () async {
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              if (call.method == 'getSearchManga') {
                if (fail) {
                  throw PlatformException(
                    code: 'NETWORK_ERROR',
                    message: 'Unavailable',
                  );
                }
                return {
                  'mangas': [
                    {'url': '/book', 'title': 'Book'},
                  ],
                  'hasNextPage': false,
                };
              }
              return true;
            });
        final runner = ExtensionSearchRunner(
          resolveDirectory: (id) async {
            expect(id, plugin.id);
            return '/test/source';
          },
        );
        final result = runner.search(plugin, 'book', 1, isCurrent: () => true);
        if (fail) {
          await expectLater(result, throwsA(isA<VBookEngineException>()));
        } else {
          expect((await result).mangas.single.title, 'Book');
        }
        expect(calls.map((c) => c.method), [
          'loadSource',
          'getSearchManga',
          'closeSource',
        ]);
        final ids = calls.map((c) => (c.arguments as Map)['id']).toSet();
        expect(ids, hasLength(1));
        expect(ids.single, isNot(plugin.id));
        expect(plugin.id, 'source.test');
      },
    );
  }
}
