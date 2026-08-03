import 'dart:convert';

/// Tiến độ đọc — lưu chính xác vị trí đang đọc
class ReadingProgress {
  final String storyId;
  final int chapterIndex;
  final double scrollOffset;
  final double scrollPercentage; // 0.0 - 1.0
  final String lastVisibleText;  // Đoạn text đầu tiên hiện trên màn hình
  final int totalChapters;
  final DateTime updatedAt;

  ReadingProgress({
    required this.storyId,
    this.chapterIndex = 0,
    this.scrollOffset = 0.0,
    this.scrollPercentage = 0.0,
    this.lastVisibleText = '',
    this.totalChapters = 1,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'storyId': storyId,
    'chapterIndex': chapterIndex,
    'scrollOffset': scrollOffset,
    'scrollPercentage': scrollPercentage,
    'lastVisibleText': lastVisibleText,
    'totalChapters': totalChapters,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory ReadingProgress.fromJson(Map<String, dynamic> json) {
    return ReadingProgress(
      storyId: json['storyId'] ?? '',
      chapterIndex: json['chapterIndex'] ?? 0,
      scrollOffset: (json['scrollOffset'] ?? 0.0).toDouble(),
      scrollPercentage: (json['scrollPercentage'] ?? 0.0).toDouble(),
      lastVisibleText: json['lastVisibleText'] ?? '',
      totalChapters: json['totalChapters'] ?? 1,
      updatedAt: json['updatedAt'] != null
          ? DateTime.tryParse(json['updatedAt']) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  String encode() => json.encode(toJson());

  factory ReadingProgress.decode(String encoded) {
    return ReadingProgress.fromJson(json.decode(encoded));
  }
}

/// Bookmark — đánh dấu vị trí quan trọng trong truyện
class Bookmark {
  final String id;
  final String storyId;
  final String storyTitle;
  final int chapterIndex;
  final int paragraphIndex;
  final String chapterTitle;
  final double scrollOffset;
  final double scrollPercentage;
  final String selectedText;  // Đoạn text người dùng chọn
  final String note;          // Ghi chú tùy chọn
  final DateTime createdAt;
  final int colorValue;       // Màu highlight (argb int)

  Bookmark({
    required this.id,
    required this.storyId,
    this.storyTitle = '',
    this.chapterIndex = 0,
    this.paragraphIndex = 0,
    this.chapterTitle = '',
    this.scrollOffset = 0.0,
    this.scrollPercentage = 0.0,
    this.selectedText = '',
    this.note = '',
    DateTime? createdAt,
    this.colorValue = 0xFFFFC107, // Amber mặc định
  }) : createdAt = createdAt ?? DateTime.now();

  Bookmark copyWith({
    String? note,
    int? colorValue,
    int? paragraphIndex,
  }) => Bookmark(
    id: id,
    storyId: storyId,
    storyTitle: storyTitle,
    chapterIndex: chapterIndex,
    paragraphIndex: paragraphIndex ?? this.paragraphIndex,
    chapterTitle: chapterTitle,
    scrollOffset: scrollOffset,
    scrollPercentage: scrollPercentage,
    selectedText: selectedText,
    note: note ?? this.note,
    createdAt: createdAt,
    colorValue: colorValue ?? this.colorValue,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'storyId': storyId,
    'storyTitle': storyTitle,
    'chapterIndex': chapterIndex,
    'paragraphIndex': paragraphIndex,
    'chapterTitle': chapterTitle,
    'scrollOffset': scrollOffset,
    'scrollPercentage': scrollPercentage,
    'selectedText': selectedText,
    'note': note,
    'createdAt': createdAt.toIso8601String(),
    'colorValue': colorValue,
  };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
    id: json['id'] ?? '',
    storyId: json['storyId'] ?? '',
    storyTitle: json['storyTitle'] ?? '',
    chapterIndex: json['chapterIndex'] ?? 0,
    paragraphIndex: json['paragraphIndex'] ?? 0,
    chapterTitle: json['chapterTitle'] ?? '',
    scrollOffset: (json['scrollOffset'] ?? 0.0).toDouble(),
    scrollPercentage: (json['scrollPercentage'] ?? 0.0).toDouble(),
    selectedText: json['selectedText'] ?? json['snippet'] ?? '',
    note: json['note'] ?? '',
    createdAt: json['createdAt'] != null
        ? DateTime.tryParse(json['createdAt']) ?? DateTime.now()
        : DateTime.now(),
    colorValue: json['colorValue'] ?? 0xFFFFC107,
  );
}
