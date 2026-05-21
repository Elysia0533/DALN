import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:epub_view/epub_view.dart';
import 'package:image/image.dart' as img;
import '../models/story.dart';
import 'google_drive_service.dart';

class ApiService {
  static const String _localStoriesKey = 'local_imported_stories';
  static const String _serverStoriesKey = 'server_stories';

  static Future<Map<String, String>> extractEpubMetadata(String filePath) async {
    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      final document = await EpubDocument.openData(bytes);
      
      String title = document.Title ?? '';
      String coverPath = '';
      String description = '';
      // Note: epubx doesn't expose Description directly; keep empty for now
      
      if (document.CoverImage != null) {
        final directory = await getApplicationDocumentsDirectory();
        final coverFileName = 'cover_${const Uuid().v4()}.jpg';
        final coverFile = File('${directory.path}/$coverFileName');
        final jpgBytes = img.encodeJpg(document.CoverImage!);
        await coverFile.writeAsBytes(jpgBytes);
        coverPath = coverFile.path;
      }
      
      return {
        'title': title,
        'coverPath': coverPath,
        'description': description,
      };
    } catch (e) {
      debugPrint('Lỗi đọc epub metadata: $e');
      return {};
    }
  }

  // Lấy danh sách truyện trong Thư viện cá nhân
  static Future<List<Story>> fetchPersonalStories() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> localStoriesJson = prefs.getStringList(_localStoriesKey) ?? [];
    return localStoriesJson.map((s) => Story.fromJson(json.decode(s))).toList();
  }

  // Lấy danh sách truyện trên Server (giả lập bằng SharedPreferences)
  static Future<List<Story>> fetchServerStories() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> serverStoriesJson = prefs.getStringList(_serverStoriesKey) ?? [];
    
    if (serverStoriesJson.isEmpty) {
      try {
        // Tự động quét link mặc định ở lần đầu tiên
        List<Story> driveStories = await GoogleDriveService.fetchStoriesFromFolder(
          'https://drive.google.com/drive/folders/1-t-i30vQQYyP0sJ7ndTkW8gOrCchZ7f6?usp=drive_link'
        );
        await addServerStories(driveStories);
        return driveStories;
      } catch (e) {
        return []; // Nếu lỗi thì trả về rỗng
      }
    }

    return serverStoriesJson.map((s) => Story.fromJson(json.decode(s))).toList();
  }

  // Admin thêm truyện mới vào server
  static Future<void> addServerStories(List<Story> newStories) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> serverStoriesJson = prefs.getStringList(_serverStoriesKey) ?? [];
    List<Story> currentStories = serverStoriesJson.map((s) => Story.fromJson(json.decode(s))).toList();
    
    currentStories.addAll(newStories);
    List<String> updatedJson = currentStories.map((s) => json.encode(s.toJson())).toList();
    await prefs.setStringList(_serverStoriesKey, updatedJson);
  }

  static Future<void> importLocalStory(Story story) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> localStoriesJson = prefs.getStringList(_localStoriesKey) ?? [];
    
    // Kiểm tra xem đã tồn tại chưa (dựa theo id)
    bool exists = localStoriesJson.any((s) {
      final decoded = json.decode(s);
      return decoded['id'] == story.id;
    });

    if (!exists) {
      localStoriesJson.insert(0, json.encode(story.toJson()));
      await prefs.setStringList(_localStoriesKey, localStoriesJson);
    }
  }

  static Future<void> updateLocalStory(Story updatedStory) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String> localStoriesJson = prefs.getStringList(_localStoriesKey) ?? [];
    List<Story> localStories = localStoriesJson.map((s) => Story.fromJson(json.decode(s))).toList();
    
    int index = localStories.indexWhere((s) => s.id == updatedStory.id);
    if (index != -1) {
      localStories[index] = updatedStory;
      List<String> updatedJson = localStories.map((s) => json.encode(s.toJson())).toList();
      await prefs.setStringList(_localStoriesKey, updatedJson);
    }
  }

  static Future<void> saveChapterProgress(String storyId, int chapterIndex) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    
    // Lưu trong local
    List<String> localStoriesJson = prefs.getStringList(_localStoriesKey) ?? [];
    List<Story> localStories = localStoriesJson.map((s) => Story.fromJson(json.decode(s))).toList();
    int localIndex = localStories.indexWhere((s) => s.id == storyId);
    if (localIndex != -1) {
      localStories[localIndex] = localStories[localIndex].copyWith(savedChapterIndex: chapterIndex);
      List<String> updatedJson = localStories.map((s) => json.encode(s.toJson())).toList();
      await prefs.setStringList(_localStoriesKey, updatedJson);
    }

    // Lưu trong server (cho mục Khám phá)
    List<String> serverStoriesJson = prefs.getStringList(_serverStoriesKey) ?? [];
    List<Story> serverStories = serverStoriesJson.map((s) => Story.fromJson(json.decode(s))).toList();
    int serverIndex = serverStories.indexWhere((s) => s.id == storyId);
    if (serverIndex != -1) {
      serverStories[serverIndex] = serverStories[serverIndex].copyWith(savedChapterIndex: chapterIndex);
      List<String> updatedServerJson = serverStories.map((s) => json.encode(s.toJson())).toList();
      await prefs.setStringList(_serverStoriesKey, updatedServerJson);
    }
  }

  // Khởi tạo các file truyện từ assets/offline_stories/
  static Future<void> initOfflineStories() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      
      final offlineAssetPaths = manifest.listAssets()
          .where((String key) => key.startsWith('assets/offline_stories/'))
          .toList();

      if (offlineAssetPaths.isEmpty) return;

      final directory = await getApplicationDocumentsDirectory();
      SharedPreferences prefs = await SharedPreferences.getInstance();
      List<String> localStoriesJson = prefs.getStringList(_localStoriesKey) ?? [];

      for (String assetPath in offlineAssetPaths) {
        final fileName = assetPath.split('/').last;
        final localFile = File('${directory.path}/$fileName');
        
        // Tạo title đẹp hơn bằng cách bỏ đuôi file (ví dụ: ThanhXuan_Vol1.epub -> ThanhXuan_Vol1)
        final displayTitle = fileName.replaceAll(RegExp(r'\.(epub|pdf|txt)$', caseSensitive: false), '');

        // Kiểm tra xem truyện này đã được thêm vào trước đó chưa (tránh copy lại)
        bool exists = localStoriesJson.any((s) {
          final decoded = json.decode(s);
          return decoded['title'] == displayTitle && decoded['isLocal'] == true;
        });

        if (!exists) {
          // Copy từ asset ra bộ nhớ trong
          final byteData = await rootBundle.load(assetPath);
          await localFile.writeAsBytes(byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));

          String extractedTitle = displayTitle;
          String coverPath = '';
          String description = '';
          if (fileName.toLowerCase().endsWith('.epub')) {
            final metadata = await extractEpubMetadata(localFile.path);
            if (metadata['title'] != null && metadata['title']!.isNotEmpty) {
              extractedTitle = metadata['title']!;
            }
            if (metadata['coverPath'] != null) {
              coverPath = metadata['coverPath']!;
            }
            if (metadata['description'] != null) {
              description = metadata['description']!;
            }
          }

          Story newStory = Story(
            id: const Uuid().v4(),
            title: extractedTitle,
            description: description,
            localPath: localFile.path,
            isLocal: true,
            iconUrl: coverPath,
          );

          if (fileName.endsWith('.txt')) {
            newStory = Story(
              id: newStory.id,
              title: displayTitle,
              content: await localFile.readAsString(),
              localPath: localFile.path,
              isLocal: true,
            );
          }

          // Trực tiếp thêm vào list hiện tại để vòng lặp sau nhận biết
          localStoriesJson.insert(0, json.encode(newStory.toJson()));
        }
      }
      
      // Lưu lại toàn bộ danh sách cập nhật
      await prefs.setStringList(_localStoriesKey, localStoriesJson);
    } catch (e) {
      debugPrint('Lỗi khởi tạo offline stories: $e');
    }
  }
}
