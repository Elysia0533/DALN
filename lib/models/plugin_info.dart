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

  factory PluginInfo.fromRegistryJson(
    Map<String, dynamic> json, {
    String? registryUrl,
  }) {
    final rawMetadata = json['metadata'];
    final metadata = rawMetadata is Map
        ? Map<String, dynamic>.from(rawMetadata)
        : const <String, dynamic>{};

    dynamic readValue(String key) => json[key] ?? metadata[key];
    String readString(String key) => readValue(key)?.toString() ?? '';

    // Trích xuất ID: ưu tiên id trong json, nếu không trích xuất từ path hoặc name
    String id = readString('id');
    final path =
        json['path']?.toString() ?? json['downloadUrl']?.toString() ?? '';

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
      final name = readString('name');
      id = name.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    }

    if (id.isEmpty) {
      id = 'plugin_${DateTime.now().millisecondsSinceEpoch}';
    }

    String resolvedDownloadUrl = path;
    String resolvedIconUrl =
        json['icon']?.toString() ??
        json['iconUrl']?.toString() ??
        metadata['icon']?.toString() ??
        metadata['iconUrl']?.toString() ??
        '';

    if (registryUrl != null && registryUrl.isNotEmpty) {
      try {
        final baseUri = Uri.parse(registryUrl);
        if (resolvedDownloadUrl.isNotEmpty &&
            !resolvedDownloadUrl.startsWith('http')) {
          resolvedDownloadUrl = baseUri.resolve(resolvedDownloadUrl).toString();
        }
        if (resolvedIconUrl.isNotEmpty && !resolvedIconUrl.startsWith('http')) {
          resolvedIconUrl = baseUri.resolve(resolvedIconUrl).toString();
        }
      } catch (_) {}
    }

    final rawScripts = json['scripts'] ?? json['script'];
    final scripts = <String, String>{};
    if (rawScripts is Map) {
      for (final entry in rawScripts.entries) {
        if (entry.value != null) {
          scripts[entry.key.toString()] = entry.value.toString();
        }
      }
    }

    final rawVersion = readValue('version');
    final version = rawVersion is num
        ? rawVersion.toInt()
        : int.tryParse(rawVersion?.toString() ?? '') ?? 1;
    final tag = readString('tag').toLowerCase();

    return PluginInfo(
      id: id,
      name: readString('name').isEmpty ? id : readString('name'),
      author: readString('author').isEmpty ? 'vBook' : readString('author'),
      source: readString('source'),
      iconUrl: resolvedIconUrl,
      description: readString('description'),
      type: readString('type').isEmpty ? 'novel' : readString('type'),
      locale: readString('locale'),
      version: version,
      isNsfw: tag == 'nsfw' || readValue('isNsfw') == true,
      downloadUrl: resolvedDownloadUrl,
      scripts: scripts,
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
