import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

class ParsedMangaChapter {
  final String title;
  final String folderPath;
  final List<File> imageFiles;

  ParsedMangaChapter({
    required this.title,
    required this.folderPath,
    required this.imageFiles,
  });
}

class ParsedMangaInfo {
  final String rootPath;
  final String title;
  final String author;
  final String description;
  final String coverPath;
  final List<ParsedMangaChapter> chapters;

  ParsedMangaInfo({
    required this.rootPath,
    required this.title,
    required this.author,
    required this.description,
    required this.coverPath,
    required this.chapters,
  });
}

class LocalMangaParser {
  static const imageExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif'};

  static int naturalCompare(String a, String b) {
    final reg = RegExp(r'(\d+)|(\D+)');
    final matchesA = reg.allMatches(a).toList();
    final matchesB = reg.allMatches(b).toList();

    for (int i = 0; i < matchesA.length && i < matchesB.length; i++) {
      final tokenA = matchesA[i].group(0)!;
      final tokenB = matchesB[i].group(0)!;

      final numA = int.tryParse(tokenA);
      final numB = int.tryParse(tokenB);

      if (numA != null && numB != null) {
        final cmp = numA.compareTo(numB);
        if (cmp != 0) return cmp;
      } else {
        final cmp = tokenA.toLowerCase().compareTo(tokenB.toLowerCase());
        if (cmp != 0) return cmp;
      }
    }
    return matchesA.length.compareTo(matchesB.length);
  }

