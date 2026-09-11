import 'dart:convert';

import 'plugin_info.dart';
import 'search_capabilities.dart';
import 'story.dart';

enum SearchSourceType { drive, local, extension }

class SearchSource {
  const SearchSource({
    required this.type,
    required this.id,
    required this.name,
    required this.capabilities,
    this.plugin,
  });

  final SearchSourceType type;
  final String id;
  final String name;
  final SearchCapabilities capabilities;
  final PluginInfo? plugin;

  String get key => jsonEncode([type.name, id]);
}

class UnifiedSearchQuery {
  const UnifiedSearchQuery({this.text = '', this.author, this.genre});

  final String text;
  final String? author;
  final String? genre;
  bool get isEmpty => text.trim().isEmpty && author == null && genre == null;
}

class SearchResult {
  SearchResult({
    required this.source,
    required this.remoteId,
    required this.story,
  });

  final SearchSource source;
  final String remoteId;
  final Story story;

  String get stableId => jsonEncode([source.type.name, source.id, remoteId]);
  String get title => story.title;
  String get author => story.author;
  List<String> get genres => story.genres;
  String get cover => story.iconUrl;
  String get description => story.description;
}

class SourceSearchPage {
  SourceSearchPage({required Iterable<SearchResult> items, this.nextPage})
    : items = List.unmodifiable(items);

  final List<SearchResult> items;
  final int? nextPage;
}

class SearchFacets {
  SearchFacets({
    Iterable<String> authors = const [],
    Iterable<String> genres = const [],
  }) : authors = List.unmodifiable(authors),
       genres = List.unmodifiable(genres);

  final List<String> authors;
  final List<String> genres;
}

enum SourceSearchStatus { idle, loading, ready, error, unsupported }

class SourceSearchState {
  SourceSearchState({
    required this.source,
    this.status = SourceSearchStatus.idle,
    Iterable<SearchResult> items = const [],
    this.nextPage,
    this.failedPage,
    this.message,
  }) : items = List.unmodifiable(items);

  final SearchSource source;
  final SourceSearchStatus status;
  final List<SearchResult> items;
  final int? nextPage;
  final int? failedPage;
  final String? message;
}
