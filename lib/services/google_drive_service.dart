import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/story.dart';
import 'package:uuid/uuid.dart';

class GoogleDriveService {
  // Thay thế YOUR_API_KEY bằng API Key thật của bạn
  static const String apiKey = 'AIzaSyDKJeyLnSj0DDYoe9z0j2Sh49C0trG_6Z4';

  static String? extractFolderId(String url) {
    // Ví dụ URL: https://drive.google.com/drive/folders/1JqHqueAhOcybtFQixX1PTypmq0MB7Mrx
    final uri = Uri.tryParse(url);
    if (uri != null && uri.pathSegments.contains('folders')) {
      final index = uri.pathSegments.indexOf('folders');
      if (index + 1 < uri.pathSegments.length) {
        return uri.pathSegments[index + 1];
      }
    }
    return null;
  }

  static Future<List<Story>> fetchStoriesFromFolder(String folderUrl) async {
    final folderId = extractFolderId(folderUrl);
    if (folderId == null) {
      throw Exception('URL thư mục không hợp lệ');
    }

    if (apiKey == 'YOUR_API_KEY') {
      throw Exception('Vui lòng cung cấp API Key trong file google_drive_service.dart');
    }

    final String apiUrl =
        'https://www.googleapis.com/drive/v3/files?q=\'$folderId\'+in+parents+and+trashed=false&fields=files(id,name,mimeType)&key=$apiKey';

    final response = await http.get(Uri.parse(apiUrl));

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final List<dynamic> items = data['files'];
      List<Story> stories = [];

      for (var item in items) {
        final name = item['name'] as String;
        final id = item['id'] as String;
        final mimeType = item['mimeType'] as String;
        
        if (mimeType == 'application/vnd.google-apps.folder') {
          // Nếu là thư mục, tên thư mục sẽ là tên truyện
          // Gọi API để tìm file epub/txt bên trong thư mục này
          final subApiUrl = 'https://www.googleapis.com/drive/v3/files?q=\'$id\'+in+parents+and+trashed=false&fields=files(id,name)&key=$apiKey';
          final subResponse = await http.get(Uri.parse(subApiUrl));
          if (subResponse.statusCode == 200) {
            final subData = json.decode(subResponse.body);
            final List<dynamic> subFiles = subData['files'];
            for (var subFile in subFiles) {
              final subName = subFile['name'] as String;
              if (subName.endsWith('.epub') || subName.endsWith('.pdf') || subName.endsWith('.txt')) {
                // Nếu lấy được file con, ta nối tên thư mục gốc với tên file (bỏ đuôi) để người dùng phân biệt nếu có nhiều vol
                final cleanSubName = subName.replaceAll(RegExp(r'\.(epub|pdf|txt)$', caseSensitive: false), '');
                final displayTitle = (subFiles.length > 1) ? '$name - $cleanSubName' : name;
                
                stories.add(
                  Story(
                    id: const Uuid().v4(),
                    title: displayTitle,
                    driveFileId: subFile['id'] as String,
                    isFromDrive: true,
                    isLocal: false,
                  ),
                );
                // Không dùng break nữa để lấy được tất cả các tập (vol) trong 1 bộ truyện
              }
            }
          }
        } else {
          // Chỉ lấy epub, pdf, txt nếu nằm trực tiếp
          if (name.endsWith('.epub') || name.endsWith('.pdf') || name.endsWith('.txt')) {
            // Xóa đuôi mở rộng để lấy tên
            final cleanName = name.replaceAll(RegExp(r'\.(epub|pdf|txt)$', caseSensitive: false), '');
            stories.add(
              Story(
                id: const Uuid().v4(),
                title: cleanName,
                driveFileId: id,
                isFromDrive: true,
                isLocal: false,
              ),
            );
          }
        }
      }
      return stories;
    } else {
      throw Exception('Lỗi khi tải thư mục: ${response.body}');
    }
  }

  static String getDownloadUrl(String fileId) {
    return 'https://www.googleapis.com/drive/v3/files/$fileId?alt=media&key=$apiKey';
  }

  static Future<Uint8List> downloadFileBytes(String fileId) async {
    final String apiUrl = getDownloadUrl(fileId);
    final response = await http.get(Uri.parse(apiUrl));

    if (response.statusCode == 200) {
      return response.bodyBytes;
    } else {
      throw Exception('Lỗi khi tải file từ Drive: ${response.body}');
    }
  }
}
