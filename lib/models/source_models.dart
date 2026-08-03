class SManga {
  static const int UNKNOWN = 0;
  static const int ONGOING = 1;
  static const int COMPLETED = 2;

  String url = '';
  String title = '';
  String artist = '';
  String author = '';
  String description = '';
  String genre = '';
  int status = UNKNOWN;
  String thumbnailUrl = '';
  bool initialized = false;

  static SManga create() => SManga();
}

class SChapter {
  String url = '';
  String name = '';
  int dateUpload = 0;
  int chapterNumber = -1;
  String scanlator = '';
}

class MangasPage {
  final List<SManga> mangas;
  final bool hasNextPage;

  MangasPage(this.mangas, this.hasNextPage);
}

class Page {
  final int index;
  final String url;
  final String imageUrl;

  Page(this.index, this.url, this.imageUrl);
}

class PluginConfig {
  final String name;
  final String language;
  final String locale;
  final String author;
  final int version;
  final String type; // comic, novel
  final PluginScript script;

  PluginConfig({
    required this.name,
    required this.language,
    required this.locale,
    required this.author,
    required this.version,
    required this.type,
    required this.script,
  });

  factory PluginConfig.fromJson(Map<String, dynamic> json) {
    var meta = json['metadata'] ?? {};
    var s = json['script'] ?? {};
    return PluginConfig(
      name: meta['name']?.toString() ?? '',
      language: meta['language']?.toString() ?? '',
      locale: meta['locale']?.toString() ?? '',
      author: meta['author']?.toString() ?? '',
      version: (meta['version'] as num?)?.toInt() ?? 1,
      type: meta['type']?.toString() ?? 'comic',
      script: PluginScript.fromJson(s),
    );
  }
}

class PluginScript {
  final String? home;
  final String? detail;
  final String? toc;
  final String? chap;
  final String? search;
  final String? genre;

  PluginScript({
    this.home,
    this.detail,
    this.toc,
    this.chap,
    this.search,
    this.genre,
  });

  factory PluginScript.fromJson(Map<String, dynamic> json) {
    return PluginScript(
      home: json['home']?.toString(),
      detail: json['detail']?.toString(),
      toc: json['toc']?.toString(),
      chap: json['chap']?.toString(),
      search: json['search']?.toString(),
      genre: json['genre']?.toString(),
    );
  }
}