  /// Quét tất cả các file ảnh trong một thư mục
  static List<File> scanImagesInDirectory(Directory dir) {
    if (!dir.existsSync()) return [];
    final files = <File>[];
    try {
      for (final entity in dir.listSync()) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (imageExtensions.contains(ext)) {
            files.add(entity);
          }
        }
      }
    } catch (_) {}
    files.sort((a, b) => naturalCompare(p.basename(a.path), p.basename(b.path)));
    return files;
  }

  /// Tìm tất cả các thư mục con có chứa ảnh (hỗ trợ cả thư mục lồng nhau cấp 1 và cấp 2)
  static List<Directory> findImageDirectories(Directory rootDir) {
    final result = <Directory>[];
    if (!rootDir.existsSync()) return result;

    try {
      for (final entity in rootDir.listSync()) {
        if (entity is Directory) {
          final directImages = scanImagesInDirectory(entity);
          if (directImages.isNotEmpty) {
            result.add(entity);
          } else {
            // Kiểm tra thêm 1 cấp lồng nhau (ví dụ: root/images/chap1, root/chapters/01)
            try {
              for (final sub in entity.listSync()) {
                if (sub is Directory) {
                  final subImages = scanImagesInDirectory(sub);
                  if (subImages.isNotEmpty) {
                    result.add(sub);
                  }
                }
              }
            } catch (_) {}
          }
        }
      }
    } catch (_) {}

    result.sort((a, b) => naturalCompare(p.basename(a.path), p.basename(b.path)));
    return result;
  }

  /// Phân tích một bộ truyện tranh từ thư mục gốc hoặc file chapter.json
  static Future<ParsedMangaInfo?> parse({
    String? directoryPath,
    String? chapterJsonFilePath,
  }) async {
    Directory rootDir;
    File? jsonFile;

    if (chapterJsonFilePath != null && chapterJsonFilePath.isNotEmpty) {
      jsonFile = File(chapterJsonFilePath);
      if (!await jsonFile.exists()) return null;
      rootDir = jsonFile.parent;
    } else if (directoryPath != null && directoryPath.isNotEmpty) {
      rootDir = Directory(directoryPath);
      if (!await rootDir.exists()) return null;

      // Tìm file chapter.json / chapters.json / story_info.json trong thư mục gốc
      final candidateNames = [
        'chapter.json',
        'chapters.json',
        'story_info.json',
        'info.json',
        'index.json',
        'metadata.json',
      ];
      for (final name in candidateNames) {
        final f = File(p.join(rootDir.path, name));
        if (await f.exists()) {
          jsonFile = f;
          break;
        }
      }
    } else {
      return null;
    }

    String storyTitle = p.basename(rootDir.path);
    String author = 'Cục bộ';
    String description = '';
    String coverPath = '';
    final parsedChapters = <ParsedMangaChapter>[];

    // Tìm ảnh bìa sẵn có trong thư mục gốc (cover.jpg, folder.jpg, ...)
    final coverNames = ['cover', 'folder', 'poster', 'thumb', 'thumbnail', 'avatar'];
    try {
      for (final entity in rootDir.listSync()) {
        if (entity is File) {
          final base = p.basenameWithoutExtension(entity.path).toLowerCase();
          final ext = p.extension(entity.path).toLowerCase();
          if (coverNames.contains(base) && imageExtensions.contains(ext)) {
            coverPath = entity.path;
            break;
          }
        }
      }
    } catch (_) {}

    // 1. Nếu có file JSON mô tả chapters
    if (jsonFile != null && await jsonFile.exists()) {
      try {
        final rawContent = await jsonFile.readAsString();
        final dynamic decoded = jsonDecode(rawContent);

        List<dynamic>? rawChapterList;
        if (decoded is List) {
          rawChapterList = decoded;
        } else if (decoded is Map<String, dynamic>) {
          if (decoded['storyTitle'] is String && (decoded['storyTitle'] as String).trim().isNotEmpty) {
            storyTitle = (decoded['storyTitle'] as String).trim();
          } else if (decoded['title'] is String && (decoded['title'] as String).trim().isNotEmpty) {
            storyTitle = (decoded['title'] as String).trim();
          } else if (decoded['name'] is String && (decoded['name'] as String).trim().isNotEmpty) {
            storyTitle = (decoded['name'] as String).trim();
          }

          if (decoded['author'] is String) {
            author = decoded['author'] as String;
          }
          if (decoded['description'] is String) {
            description = decoded['description'] as String;
          }

          final chaptersField = decoded['chapters'] ?? decoded['chapterList'] ?? decoded['data'] ?? decoded['items'];
          if (chaptersField is List) {
            rawChapterList = chaptersField;
          }
        }

        final imageDirs = findImageDirectories(rootDir);

        if (rawChapterList != null && rawChapterList.isNotEmpty) {
          for (int i = 0; i < rawChapterList.length; i++) {
            final item = rawChapterList[i];
            String chapTitle = 'Chương ${i + 1}';
            String chapFolder = '';
            List<String> explicitImages = [];

            if (item is Map) {
              chapTitle = (item['title'] ?? item['name'] ?? item['chapterTitle'] ?? item['chapter_name'] ?? 'Chương ${i + 1}').toString().trim();
              chapFolder = (item['folder'] ?? item['path'] ?? item['dir'] ?? '').toString().trim();
              if (item['images'] is List) {
                explicitImages = (item['images'] as List).map((e) => e.toString()).toList();
              }
            } else if (item is String) {
              chapTitle = item.trim();
            }

            List<File> chapterImages = [];

            // Cách A: Tìm theo đường dẫn folder chỉ định trong json
            if (chapFolder.isNotEmpty) {
              final candidateDir = Directory(p.isAbsolute(chapFolder) ? chapFolder : p.join(rootDir.path, chapFolder));
              if (candidateDir.existsSync()) {
                chapterImages = scanImagesInDirectory(candidateDir);
              }
            }

            // Cách B: Danh sách ảnh rõ ràng
            if (chapterImages.isEmpty && explicitImages.isNotEmpty) {
              for (final imgName in explicitImages) {
                final imgFile = File(p.isAbsolute(imgName) ? imgName : p.join(rootDir.path, imgName));
                if (imgFile.existsSync()) {
                  chapterImages.add(imgFile);
                }
              }
            }

            // Cách C: Ghép với danh sách thư mục ảnh theo thứ tự index
            if (chapterImages.isEmpty && i < imageDirs.length) {
              chapterImages = scanImagesInDirectory(imageDirs[i]);
              chapFolder = p.relative(imageDirs[i].path, from: rootDir.path);
            }

            // Cách D: Ghép theo tên thư mục khớp tên chương
            if (chapterImages.isEmpty) {
              for (final d in imageDirs) {
                final base = p.basename(d.path).toLowerCase();
                if (base == chapTitle.toLowerCase() || base.contains(chapTitle.toLowerCase())) {
                  chapterImages = scanImagesInDirectory(d);
                  chapFolder = p.relative(d.path, from: rootDir.path);
                  break;
                }
              }
            }

            if (chapterImages.isNotEmpty) {
              parsedChapters.add(
                ParsedMangaChapter(
                  title: chapTitle,
                  folderPath: chapFolder.isNotEmpty ? p.join(rootDir.path, chapFolder) : (chapterImages.isNotEmpty ? chapterImages.first.parent.path : rootDir.path),
                  imageFiles: chapterImages,
                ),
              );
            }
          }
        }
      } catch (_) {
        // Lỗi đọc json -> Tiếp tục fallback quét thư mục ảnh thông thường
      }
    }

    // 2. Fallback: Nếu không có chapter.json hoặc không trích xuất được chương nào
    if (parsedChapters.isEmpty) {
      final imageDirs = findImageDirectories(rootDir);
      for (final dir in imageDirs) {
        final imgs = scanImagesInDirectory(dir);
        if (imgs.isNotEmpty) {
          // Kiểm tra xem bên trong thư mục con này có chapter.json riêng không
          String title = p.basename(dir.path);
          final subJson = File(p.join(dir.path, 'chapter.json'));
          if (subJson.existsSync()) {
            try {
              final subDecoded = jsonDecode(subJson.readAsStringSync());
              if (subDecoded is Map) {
                final name = subDecoded['title'] ?? subDecoded['name'] ?? subDecoded['chapterTitle'];
                if (name != null && name.toString().trim().isNotEmpty) {
                  title = name.toString().trim();
                }
              }
            } catch (_) {}
          }

          parsedChapters.add(
            ParsedMangaChapter(
              title: title,
              folderPath: dir.path,
              imageFiles: imgs,
            ),
          );
        }
      }

      // Nếu thư mục gốc phẳng chứa ảnh trực tiếp
      if (parsedChapters.isEmpty) {
        final directImages = scanImagesInDirectory(rootDir);
        if (directImages.isNotEmpty) {
          parsedChapters.add(
            ParsedMangaChapter(
              title: storyTitle,
              folderPath: rootDir.path,
              imageFiles: directImages,
            ),
          );
        }
      }
    }

    if (parsedChapters.isEmpty) {
      return null;
    }

    // Nếu chưa có ảnh bìa, lấy ảnh đầu tiên của chương đầu tiên
    if (coverPath.isEmpty && parsedChapters.isNotEmpty && parsedChapters.first.imageFiles.isNotEmpty) {
      coverPath = parsedChapters.first.imageFiles.first.path;
    }

    if (description.isEmpty) {
      description = 'Truyện tranh offline (${parsedChapters.length} chương)';
    }

    return ParsedMangaInfo(
      rootPath: rootDir.path,
      title: storyTitle,
      author: author,
      description: description,
      coverPath: coverPath,
      chapters: parsedChapters,
    );
  }
}
