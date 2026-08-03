/// Thông tin về một extension/plugin nguồn truyện
class PluginInfo {
  final String id;
  final String name;
  final String author;
  final String source;
  final String iconUrl;
  final String description;
  final String type; // 'novel' | 'comic'
  final String locale;
  final int version;
  final bool isNsfw;
  final String downloadUrl;
  final Map<String, String> scripts;

  bool isInstalled;
  int installedVersion;

  PluginInfo({
    required this.id,
    required this.name,
    required this.author,
    required this.source,
    required this.iconUrl,
    required this.description,
    required this.type,
    required this.locale,
    required this.version,
    required this.downloadUrl,
    this.isNsfw = false,
    this.scripts = const {},
    this.isInstalled = false,
    this.installedVersion = 0,
  });

  bool get isNovel => type == 'novel';
  bool get isComic => type == 'comic';
  bool get hasUpdate => isInstalled && installedVersion < version;

  factory PluginInfo.fromRegistryJson(Map<String, dynamic> json, {String? registryUrl}) {
    // Trích xuất ID: ưu tiên id trong json, nếu không trích xuất từ path hoặc name
    String id = json['id']?.toString() ?? json['metadata']?['id']?.toString() ?? '';
    final path = json['path'] as String? ?? json['downloadUrl'] as String? ?? '';

    if (id.isEmpty && path.isNotEmpty) {
      final pathParts = path.split('/');
      for (int i = pathParts.length - 1; i >= 0; i--) {
        final decoded = Uri.decodeComponent(pathParts[i]);
        if (decoded == 'plugin.zip' && i > 0) {
          id = Uri.decodeComponent(pathParts[i - 1]);
          break;
        }
      }
      if (id.isEmpty && pathParts.length >= 2) {
        id = Uri.decodeComponent(pathParts[pathParts.length - 2]);
      }
    }

    if (id.isEmpty) {
      final name = json['name']?.toString() ?? '';
      id = name.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    }

    if (id.isEmpty) {
      id = 'plugin_${DateTime.now().millisecondsSinceEpoch}';
    }

    String resolvedDownloadUrl = path;
    String resolvedIconUrl = json['icon'] as String? ?? json['iconUrl'] as String? ?? '';

    if (registryUrl != null && registryUrl.isNotEmpty) {
      try {
        final baseUri = Uri.parse(registryUrl);
        if (resolvedDownloadUrl.isNotEmpty && !resolvedDownloadUrl.startsWith('http')) {
          resolvedDownloadUrl = baseUri.resolve(resolvedDownloadUrl).toString();
        }
        if (resolvedIconUrl.isNotEmpty && !resolvedIconUrl.startsWith('http')) {
          resolvedIconUrl = baseUri.resolve(resolvedIconUrl).toString();
        }
      } catch (_) {}
    }

    return PluginInfo(
      id: id,
      name: json['name'] ?? id,
      author: json['author'] ?? 'vBook',
      source: json['source'] ?? '',
      iconUrl: resolvedIconUrl,
      description: json['description'] ?? '',
      type: json['type'] ?? 'novel',
      locale: json['locale'] ?? '',
      version: json['version'] ?? 1,
      isNsfw: json['tag'] == 'nsfw' || json['isNsfw'] == true,
      downloadUrl: resolvedDownloadUrl,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'author': author,
    'source': source,
    'iconUrl': iconUrl,
    'description': description,
    'type': type,
    'locale': locale,
    'version': version,
    'isNsfw': isNsfw,
    'downloadUrl': downloadUrl,
    'scripts': scripts,
    'isInstalled': isInstalled,
    'installedVersion': installedVersion,
  };

  factory PluginInfo.fromJson(Map<String, dynamic> json) => PluginInfo(
    id: json['id'] ?? '',
    name: json['name'] ?? '',
    author: json['author'] ?? '',
    source: json['source'] ?? '',
    iconUrl: json['iconUrl'] ?? '',
    description: json['description'] ?? '',
    type: json['type'] ?? 'novel',
    locale: json['locale'] ?? '',
    version: json['version'] ?? 1,
    isNsfw: json['isNsfw'] ?? false,
    downloadUrl: json['downloadUrl'] ?? '',
    scripts: Map<String, String>.from(json['scripts'] ?? {}),
    isInstalled: json['isInstalled'] ?? false,
    installedVersion: json['installedVersion'] ?? 0,
  );
}
