import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:online_story_reader/services/google_drive_service.dart';

void main() {
  const limit = GoogleDriveService.textMetadataPrefixBytes;

  test(
    'range request preserves Android restriction headers and disables redirects',
    () async {
      final client = _Client((request) async {
        expect(request.url.host, 'www.googleapis.com');
        expect(request.url.queryParameters['alt'], 'media');
        expect(request.headers['Range'], 'bytes=0-524287');
        expect(request.headers['Accept-Encoding'], 'identity');
        expect(request.headers['X-Android-Package'], 'com.example.test');
        expect(request.followRedirects, isFalse);
        return http.StreamedResponse(
          Stream.value(utf8.encode('Title: Book')),
          206,
          headers: {'content-range': 'bytes 0-10/1000'},
        );
      });
      expect(
        utf8.decode(
          await GoogleDriveService.downloadTextMetadataPrefixForTesting(
            fileId: 'test-file',
            client: client,
            restrictionHeaders: {'X-Android-Package': 'com.example.test'},
          ),
        ),
        'Title: Book',
      );
      expect(client.closed, isTrue);
    },
  );

  test(
    'ignored Range stops consuming a large full response at 512 KiB',
    () async {
      var cancelled = false;
      late StreamController<List<int>> stream;
      stream = StreamController<List<int>>(
        onListen: () => stream.add(List.filled(limit + 31, 65)),
        onCancel: () {
          cancelled = true;
        },
      );
      final client = _Client(
        (_) async => http.StreamedResponse(
          stream.stream,
          200,
          contentLength: limit * 100,
        ),
      );
      final result =
          await GoogleDriveService.downloadTextMetadataPrefixForTesting(
            fileId: 'file',
            client: client,
          );
      expect(result, hasLength(limit));
      expect(cancelled, isTrue);
      expect(client.closed, isTrue);
      await stream.close();
    },
  );

  test('small complete 200 response without Range remains usable', () async {
    final client = _Client(
      (_) async =>
          http.StreamedResponse(Stream.value([65, 66]), 200, contentLength: 2),
    );
    expect(
      await GoogleDriveService.downloadTextMetadataPrefixForTesting(
        fileId: 'file',
        client: client,
      ),
      [65, 66],
    );
  });

  for (final range in [
    null,
    'bytes 1-2/30',
    'bytes 0-524288/600000',
    'bytes 0-2/2',
    'garbage',
  ]) {
    test('rejects invalid Content-Range $range', () async {
      final client = _Client(
        (_) async => http.StreamedResponse(
          Stream.value([65, 66, 67]),
          206,
          headers: {'content-range': ?range},
        ),
      );
      await expectLater(
        GoogleDriveService.downloadTextMetadataPrefixForTesting(
          fileId: 'file',
          client: client,
        ),
        throwsFormatException,
      );
      expect(client.closed, isTrue);
    });
  }

  for (final size in [2, 4]) {
    test('rejects a partial body whose length is $size instead of 3', () async {
      final client = _Client(
        (_) async => http.StreamedResponse(
          Stream.value(List.filled(size, 65)),
          206,
          headers: {'content-range': 'bytes 0-2/100'},
        ),
      );
      await expectLater(
        GoogleDriveService.downloadTextMetadataPrefixForTesting(
          fileId: 'file',
          client: client,
        ),
        throwsFormatException,
      );
    });
  }

  for (final code in [302, 403, 416, 500]) {
    test(
      'HTTP $code closes client without reading error body or retrying elsewhere',
      () async {
        var listened = false;
        final stream = StreamController<List<int>>(
          onListen: () {
            listened = true;
          },
        );
        final client = _Client(
          (_) async => http.StreamedResponse(stream.stream, code),
        );
        await expectLater(
          GoogleDriveService.downloadTextMetadataPrefixForTesting(
            fileId: 'file',
            client: client,
          ),
          throwsFormatException,
        );
        expect(listened, isFalse);
        expect(client.closed, isTrue);
        unawaited(stream.close());
      },
    );
  }

  test('HTML is rejected even when labeled as a plain text response', () async {
    final client = _Client(
      (_) async => http.StreamedResponse(
        Stream.value(utf8.encode('<!DOCTYPE html><html>Login</html>')),
        200,
      ),
    );
    await expectLater(
      GoogleDriveService.downloadTextMetadataPrefixForTesting(
        fileId: 'file',
        client: client,
      ),
      throwsFormatException,
    );
  });

  test('body timeout cancels the stream and closes the client', () async {
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
      GoogleDriveService.downloadTextMetadataPrefixForTesting(
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

  test('transport details never escape in the thrown error', () async {
    final client = _Client(
      (_) async => throw http.ClientException('sensitive-request-detail'),
    );
    await expectLater(
      GoogleDriveService.downloadTextMetadataPrefixForTesting(
        fileId: 'file',
        client: client,
      ),
      throwsA(
        predicate(
          (error) =>
              error is FormatException &&
              !error.toString().contains('sensitive-request-detail'),
        ),
      ),
    );
    expect(client.closed, isTrue);
  });

  test('invalid file identity fails before any request', () async {
    var calls = 0;
    final client = _Client((_) async {
      calls++;
      throw StateError('Unexpected request');
    });
    await expectLater(
      GoogleDriveService.downloadTextMetadataPrefixForTesting(
        fileId: '../file',
        client: client,
      ),
      throwsFormatException,
    );
    expect(calls, 0);
    expect(client.closed, isTrue);
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
