class Story {
  final String id;
  final String title;
  final String titleEng;
  final String content;
  final String contentEng;
  final String description; // Mô tả / giới thiệu truyện (từ EPUB metadata)
  final int totalChapters;
  final int currentChapter;
  final int savedChapterIndex; // Chỉ mục chương đang đọc dở (0-based)
  final String iconUrl;
  final String localPath;
  final bool isLocal;
  final String driveFileId;
  final bool isFromDrive;

  Story({
    required this.id,
    required this.title,
    this.content = "",
    this.titleEng = "",
    this.contentEng = "",
    this.description = "",
    this.totalChapters = 1,
    this.currentChapter = 1,
    this.savedChapterIndex = 0,
    this.iconUrl = "",
    this.localPath = "",
    this.isLocal = false,
    this.driveFileId = "",
    this.isFromDrive = false,
  });

  factory Story.fromJson(Map<String, dynamic> json) {
    return Story(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      content: json['content'] ?? '',
      titleEng: json['titleEng'] ?? '',
      contentEng: json['contentEng'] ?? '',
      description: json['description'] ?? '',
      totalChapters: json['totalChapters'] ?? 1,
      currentChapter: json['currentChapter'] ?? 1,
      savedChapterIndex: json['savedChapterIndex'] ?? 0,
      iconUrl: json['iconUrl'] ?? '',
      localPath: json['localPath'] ?? '',
      isLocal: json['isLocal'] ?? false,
      driveFileId: json['driveFileId'] ?? '',
      isFromDrive: json['isFromDrive'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'titleEng': titleEng,
      'contentEng': contentEng,
      'description': description,
      'totalChapters': totalChapters,
      'currentChapter': currentChapter,
      'savedChapterIndex': savedChapterIndex,
      'iconUrl': iconUrl,
      'localPath': localPath,
      'isLocal': isLocal,
      'driveFileId': driveFileId,
      'isFromDrive': isFromDrive,
    };
  }

  Story copyWith({
    String? id,
    String? title,
    String? titleEng,
    String? content,
    String? contentEng,
    String? description,
    int? totalChapters,
    int? currentChapter,
    int? savedChapterIndex,
    String? iconUrl,
    String? localPath,
    bool? isLocal,
    String? driveFileId,
    bool? isFromDrive,
  }) {
    return Story(
      id: id ?? this.id,
      title: title ?? this.title,
      titleEng: titleEng ?? this.titleEng,
      content: content ?? this.content,
      contentEng: contentEng ?? this.contentEng,
      description: description ?? this.description,
      totalChapters: totalChapters ?? this.totalChapters,
      currentChapter: currentChapter ?? this.currentChapter,
      savedChapterIndex: savedChapterIndex ?? this.savedChapterIndex,
      iconUrl: iconUrl ?? this.iconUrl,
      localPath: localPath ?? this.localPath,
      isLocal: isLocal ?? this.isLocal,
      driveFileId: driveFileId ?? this.driveFileId,
      isFromDrive: isFromDrive ?? this.isFromDrive,
    );
  }
}
