# CURRENT STATUS — vBook

> Trạng thái hiện tại của project, cập nhật: 2026-08-10.

## Tổng Quan

| Hạng mục              | Trạng thái     | Ghi chú                                    |
|------------------------|----------------|---------------------------------------------|
| App build & launch     | ✅ Hoạt động   | Khởi động, splash, navigation OK            |
| Local file reader      | ✅ Hoạt động   | EPUB, PDF, TXT                              |
| Google Drive reader    | ✅ Hoạt động   | Scan folder, download, read EPUB from Drive |
| Firebase Auth          | ✅ Hoạt động   | Register, login, email verification         |
| Cloud sync (library)   | ✅ Hoạt động   | Sync stories + progress to Firestore        |
| Community chat         | ✅ Hoạt động   | Send/read messages, admin delete            |
| Extension registry     | 🔄 Phase 1 Done| Install validation implemented (BUG-013). Runtime test pending. |
| Extension browsing     | 🔄 Phase 1 Done| String ID standardized across bridge (BUG-014). Runtime test pending. |
| Online reader (novel)  | ⚠️ Phase 1 Done| Bridge identity fixed; quickjs/web limitations remain |
| Online reader (comic)  | ⚠️ Phase 1 Done| Bridge identity fixed; cookie/session limitations remain |
| TTS                    | 🔄 Phase 1 Done| Unified to TtsService.instance, Android 11+ intent added, 1000 char buffer limit (BUG-002). Runtime test pending. |
| Offline download       | ⚠️ Phase 1 Done| Bridge identity fixed; engine reliability improved |
| Ambient audio          | ❌ Stub         | Service tạo nhưng không có audio playback   |
| Hán-Việt translator    | ❌ Minimal      | Chỉ map ~20 từ cố định                      |
| Bookmarks (new system) | ✅ Hoạt động   | Local + cloud sync                          |
| Reading progress       | ✅ Hoạt động   | Debounced save, cloud sync                  |
| EPUB export            | ✅ Hoạt động   | Export downloaded stories to EPUB            |

---

## Chi Tiết Theo Module

### 1. Screens (18 files)

| Screen                         | Size    | Trạng thái     | Ghi chú                        |
|--------------------------------|---------|----------------|----------------------------------|
| `splash_screen.dart`           | 1KB     | ✅ OK          | Simple timer → HomeScreen        |
| `home_screen.dart`             | 33KB    | ✅ OK          | Tab navigation, library grid/list|
| `explore_screen.dart`          | 47KB    | ✅ OK          | Drive stories, search, import    |
| `story_detail_screen.dart`     | 31KB    | ✅ OK          | Story info, chapter selection    |
| `reading_screen.dart`          | 46KB    | ✅ OK          | TXT reader with TTS integration  |
| `chapter_reader_screen.dart`   | 64KB    | ✅ OK          | Multi-chapter reader             |
| `epub_reader_screen.dart`      | 20KB    | ✅ OK          | EPUB via epub_view               |
| `pdf_reader_screen.dart`       | 5KB     | ✅ OK          | PDF via Syncfusion               |
| `bookmarks_screen.dart`        | 7KB     | ✅ OK          | Bookmark management              |
| `reading_stats_screen.dart`    | 7KB     | ✅ OK          | Reading statistics               |
| `community_screen.dart`        | 30KB    | ✅ OK          | Chat UI                          |
| `profile_screen.dart`          | 72KB    | ✅ OK          | Auth forms, settings             |
| `extension_screen.dart`        | 43KB    | ⚠️ Có vấn đề  | Plugin list, install/uninstall   |
| `source_browse_screen.dart`    | 31KB    | ⚠️ Có vấn đề  | Browse source content            |
| `online_story_detail_screen.dart`| 30KB  | ⚠️ Có vấn đề  | Online story detail              |
| `online_chapter_reader_screen.dart`| 41KB| ⚠️ Có vấn đề  | Online chapter content reader    |
| `download_manager_screen.dart` | 20KB    | ⚠️ Phụ thuộc  | Depends on engine reliability    |
| `web_browser_screen.dart`      | 13KB    | ✅ OK          | In-app WebView browser           |

### 2. Services (11 files + plugin subdir)

