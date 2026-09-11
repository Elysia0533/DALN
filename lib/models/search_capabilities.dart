import 'package:flutter/foundation.dart';

@immutable
class SearchCapabilities {
  static const int currentVersion = 1;

  static const SearchCapabilities none = SearchCapabilities._(
    version: currentVersion,
    supportsKeyword: false,
    supportsAuthor: false,
    supportsGenre: false,
    supportsPagination: false,
    availableGenres: <String>[],
  );

  const SearchCapabilities._({
    required this.version,
    required this.supportsKeyword,
    required this.supportsAuthor,
    required this.supportsGenre,
    required this.supportsPagination,
    required this.availableGenres,
  });

  factory SearchCapabilities({
    int version = currentVersion,
    bool supportsKeyword = false,
    bool supportsAuthor = false,
    bool supportsGenre = false,
    bool supportsPagination = false,
    Iterable<String> availableGenres = const <String>[],
  }) {
    return SearchCapabilities._(
      version: version > 0 ? version : currentVersion,
      supportsKeyword: supportsKeyword,
      supportsAuthor: supportsAuthor,
      supportsGenre: supportsGenre,
      supportsPagination: supportsPagination,
      availableGenres: List<String>.unmodifiable(
        supportsGenre ? _normalizeGenres(availableGenres) : const <String>[],
      ),
    );
  }

  /// Legacy vBook manifests have no capability block. A configured search
  /// script is the only reliable evidence that keyword search is available.
  /// The legacy bridge always supplies a page number, so pagination remains
  /// enabled and the script's `next` value decides whether another page exists.
  factory SearchCapabilities.fromLegacyScripts(Map<String, String> scripts) {
    final hasSearchScript = _hasSearchScript(scripts);
    if (!hasSearchScript) return none;
    return SearchCapabilities(supportsKeyword: true, supportsPagination: true);
  }

  factory SearchCapabilities.fromPluginJson(
    Map<String, dynamic> json, {
    Map<String, String> scripts = const <String, String>{},
  }) {
    final declaration = _findDeclaration(json);
    return _fromDeclaration(declaration, scripts: scripts);
  }

  factory SearchCapabilities.fromStoredJson(
    Object? value, {
    Map<String, String> scripts = const <String, String>{},
  }) {
    return _fromDeclaration(_asStringMap(value), scripts: scripts);
  }

  final int version;
  final bool supportsKeyword;
  final bool supportsAuthor;
  final bool supportsGenre;
  final bool supportsPagination;
  final List<String> availableGenres;

  bool get supportsAnySearch =>
      supportsKeyword || supportsAuthor || supportsGenre;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': version,
    'supportsKeyword': supportsKeyword,
    'supportsAuthor': supportsAuthor,
    'supportsGenre': supportsGenre,
    'supportsPagination': supportsPagination,
    'availableGenres': availableGenres,
  };

  static SearchCapabilities _fromDeclaration(
    Map<String, dynamic>? declaration, {
    required Map<String, String> scripts,
  }) {
    final legacy = SearchCapabilities.fromLegacyScripts(scripts);
    if (declaration == null) return legacy;

    final hasSearchScript = _hasSearchScript(scripts);
    final supportsKeyword =
        hasSearchScript &&
        (_readBool(declaration['supportsKeyword']) ?? legacy.supportsKeyword);
    final supportsAuthor =
        hasSearchScript && (_readBool(declaration['supportsAuthor']) ?? false);
    final supportsGenre =
        hasSearchScript && (_readBool(declaration['supportsGenre']) ?? false);
    final supportsAnySearch =
        supportsKeyword || supportsAuthor || supportsGenre;
    final supportsPagination =
        hasSearchScript &&
        supportsAnySearch &&
        (_readBool(declaration['supportsPagination']) ??
            legacy.supportsPagination);

    final rawVersion = declaration['version'] ?? declaration['schemaVersion'];
    final parsedVersion = rawVersion is num
        ? rawVersion.toInt()
        : int.tryParse(rawVersion?.toString() ?? '');
    final rawGenres = declaration['availableGenres'];
    final genres = rawGenres is List
        ? rawGenres.whereType<String>()
        : const <String>[];

    return SearchCapabilities(
      version: parsedVersion ?? currentVersion,
      supportsKeyword: supportsKeyword,
      supportsAuthor: supportsAuthor,
      supportsGenre: supportsGenre,
      supportsPagination: supportsPagination,
      availableGenres: genres,
    );
  }

  static Map<String, dynamic>? _findDeclaration(Map<String, dynamic> json) {
    final direct = _asStringMap(json['searchCapabilities']);
    if (direct != null) return direct;

    final metadata = _asStringMap(json['metadata']);
    final metadataDeclaration = _asStringMap(metadata?['searchCapabilities']);
    if (metadataDeclaration != null) return metadataDeclaration;

    final capabilities = _asStringMap(json['capabilities']);
    return _asStringMap(capabilities?['search']);
  }

  static Map<String, dynamic>? _asStringMap(Object? value) {
    if (value is! Map) return null;
    return <String, dynamic>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }

  static bool _hasSearchScript(Map<String, String> scripts) {
    for (final entry in scripts.entries) {
      if (entry.key.trim().toLowerCase() == 'search' &&
          entry.value.trim().isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  static bool? _readBool(Object? value) => value is bool ? value : null;

  static List<String> _normalizeGenres(Iterable<String> values) {
    final genres = <String>[];
    final seen = <String>{};
    for (final value in values) {
      final genre = value.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (genre.isEmpty || !seen.add(genre.toLowerCase())) continue;
      genres.add(genre);
    }
    return genres;
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SearchCapabilities &&
            version == other.version &&
            supportsKeyword == other.supportsKeyword &&
            supportsAuthor == other.supportsAuthor &&
            supportsGenre == other.supportsGenre &&
            supportsPagination == other.supportsPagination &&
            listEquals(availableGenres, other.availableGenres);
  }

  @override
  int get hashCode => Object.hash(
    version,
    supportsKeyword,
    supportsAuthor,
    supportsGenre,
    supportsPagination,
    Object.hashAll(availableGenres),
  );
}
