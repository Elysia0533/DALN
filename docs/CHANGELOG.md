# CHANGELOG — vBook

## [Phase 1 Implementation] 2026-08-10 — Centralizing TTS Architecture & Android Package Visibility (BUG-002)

### Scope
- Centralize TTS architecture into `TtsService.instance` as the single source of truth.
- Declare Android 11+ TTS intent in `AndroidManifest.xml`.
- Standardize safe sentence chunking (1000 max characters limit).

### Changes Made
- **`AndroidManifest.xml`:** Added `<action android:name="android.intent.action.TTS_SERVICE" />` in `<queries>` to fix Android 11+ service binding.
- **`tts_service.dart`:** Added `storyId`, `chapterIndex`, selection mode tracking, `speakSelection()`, `toggle()`, and conservative 1000-character sentence chunking logic.
- **`reading_screen.dart`:** Removed local `FlutterTts` instance, local chunking logic, and state flags. Delegated all speak/toggle/stop calls to `TtsService.instance`. Bound reader audio bar to `TtsService.instance` via `ListenableBuilder`.
- **`chapter_reader_screen.dart`:** Removed local `FlutterTts` instance, local queues, and completion handlers. Delegated chapter transitions, selection speech, menu audio actions, and audio bar UI to `TtsService.instance`.

---

### Scope
- Complete pipeline trace and root cause investigation of the Text-to-Speech (TTS) system.
- Zero functional code modifications performed.

### Findings
- **Architectural Duplication:** Identified 3 separate `FlutterTts` instances causing state desynchronization across `TtsService`, `ReadingScreen`, and `ChapterReaderScreen`.
- **Android Package Visibility Block:** Missing `<intent><action android:name="android.intent.action.TTS_SERVICE" /></intent>` declaration in `AndroidManifest.xml` under `<queries>`.
- **Buffer Oversize:** 3200 character chunk limits in reader screens exceed native Android `TextToSpeech` buffer boundaries.

### Documentation Updates
- Updated `docs/BUGS.md` (BUG-002 detailed root causes).
- Updated `docs/CURRENT_STATUS.md` (TTS module status).

---

## [Phase 1 Implementation] 2026-08-10 — Extension Engine Stability Remediation (BUG-013 + BUG-014)

### Scope
- **BUG-013:** Fix silent failures during extension native engine loading.
- **BUG-014:** Standardize extension identification using persistent `String plugin.id` instead of unstable Dart `hashCode`.

### Changes Made
- **`MainActivity.kt`:** Replaced `sources: MutableMap<Long, JsSource>` with `MutableMap<String, JsSource>`. Updated all `MethodChannel` call handlers to accept `String id`.
- **`vbook_engine_channel.dart`:** Updated all engine methods to accept `String id`. Rethrown `PlatformException` in `loadSource` to propagate detailed native loading failure messages to callers.
- **`extension_service.dart`:** Enforced mandatory successful native engine load in `installPlugin` and `installFromZipFile`. On failure, cleaned up extracted extension files, threw `Exception` to notify UI, and prevented saving uninitialized extension to `SharedPreferences`.
- **`offline_download_service.dart`:** Updated `loadSource` and `getPageList` calls to pass `plugin.id` (String). Added error status handling if engine load fails.
- **UI Screens (`source_browse_screen.dart`, `online_story_detail_screen.dart`, `online_chapter_reader_screen.dart`):** Replaced all `plugin.id.hashCode` / `widget.plugin.id.hashCode` calls with `plugin.id` / `widget.plugin.id`.

### Verification Status
- **Static Analysis:** Passed `flutter analyze` with **0 errors**.
- **Call site audit:** Grep confirmed **0** remaining `plugin.id.hashCode` calls across the entire project.
- **Runtime Verification:** `PENDING` (to be performed on physical Android device / emulator).

---

## [Audit] 2026-08-10 — Initial Project Audit

### Người thực hiện
- AI Assistant (Antigravity)

### Phạm vi audit
Đọc và phân tích toàn bộ cấu trúc project:
- 46 file Dart trong `lib/` (2 root + 8 models + 18 screens + 11 services + 3 theme + 1 utils + 6 widgets)
- 5 file Kotlin native (MainActivity, VBookEngine, JsEnvironment, JsLoader, JsSource, PluginConfig)
- pubspec.yaml, firebase_config.dart, firestore.rules, .env

### Tài liệu tạo mới
| File                     | Mô tả                                              |
|--------------------------|-----------------------------------------------------|
| `docs/PROJECT_CONTEXT.md`| Tổng quan project, cấu trúc, nguồn dữ liệu         |
| `docs/ARCHITECTURE.md`   | Kiến trúc, state management, luồng dữ liệu, dependencies |
| `docs/CURRENT_STATUS.md` | Trạng thái từng module, screen, service, model       |
| `docs/BUGS.md`           | 15 bugs/risks đã xác định (3 critical, 8 warning, 4 info) |
| `docs/FEATURES.md`       | 10 nhóm chức năng đang hoạt động, 4 nhóm chưa hoàn thiện |
| `docs/TEST_PLAN.md`      | 5 phase kiểm thử với ~50 test cases                 |
| `docs/CHANGELOG.md`      | File này                                             |

### Kết quả audit
- **Không thay đổi source code**
- **Không thêm/xóa package**
- **Không thay đổi database/Firebase**

### Tóm tắt phát hiện
- 15 bugs/risks đã ghi nhận (BUG-001 đến BUG-015)
- 3 bugs critical: Extension engine, ApiService god class
- Extension/Source system là phần có vấn đề nhất
- Core features (local reader, Drive, auth, sync) hoạt động tốt
- 2 service chưa hoàn thiện (AmbientAudio, HanVietTranslator)
- 1 dependency có thể không dùng (flutter_js)

### Đề xuất thứ tự sửa chữa (CHƯA THỰC HIỆN)
1. Fix Extension Engine (BUG-001) — Critical, ảnh hưởng nhiều chức năng
2. Fix encoding issue (BUG-011) — Quick fix
3. Verify TTS stability (BUG-002) — Test trên thiết bị thật
4. Audit flutter_js usage (BUG-008) — Quick grep
5. Audit SourcePlugin usage (BUG-009) — Quick grep
6. Dần refactor ApiService (BUG-003) — Long-term, từng bước

---

## Version History

| Version | Date       | Notes                    |
|---------|------------|--------------------------|
| 1.1.0+2 | UNKNOWN   | Current version in pubspec |
| 1.0.0   | UNKNOWN   | UNKNOWN / NEED VERIFICATION |
