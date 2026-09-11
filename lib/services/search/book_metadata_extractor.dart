import '../google_drive_service.dart';

typedef BookMetadataLoader = Future<BookMetadata> Function(String fileId);

class BookMetadata {
  const BookMetadata({
    this.title,
    this.authors = const [],
    this.genres = const [],
    this.description = '',
  });

  final String? title;
  final List<String> authors;
  final List<String> genres;
  final String description;
}

class BookMetadataExtraction {
  static final _limiter = RequestConcurrencyLimiter(maxConcurrency: 2);

  static Future<T> run<T>(Future<T> Function() extract) =>
      _limiter.run(extract);
}
