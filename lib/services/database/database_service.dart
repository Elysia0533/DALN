import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'search_index_migrations.dart';

typedef DatabasePathResolver = Future<String> Function();

class DatabaseService {
  DatabaseService({
    DatabaseFactory? factory,
    DatabasePathResolver? pathResolver,
  }) : _factory = factory ?? databaseFactory,
       _pathResolver = pathResolver ?? _defaultDatabasePath;

  static const String databaseName = 'vbook_index.db';
  static final DatabaseService instance = DatabaseService();

  final DatabaseFactory _factory;
  final DatabasePathResolver _pathResolver;

  Database? _database;
  Future<Database>? _opening;

  Future<Database> get database {
    final openDatabase = _database;
    if (openDatabase != null && openDatabase.isOpen) {
      return Future.value(openDatabase);
    }

    final pendingOpen = _opening;
    if (pendingOpen != null) return pendingOpen;

    final opening = _openAndTrack();
    _opening = opening;
    return opening;
  }

  Future<void> close() async {
    final pendingOpen = _opening;
    final databaseToClose = pendingOpen == null ? _database : await pendingOpen;
    _database = null;

    if (databaseToClose != null && databaseToClose.isOpen) {
      await databaseToClose.close();
    }
  }

  Future<Database> _openAndTrack() async {
    try {
      final databasePath = await _pathResolver();
      final opened = await _factory.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: SearchIndexSchema.version,
          onConfigure: (database) async {
            await database.execute('PRAGMA foreign_keys = ON');
          },
          onCreate: (database, version) {
            return SearchIndexSchema.migrate(database, 0, version);
          },
          onUpgrade: SearchIndexSchema.migrate,
        ),
      );
      _database = opened;
      return opened;
    } finally {
      _opening = null;
    }
  }

  static Future<String> _defaultDatabasePath() async {
    return path.join(await getDatabasesPath(), databaseName);
  }
}
