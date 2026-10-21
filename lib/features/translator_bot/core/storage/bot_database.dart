import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/translation_models.dart';

class BotDatabase {
  static final BotDatabase instance = BotDatabase._internal();
  factory BotDatabase() => instance;
  BotDatabase._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDb();
    return _database!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'translator_bot.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE profiles (
            id TEXT PRIMARY KEY,
            title TEXT,
            src_lang TEXT,
            tgt_lang TEXT,
            preset TEXT,
            style_guide TEXT,
            version INTEGER,
            updated_at INTEGER
          )
        ''');

        await db.execute('''
          CREATE TABLE glossary_terms (
            id TEXT PRIMARY KEY,
            profile_id TEXT,
            source TEXT,
            target TEXT,
            type TEXT,
            note TEXT,
            is_confirmed INTEGER,
            always_include INTEGER,
            FOREIGN KEY (profile_id) REFERENCES profiles (id) ON DELETE CASCADE
          )
        ''');

        await db.execute('''
          CREATE TABLE address_rules (
            id TEXT PRIMARY KEY,
            profile_id TEXT,
            speaker TEXT,
            listener TEXT,
            self_ref TEXT,
            other_ref TEXT,
            context TEXT,
            FOREIGN KEY (profile_id) REFERENCES profiles (id) ON DELETE CASCADE
          )
        ''');

        await db.execute('''
          CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            profile_id TEXT,
            folder_name TEXT,
            chapter_title TEXT,
            kind TEXT,
            source_ref TEXT,
            status TEXT,
            rolling_summary TEXT,
            created_at INTEGER
          )
        ''');

        await db.execute('''
          CREATE TABLE segments (
            session_id TEXT,
            seg_id TEXT,
            src TEXT,
            tgt TEXT,
            state TEXT,
            error TEXT,
            PRIMARY KEY (session_id, seg_id),
            FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE
          )
        ''');

        await db.execute('''
          CREATE TABLE cached_segments (
            hash TEXT PRIMARY KEY,
            tgt TEXT,
            last_used INTEGER
          )
        ''');
      },
    );
  }

  // --- Profile Operations ---
  Future<void> saveProfile(TranslationProfile profile) async {
    final db = await database;
    await db.insert(
      'profiles',
      profile.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<TranslationProfile?> getProfile(String id) async {
    final db = await database;
    final maps = await db.query('profiles', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return TranslationProfile.fromMap(maps.first);
  }

  Future<List<TranslationProfile>> getAllProfiles() async {
    final db = await database;
    final maps = await db.query('profiles', orderBy: 'updated_at DESC');
    return maps.map((m) => TranslationProfile.fromMap(m)).toList();
  }

  // --- Glossary Operations ---
  Future<void> saveGlossaryTerm(GlossaryTerm term) async {
    final db = await database;
    await db.insert(
      'glossary_terms',
      term.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<GlossaryTerm>> getTermsByProfile(String profileId) async {
    final db = await database;
    final maps = await db.query(
      'glossary_terms',
      where: 'profile_id = ?',
      whereArgs: [profileId],
    );
    return maps.map((m) => GlossaryTerm.fromMap(m)).toList();
  }

  // --- Address Rule Operations ---
  Future<void> saveAddressRule(AddressRule rule) async {
    final db = await database;
    await db.insert(
      'address_rules',
      rule.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<AddressRule>> getAddressRulesByProfile(String profileId) async {
    final db = await database;
    final maps = await db.query(
      'address_rules',
      where: 'profile_id = ?',
      whereArgs: [profileId],
    );
    return maps.map((m) => AddressRule.fromMap(m)).toList();
  }

  // --- Session & Segment Operations ---
  Future<void> saveSession(TranslationSession session) async {
    final db = await database;
    await db.insert(
      'sessions',
      session.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> saveSegments(String sessionId, List<TranslationSegment> segments) async {
    final db = await database;
    final batch = db.batch();
    for (final seg in segments) {
      batch.insert(
        'segments',
        seg.toMap(sessionId),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<TranslationSegment>> getSegments(String sessionId) async {
    final db = await database;
    final maps = await db.query(
      'segments',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'rowid ASC',
    );
    return maps.map((m) => TranslationSegment.fromMap(m)).toList();
  }

  Future<void> updateSegmentTranslation(String sessionId, String segId, String tgt, SegmentState state) async {
    final db = await database;
    await db.update(
      'segments',
      {'tgt': tgt, 'state': state.name},
      where: 'session_id = ? AND seg_id = ?',
      whereArgs: [sessionId, segId],
    );
  }

  /// Đổi trạng thái phiên thành 'saved' vĩnh viễn
  Future<void> markSessionAsSaved(String sessionId, {String? folderName, String? chapterTitle}) async {
    final db = await database;
    final updates = <String, dynamic>{'status': SessionStatus.saved.name};
    if (folderName != null) updates['folder_name'] = folderName;
    if (chapterTitle != null) updates['chapter_title'] = chapterTitle;
    await db.update('sessions', updates, where: 'id = ?', whereArgs: [sessionId]);
  }

  /// Xóa phiên và các segment liên quan
  Future<void> deleteSession(String sessionId) async {
    final db = await database;
    await db.delete('segments', where: 'session_id = ?', whereArgs: [sessionId]);
    await db.delete('sessions', where: 'id = ?', whereArgs: [sessionId]);
  }

  /// Lấy danh sách các phiên đã lưu theo từng thư mục truyện
  Future<Map<String, List<TranslationSession>>> getSavedSessionsGroupedByFolder() async {
    final db = await database;
    final maps = await db.query(
      'sessions',
      where: 'status = ?',
      whereArgs: [SessionStatus.saved.name],
      orderBy: 'created_at DESC',
    );
    final result = <String, List<TranslationSession>>{};
    for (final m in maps) {
      final session = TranslationSession.fromMap(m);
      result.putIfAbsent(session.folderName, () => []).add(session);
    }
    return result;
  }

  /// Tìm các phiên tạm (temp) bị bỏ quên khi thoát app đột ngột
  Future<List<TranslationSession>> getOrphanTempSessions() async {
    final db = await database;
    final maps = await db.query(
      'sessions',
      where: 'status = ?',
      whereArgs: [SessionStatus.temp.name],
    );
    return maps.map((m) => TranslationSession.fromMap(m)).toList();
  }

  /// Dọn sạch các phiên tạm
  Future<void> clearAllTempSessions() async {
    final tempSessions = await getOrphanTempSessions();
    for (final s in tempSessions) {
      await deleteSession(s.id);
    }
  }

  // --- Cache Segments ---
  Future<String?> getCachedTranslation(String hash) async {
    final db = await database;
    final maps = await db.query('cached_segments', where: 'hash = ?', whereArgs: [hash]);
    if (maps.isEmpty) return null;
    return maps.first['tgt'] as String?;
  }

  Future<void> cacheTranslation(String hash, String tgt) async {
    final db = await database;
    await db.insert(
      'cached_segments',
      {
        'hash': hash,
        'tgt': tgt,
        'last_used': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
