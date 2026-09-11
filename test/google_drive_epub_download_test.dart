import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:online_story_reader/services/google_drive_service.dart';

import 'support/epub_metadata_fixture.dart';

void main() {
  const limit = GoogleDriveService.epubMetadataMaxBytes;
  test(
    'EPUB download requests the whole file with restriction headers and no redirects',
    () async {
      final bytes = epubMetadataFixture();
      final client = _Client((request) async {
        expect(request.headers.containsKey('Range'), isFalse);
        expect(request.headers['X-Android-Package'], 'com.example.test');
        expect(request.followRedirects, isFalse);
        expect(request.url.host, 'www.googleapis.com');
        expect(request.url.queryParameters['alt'], 'media');
        return http.StreamedResponse(
          Stream.value(bytes),
          200,
          contentLength: bytes.length,
        );
      });
      final result =
          await GoogleDriveService.downloadEpubMetadataFileForTesting(
            fileId: 'file',
            client: client,
            restrictionHeaders: {'X-Android-Package': 'com.example.test'},
          );
      expect(result, bytes);
      expect(client.closed, isTrue);
    },
  );

  test(
    'known oversized response is refused before reading the stream',
    () async {
      var read = false;
      final controller = StreamController<List<int>>(
        onListen: () {
          read = true;
        },
      );
      final client = _Client(
        (_) async => http.StreamedResponse(
          controller.stream,
          200,
          contentLength: limit + 1,
        ),
      );
      await expectLater(
        GoogleDriveService.downloadEpubMetadataFileForTesting(
          fileId: 'file',
          client: client,
        ),
        throwsFormatException,
      );
      expect(read, isFalse);
      expect(client.closed, isTrue);
      unawaited(controller.close());
    },
  );

  test('unknown-length response cannot exceed the full-file cap', () async {
    var cancelled = false;
    late StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        controller.add(Uint8List(limit));
        controller.add([1]);
      },
      onCancel: () {
        cancelled = true;
      },
    );
    final client = _Client(
      (_) async => http.StreamedResponse(controller.stream, 200),
    );
    await expectLater(
      GoogleDriveService.downloadEpubMetadataFileForTesting(
        fileId: 'file',
        client: client,
      ),
      throwsFormatException,
    );
    expect(cancelled, isTrue);
    expect(client.closed, isTrue);
    await controller.close();
  });

  test(
    'exactly the full-file cap is accepted only after end of stream',
    () async {
      final client = _Client(
        (_) async => http.StreamedResponse(
          Stream.value(Uint8List(limit)),
          200,
          contentLength: limit,
        ),
      );
      expect(
        await GoogleDriveService.downloadEpubMetadataFileForTesting(
          fileId: 'file',
          client: client,
        ),
        hasLength(limit),
      );
      expect(client.closed, isTrue);
    },
  );

  for (final status in [206, 302, 403, 500]) {
    test(
      'EPUB HTTP $status is not treated as a complete ZIP download',
      () async {
        final client = _Client(
          (_) async => http.StreamedResponse(Stream.value([65]), status),
        );
        await expectLater(
          GoogleDriveService.downloadEpubMetadataFileForTesting(
            fileId: 'file',
            client: client,
          ),
          throwsFormatException,
        );
        expect(client.closed, isTrue);
      },
    );
  }

  test('truncated body and disguised HTML are refused', () async {
    for (final response in [
      http.StreamedResponse(Stream.value([65]), 200, contentLength: 2),
      http.StreamedResponse(
        Stream.value(utf8.encode('<!DOCTYPE html><html>Login</html>')),
        200,
      ),
    ]) {
      final client = _Client((_) async => response);
      await expectLater(
        GoogleDriveService.downloadEpubMetadataFileForTesting(
          fileId: 'file',
          client: client,
        ),
        throwsFormatException,
      );
      expect(client.closed, isTrue);
    }
  });

  test('timed-out download releases its stream and client', () async {
    var cancelled = false;
    final stream = StreamController<List<int>>(
      onCancel: () {
        cancelled = true;
      },
    );
    final client = _Client(
      (_) async => http.StreamedResponse(stream.stream, 200),
    );
    await expectLater(
      GoogleDriveService.downloadEpubMetadataFileForTesting(
        fileId: 'file',
        client: client,
        timeout: const Duration(milliseconds: 20),
      ),
      throwsFormatException,
    );
    expect(cancelled, isTrue);
    expect(client.closed, isTrue);
    await stream.close();
  });
}

class _Client extends http.BaseClient {
  _Client(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
  @override
  void close() {
    closed = true;
  }
}
