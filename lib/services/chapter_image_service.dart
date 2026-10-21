import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'google_drive_service.dart';

class ChapterImageService {
  static const maxBytes = 16 * 1024 * 1024;
  static final _limiter = RequestConcurrencyLimiter(maxConcurrency: 2);
  static final http.Client _client = http.Client();

  static Future<Uint8List> load(
    String source, {
    required String referer,
  }) => _limiter.run(() async {
    try {
      Uint8List? bytes;
      if (source.startsWith('data:image/')) {
        if (source.length > maxBytes * 4 ~/ 3 + 1024) {
          throw const FormatException();
        }
        final data = UriData.parse(source);
        bytes = data.contentAsBytes();
      } else if (source.startsWith('vbook-base64://')) {
        if (source.length > maxBytes * 4 ~/ 3 + 1024) {
          throw const FormatException();
        }
        bytes = base64Decode(source.substring('vbook-base64://'.length));
      } else {
        final uri = Uri.tryParse(source);
        if (uri == null ||
            !['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          throw const FormatException();
        }
        final request = http.Request('GET', uri);
        request.headers['Referer'] = referer;
        request.headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
        final response = await _client.send(request);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          bytes = await response.stream.toBytes();
        }
      }
      if (bytes == null || bytes.length > maxBytes) {
        throw const FormatException();
      }
      extensionFor(bytes);
      return bytes;
    } catch (_) {
      throw const FormatException(
        'Không tải được ảnh minh họa. Hãy thử lại hoặc mở nguồn trong trình duyệt.',
      );
    }
  });

  static String extensionFor(List<int> bytes) {
    bool starts(List<int> signature) =>
        bytes.length >= signature.length &&
        List.generate(
          signature.length,
          (i) => bytes[i] == signature[i],
        ).every((v) => v);
    if (starts([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return 'png';
    if (starts([0xff, 0xd8, 0xff])) return 'jpg';
    if (starts([0x47, 0x49, 0x46, 0x38])) return 'gif';
    if (starts([0x52, 0x49, 0x46, 0x46]) &&
        bytes.length >= 12 &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'webp';
    }
    if (starts([0x42, 0x4d])) return 'bmp';
    throw const FormatException('Unsupported chapter image format.');
  }
}