| Service                         | Size    | Trạng thái     | Ghi chú                        |
|---------------------------------|---------|----------------|----------------------------------|
| `api_service.dart`              | 74KB    | ⚠️ God class  | 2142 dòng, quá lớn, quá nhiều trách nhiệm |
| `firebase_backend_service.dart` | 18KB    | ✅ OK          | Clean, tách biệt Firebase logic  |
| `google_drive_service.dart`     | 27KB    | ✅ OK          | Folder scanning, download        |
| `extension_service.dart`        | 10KB    | ⚠️ Có vấn đề  | Plugin install/registry OK, nhưng engine unreliable |
| `tts_service.dart`              | 10KB    | ⚠️ Cần verify  | Chunking, controls, sleep timer   |
| `bookmark_service.dart`         | 7KB     | ✅ OK          | Clean, debounced save             |
| `offline_download_service.dart` | 14KB    | ⚠️ Phụ thuộc  | Depends on engine getPageList     |
| `epub_export_service.dart`      | 8KB     | ✅ OK          | Export to EPUB format             |
| `ambient_audio_service.dart`    | 1KB     | ❌ Stub        | Chỉ có state, không có audio player |
| `han_viet_translator_service.dart`| 2KB   | ❌ Minimal     | Hardcoded map ~20 từ              |
| `plugin/plugin_loader.dart`     | 5KB     | ✅ OK          | ZIP download & extract            |
| `plugin/vbook_engine_channel.dart`| 6KB   | ⚠️ Bridge     | MethodChannel bridge to native    |
| `plugin/plugin_model.dart`      | 0.3KB   | ⚠️ Unused?    | SourcePlugin model, có thể không dùng |

### 3. Models (8 files)

| Model                  | Trạng thái | Ghi chú                                      |
|------------------------|-----------|------------------------------------------------|
| `story.dart`           | ✅ OK     | Core model, 20 fields, copyWith + toJson      |
| `app_user.dart`        | ✅ OK     | User model with role                           |
| `plugin_info.dart`     | ✅ OK     | Extension metadata, fromRegistryJson           |
| `source_models.dart`   | ✅ OK     | SManga, SChapter, MangasPage, PluginConfig     |
| `online_chapter.dart`  | ✅ OK     | OnlineChapter, NovelContent, ComicContent      |
| `reading_progress.dart`| ✅ OK     | ReadingProgress + Bookmark model               |
| `reading_marker.dart`  | ✅ OK     | ReadingMarker for history/bookmarks            |
| `community_message.dart`| ✅ OK    | Chat message model                             |

### 4. Theme/Providers (3 files)

| File                            | Trạng thái | Ghi chú                          |
|---------------------------------|-----------|-----------------------------------|
| `theme_provider.dart`           | ✅ OK     | Material3, dark/light, cyan seed  |
| `reading_settings_provider.dart`| ✅ OK     | Font, bg, line height, TTS params |
| `user_provider.dart`            | ✅ OK     | Auth state, delegates to ApiService|

### 5. Widgets (6 files)

| Widget                          | Trạng thái | Ghi chú                          |
|---------------------------------|-----------|-----------------------------------|
| `app_state_widgets.dart`        | ✅ OK     | Loading/error state widgets       |
| `background_download_banner.dart`| ✅ OK    | Download progress banner          |
| `bookmark_sheet.dart`           | ✅ OK     | Bookmark bottom sheet             |
| `reader_selectable_text.dart`   | ✅ OK     | Custom selectable text            |
| `story_cover_image.dart`        | ✅ OK     | Cover image with Drive fallbacks  |
| `tts_control_sheet.dart`        | ✅ OK     | TTS control bottom sheet          |

### 6. Native Kotlin (5 files)

| File                | Size    | Trạng thái     | Ghi chú                              |
|---------------------|---------|----------------|----------------------------------------|
| `MainActivity.kt`  | 18KB    | ⚠️ Complex    | MethodChannel handler, nhiều method    |
| `VBookEngine.kt`   | 25KB    | ⚠️ Có vấn đề  | Core engine, session/cookie management |
| `JsEnvironment.kt` | 13KB    | ⚠️ Có vấn đề  | JS execution, HTTP bridge              |
| `JsLoader.kt`      | 10KB    | ✅ OK          | Plugin ZIP extract & validation        |
| `JsSource.kt`      | 32KB    | ⚠️ Có vấn đề  | JS script execution, data parsing      |
| `PluginConfig.kt`   | 2KB    | ✅ OK          | Kotlin model                           |
