/// Chương truyện online
class OnlineChapter {
  final String name;
  final String url;
  final String host;

  const OnlineChapter({
    required this.name,
    required this.url,
    this.host = '',
  });

  factory OnlineChapter.fromJson(Map<String, dynamic> json) => OnlineChapter(
    name: json['name'] ?? '',
    url: json['url'] ?? json['link'] ?? '',
    host: json['host'] ?? '',
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'host': host,
  };
}

/// Nội dung chương truyện chữ
class NovelContent {
  final String title;
  final String htmlContent;
  final String plainText;

  const NovelContent({
    required this.title,
    required this.htmlContent,
    required this.plainText,
  });
}

/// Nội dung chương truyện tranh
class ComicContent {
  final String title;
  final List<ComicPage> pages;

  const ComicContent({
    required this.title,
    required this.pages,
  });
}

/// Một trang ảnh truyện tranh
class ComicPage {
  final String link;
  final List<String> fallback;

  const ComicPage({
    required this.link,
    this.fallback = const [],
  });

  factory ComicPage.fromJson(Map<String, dynamic> json) => ComicPage(
    link: json['link'] ?? json['src'] ?? '',
    fallback: (json['fallback'] as List<dynamic>?)
        ?.map((e) => e.toString())
        .toList() ?? [],
  );
}

/// Thông tin chi tiết truyện từ nguồn online
class OnlineStoryDetail {
  final String name;
  final String cover;
  final String author;
  final String description;
  final bool ongoing;
  final List<String> genres;
  final String host;

  const OnlineStoryDetail({
    required this.name,
    this.cover = '',
    this.author = '',
    this.description = '',
    this.ongoing = true,
    this.genres = const [],
    this.host = '',
  });
}

/// Danh mục trang chủ nguồn
class SourceCategory {
  final String title;
  final String input;
  final String script;

  const SourceCategory({
    required this.title,
    required this.input,
    required this.script,
  });

  factory SourceCategory.fromJson(Map<String, dynamic> json) => SourceCategory(
    title: json['title'] ?? '',
    input: json['input'] ?? '',
    script: json['script'] ?? 'gen.js',
  );
}

/// Kết quả tìm kiếm/duyệt
class SourceStoryItem {
  final String name;
  final String link;
  final String cover;
  final String description;
  final String host;

  const SourceStoryItem({
    required this.name,
    required this.link,
    this.cover = '',
    this.description = '',
    this.host = '',
  });

  factory SourceStoryItem.fromJson(Map<String, dynamic> json) => SourceStoryItem(
    name: json['name'] ?? '',
    link: json['link'] ?? '',
    cover: json['cover'] ?? '',
    description: json['description'] ?? '',
    host: json['host'] ?? '',
  );
}
