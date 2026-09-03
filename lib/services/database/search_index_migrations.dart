import 'package:sqflite/sqflite.dart';

abstract final class SearchIndexSchema {
  static const int version = 1;

  static Future<void> migrate(
    DatabaseExecutor database,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 0 || oldVersion > newVersion || newVersion > version) {
      throw StateError(
        'Unsupported search index migration: $oldVersion -> $newVersion',
      );
    }

    for (
      var targetVersion = oldVersion + 1;
      targetVersion <= newVersion;
      targetVersion++
    ) {
      switch (targetVersion) {
        case 1:
          await _migrateToVersion1(database);
      }
    }
  }

  static Future<void> _migrateToVersion1(DatabaseExecutor database) async {
    final batch = database.batch();

    batch.execute('''
      CREATE TABLE index_runs (
        run_id TEXT PRIMARY KEY,
        source_type TEXT NOT NULL CHECK(length(trim(source_type)) > 0),
        source_id TEXT NOT NULL CHECK(length(trim(source_id)) > 0),
        status TEXT NOT NULL CHECK(status IN ('indexing', 'ready', 'partial', 'error')),
        indexed_count INTEGER NOT NULL DEFAULT 0 CHECK(indexed_count >= 0),
        total_count INTEGER CHECK(total_count IS NULL OR total_count >= 0),
        started_at INTEGER NOT NULL CHECK(started_at >= 0),
        completed_at INTEGER,
        last_error TEXT
      )
    ''');

    batch.execute('''
      CREATE TABLE stories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_type TEXT NOT NULL CHECK(length(trim(source_type)) > 0),
        source_id TEXT NOT NULL CHECK(length(trim(source_id)) > 0),
        remote_id TEXT NOT NULL CHECK(length(trim(remote_id)) > 0),
        drive_file_id TEXT CHECK(drive_file_id IS NULL OR length(trim(drive_file_id)) > 0),
        title TEXT NOT NULL CHECK(length(trim(title)) > 0),
        normalized_title TEXT NOT NULL CHECK(length(trim(normalized_title)) > 0),
        mime_type TEXT NOT NULL DEFAULT '',
        modified_time INTEGER,
        file_size INTEGER CHECK(file_size IS NULL OR file_size >= 0),
        checksum TEXT,
        description TEXT NOT NULL DEFAULT '',
        cover_file_id TEXT,
        cover_url TEXT,
        cover_local_path TEXT,
        metadata_status TEXT NOT NULL CHECK(
          metadata_status IN ('pending', 'partial', 'complete', 'missing', 'error')
        ),
        last_seen_run_id TEXT,
        last_indexed_at INTEGER NOT NULL CHECK(last_indexed_at >= 0),
        UNIQUE(source_type, source_id, remote_id),
        FOREIGN KEY(last_seen_run_id) REFERENCES index_runs(run_id) ON DELETE SET NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE authors (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL CHECK(length(trim(name)) > 0),
        normalized_name TEXT NOT NULL UNIQUE CHECK(length(trim(normalized_name)) > 0)
      )
    ''');

    batch.execute('''
      CREATE TABLE genres (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL CHECK(length(trim(name)) > 0),
        normalized_name TEXT NOT NULL UNIQUE CHECK(length(trim(normalized_name)) > 0)
      )
    ''');

    batch.execute('''
      CREATE TABLE story_authors (
        story_id INTEGER NOT NULL,
        author_id INTEGER NOT NULL,
        position INTEGER NOT NULL CHECK(position >= 0),
        PRIMARY KEY(story_id, author_id),
        UNIQUE(story_id, position),
        FOREIGN KEY(story_id) REFERENCES stories(id) ON DELETE CASCADE,
        FOREIGN KEY(author_id) REFERENCES authors(id) ON DELETE CASCADE
      )
    ''');

    batch.execute('''
      CREATE TABLE story_genres (
        story_id INTEGER NOT NULL,
        genre_id INTEGER NOT NULL,
        position INTEGER NOT NULL CHECK(position >= 0),
        PRIMARY KEY(story_id, genre_id),
        UNIQUE(story_id, position),
        FOREIGN KEY(story_id) REFERENCES stories(id) ON DELETE CASCADE,
        FOREIGN KEY(genre_id) REFERENCES genres(id) ON DELETE CASCADE
      )
    ''');

    batch.execute('''
      CREATE TABLE index_jobs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_type TEXT NOT NULL CHECK(length(trim(source_type)) > 0),
        source_id TEXT NOT NULL CHECK(length(trim(source_id)) > 0),
        remote_id TEXT NOT NULL CHECK(length(trim(remote_id)) > 0),
        drive_file_id TEXT,
        status TEXT NOT NULL CHECK(status IN ('pending', 'running', 'complete', 'error')),
        attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
        last_error TEXT,
        updated_at INTEGER NOT NULL CHECK(updated_at >= 0),
        UNIQUE(source_type, source_id, remote_id)
      )
    ''');

    batch.execute(
      'CREATE UNIQUE INDEX stories_drive_file_id_idx '
      'ON stories(drive_file_id)',
    );
    batch.execute(
      'CREATE INDEX stories_normalized_title_idx '
      'ON stories(normalized_title)',
    );
    batch.execute(
      'CREATE INDEX stories_source_idx '
      'ON stories(source_type, source_id)',
    );
    batch.execute(
      'CREATE INDEX story_authors_story_id_idx '
      'ON story_authors(story_id)',
    );
    batch.execute(
      'CREATE INDEX story_authors_author_id_idx '
      'ON story_authors(author_id)',
    );
    batch.execute(
      'CREATE INDEX story_genres_story_id_idx '
      'ON story_genres(story_id)',
    );
    batch.execute(
      'CREATE INDEX story_genres_genre_id_idx '
      'ON story_genres(genre_id)',
    );
    batch.execute(
      'CREATE INDEX index_runs_source_started_idx '
      'ON index_runs(source_type, source_id, started_at)',
    );
    batch.execute(
      'CREATE INDEX index_jobs_status_updated_idx '
      'ON index_jobs(status, updated_at)',
    );

    await batch.commit(noResult: true);
  }
}
