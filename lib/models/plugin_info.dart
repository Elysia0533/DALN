import 'search_capabilities.dart';

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
  final SearchCapabilities searchCapabilities;

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
    Map<String, String> scripts = const {},
    SearchCapabilities? searchCapabilities,
    this.isInstalled = false,
    this.installedVersion = 0,
  }) : scripts = Map<String, String>.unmodifiable(scripts),
       searchCapabilities =
           searchCapabilities ?? SearchCapabilities.fromLegacyScripts(scripts);

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
    final scripts = _readScripts(rawScripts);

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
      searchCapabilities: SearchCapabilities.fromPluginJson(
        json,
        scripts: scripts,
      ),
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
    'searchCapabilities': searchCapabilities.toJson(),
    'isInstalled': isInstalled,
    'installedVersion': installedVersion,
  };

  factory PluginInfo.fromJson(Map<String, dynamic> json) {
    final scripts = _readScripts(json['scripts']);
    return PluginInfo(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      author: json['author']?.toString() ?? '',
      source: json['source']?.toString() ?? '',
      iconUrl: json['iconUrl']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      type: json['type']?.toString() ?? 'novel',
      locale: json['locale']?.toString() ?? '',
      version: _readInt(json['version'], fallback: 1),
      isNsfw: json['isNsfw'] is bool ? json['isNsfw'] as bool : false,
      downloadUrl: json['downloadUrl']?.toString() ?? '',
      scripts: scripts,
      searchCapabilities: SearchCapabilities.fromStoredJson(
        json['searchCapabilities'],
        scripts: scripts,
      ),
      isInstalled: json['isInstalled'] is bool
          ? json['isInstalled'] as bool
          : false,
      installedVersion: _readInt(json['installedVersion']),
    );
  }

  PluginInfo copyWith({
    String? id,
    String? name,
    String? author,
    String? source,
    String? iconUrl,
    String? description,
    String? type,
    String? locale,
    int? version,
    bool? isNsfw,
    String? downloadUrl,
    Map<String, String>? scripts,
    SearchCapabilities? searchCapabilities,
    bool? isInstalled,
    int? installedVersion,
  }) {
    return PluginInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      author: author ?? this.author,
      source: source ?? this.source,
      iconUrl: iconUrl ?? this.iconUrl,
      description: description ?? this.description,
      type: type ?? this.type,
      locale: locale ?? this.locale,
      version: version ?? this.version,
      isNsfw: isNsfw ?? this.isNsfw,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      scripts: scripts ?? this.scripts,
      searchCapabilities: searchCapabilities ?? this.searchCapabilities,
      isInstalled: isInstalled ?? this.isInstalled,
      installedVersion: installedVersion ?? this.installedVersion,
    );
  }

  static Map<String, String> _readScripts(Object? rawScripts) {
    final scripts = <String, String>{};
    if (rawScripts is! Map) return scripts;
    for (final entry in rawScripts.entries) {
      if (entry.value != null) {
        scripts[entry.key.toString()] = entry.value.toString();
      }
    }
    return scripts;
  }

  static int _readInt(Object? value, {int fallback = 0}) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }
}
