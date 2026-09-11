import 'search_index_story.dart';

class SearchIndexPage {
  SearchIndexPage({
    required Iterable<SearchIndexStory> items,
    required this.limit,
    required this.offset,
    required this.hasMore,
  }) : items = List.unmodifiable(items);

  final List<SearchIndexStory> items;
  final int limit;
  final int offset;
  final bool hasMore;

  int? get nextOffset => hasMore ? offset + items.length : null;
}
