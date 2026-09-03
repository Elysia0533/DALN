import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:online_story_reader/models/story.dart';
import 'package:online_story_reader/screens/explore_screen.dart';
import 'package:online_story_reader/services/admin_claim_reader.dart';
import 'package:online_story_reader/services/google_drive_service.dart';
import 'package:online_story_reader/theme/user_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('rapid refresh calls share one in-flight Drive request', (
    tester,
  ) async {
    final harness = _DriveLoaderHarness();
    await tester.pumpWidget(_testApp(harness));
    await tester.pump();

    expect(harness.calls, hasLength(1));
    expect(harness.calls.single.pageSize, 15);
    harness.complete(
      0,
      _page([_story('initial', 'Initial story')], hasMore: false),
    );
    await _flush(tester);

    final appBarRefresh = find.widgetWithIcon(IconButton, Icons.refresh);
    final refreshButton = tester.widget<IconButton>(appBarRefresh);
    refreshButton.onPressed!();
    refreshButton.onPressed!();
    refreshButton.onPressed!();
    await tester.pump();

    expect(harness.calls, hasLength(2));
    expect(tester.widget<IconButton>(appBarRefresh).onPressed, isNull);
    harness.complete(
      1,
      _page([_story('refreshed', 'Refreshed story')], hasMore: false),
    );
    await _flush(tester);

    expect(find.text('Refreshed story'), findsOneWidget);
    expect(find.text('Initial story'), findsNothing);
    expect(find.text('Đã làm mới danh sách truyện!'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh discards an in-flight load-more response', (
    tester,
  ) async {
    final harness = _DriveLoaderHarness();
    await tester.pumpWidget(_testApp(harness));
    await tester.pump();

    harness.complete(
      0,
      _page(
        List.generate(
          24,
          (index) => _story('initial-$index', 'Initial $index'),
        ),
        nextPageToken: 'next-page',
        hasMore: true,
      ),
    );
    await _flush(tester);

    for (var attempt = 0; attempt < 5 && harness.calls.length < 2; attempt++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
      await tester.pump();
    }

    expect(harness.calls, hasLength(2));
    expect(harness.calls[1].pageSize, 15);
    expect(harness.calls[1].pageToken, 'next-page');

    await tester.tap(find.byTooltip('Làm mới Drive').first);
    await tester.pump();
    expect(harness.calls, hasLength(3));
    expect(harness.calls[2].pageToken, isNull);

    harness.complete(
      2,
      _page([_story('refreshed', 'Refreshed story')], hasMore: false),
    );
    await _flush(tester);
    harness.complete(
      1,
      _page([_story('stale-more', 'Stale next page')], hasMore: false),
    );
    await _flush(tester);

    expect(find.text('Refreshed story'), findsOneWidget);
    expect(find.text('Stale next page'), findsNothing);
    expect(find.text('Initial 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Widget _testApp(_DriveLoaderHarness harness) {
  return ChangeNotifierProvider(
    create: (_) => UserProvider(adminClaimReader: _SignedOutClaimReader()),
    child: MaterialApp(
      home: ExploreScreen(
        drivePageLoader: harness.load,
        installedPluginsLoader: () async => const [],
      ),
    ),
  );
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

DrivePage<Story> _page(
  List<Story> stories, {
  String? nextPageToken,
  required bool hasMore,
}) {
  return DrivePage(
    items: stories,
    nextPageToken: nextPageToken,
    hasMore: hasMore,
  );
}

Story _story(String id, String title) {
  return Story(
    id: id,
    title: title,
    driveFileId: id,
    isFromDrive: true,
    fileType: 'pdf',
  );
}

class _DriveLoaderHarness {
  final calls = <_DriveCall>[];

  Future<DrivePage<Story>> load({required int pageSize, String? pageToken}) {
    final call = _DriveCall(pageSize: pageSize, pageToken: pageToken);
    calls.add(call);
    return call.completer.future;
  }

  void complete(int index, DrivePage<Story> page) {
    calls[index].completer.complete(page);
  }
}

class _DriveCall {
  final int pageSize;
  final String? pageToken;
  final Completer<DrivePage<Story>> completer = Completer<DrivePage<Story>>();

  _DriveCall({required this.pageSize, required this.pageToken});
}

class _SignedOutClaimReader implements AdminClaimReader {
  @override
  String? get currentUserId => null;

  @override
  Stream<String?> get userIdChanges => const Stream<String?>.empty();

  @override
  Future<Map<String, dynamic>?> readClaims({required bool forceRefresh}) async {
    return null;
  }
}
