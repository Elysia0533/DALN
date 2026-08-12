# BUGS & RISKS — vBook

> Các lỗi và rủi ro đã xác định qua audit, cập nhật: 2026-08-10.
> 
> **Quy ước:**
> - 🔴 CRITICAL — Ảnh hưởng chức năng chính, cần sửa ngay
> - 🟡 WARNING — Có thể gây lỗi trong một số trường hợp
> - 🟢 INFO — Cần cải thiện nhưng không gây crash

---

## BUG-001 🔴 Extension Engine — Native Bridge Không Ổn Định

**Vị trí:** `VBookEngine.kt`, `JsSource.kt`, `JsEnvironment.kt`

**Mô tả:** Hệ thống extension (plugin JS) chạy qua native Kotlin engine thường xuyên không trả về dữ liệu hoặc trả về dữ liệu rỗng. Đã có nhiều conversation trước đây cố gắng fix nhưng vấn đề vẫn tồn tại.

**Triệu chứng:**
- Plugin cài đặt thành công nhưng browse không hiển thị truyện
- `getPopularManga()` / `getPageList()` return null hoặc empty list
- Lỗi liên quan đến cookie/session khi fetch từ các website bảo vệ bởi Cloudflare

**Nguyên nhân có thể:**
- JS script execution environment không ổn định
- Cookie synchronization giữa WebView và native HTTP client
- Một số website yêu cầu browser fingerprint/JS challenge

**Ảnh hưởng:** ExtensionScreen, SourceBrowseScreen, OnlineStoryDetailScreen, OnlineChapterReaderScreen, OfflineDownloadService

---

## BUG-002 🔴 TTS System — Architectural Duplication, Missing Android Package Visibility & Chunking Oversize

**Status:** REMEDIATED (Implementation Complete, Runtime Verification Pending)

**Vị trí:** `lib/services/tts_service.dart`, `lib/screens/reading_screen.dart`, `lib/screens/chapter_reader_screen.dart`, `android/app/src/main/AndroidManifest.xml`

**Root Causes & Khắc phục đã thực hiện:**

1. **Đã bổ sung Intent Package Visibility trong `AndroidManifest.xml`:**
   - Đã thêm `<action android:name="android.intent.action.TTS_SERVICE" />` vào thẻ `<queries>` để khắc phục triệt để lỗi bind service im lặng trên Android 11+ (API 30+).

2. **Đã Centralize Architecture về Single Source of Truth `TtsService.instance`:**
   - Đã xóa toàn bộ 2 instance local `FlutterTts` thừa trong `ReadingScreen` và `ChapterReaderScreen`.
   - Tất cả tác vụ phát audio chapter, đọc đoạn bôi đen (`speakSelection`), chuyển chương tự động (`onChapterComplete`), tạm dừng / tiếp tục đều đi qua `TtsService.instance`.
   - Giao diện audio bar của màn hình đọc đã chuyển sang dùng `ListenableBuilder` lắng nghe trực tiếp `TtsService.instance`, loại bỏ hoàn toàn tình trạng desync UI.

3. **Chuẩn hóa Chunking Safety (Max 1000 Ký Tự):**
   - Đưa độ dài chunk tối đa về `1000` ký tự (an toàn tuyệt đối cho buffer native Android `TextToSpeech`).
   - Chuẩn hóa thuật toán ngắt câu thông minh theo dấu ngắt câu (`[.!?。！？]\s`), khoảng trắng ` `, đảm bảo không tràn buffer native.

---

## BUG-003 🔴 ApiService — God Class 2142 Dòng

**Vị trí:** `lib/services/api_service.dart`

**Mô tả:** `ApiService` chứa 2142 dòng code với quá nhiều trách nhiệm:
- EPUB metadata extraction
- Google Drive cover caching
- Authentication (register, login, verify email)
- Local account management
- Community messages
- Reading history & bookmarks
- Story CRUD (import, update, delete)
- Cloud sync
- Chapter progress

**Rủi ro:**
- Khó maintain và debug
- Dễ gây regression khi sửa một phần
- Tight coupling giữa các concern không liên quan

**Lưu ý:** KHÔNG refactor ngay. Đánh dấu để xử lý sau khi ổn định các bug critical.

---

## BUG-004 🟡 Password Lưu Plaintext trong SharedPreferences

**Vị trí:** `api_service.dart:1015-1031` (`_saveLocalBackupAccount()`)

**Mô tả:** Local account backup lưu password dạng plaintext trong SharedPreferences:
```dart
final accountData = {
  ...user.toJson(),
  'password': password,     // ← PLAINTEXT
  'pendingCloudSync': pendingCloudSync,
};
```

**Rủi ro:** Bảo mật — trên thiết bị root, SharedPreferences có thể đọc được.

---

## BUG-005 - Google Drive API Key Hardcoded

**Status:** REMEDIATED (Implementation Complete, Key Rotation Recommended)

**Vi tri:** `google_drive_service.dart`, local `.env` developer files

**Mo ta:** Google Drive API key tung co hardcoded fallback trong `GoogleDriveService.apiKey`. Fallback trong source da bi loai bo; app nhan key qua `--dart-define=GOOGLE_DRIVE_API_KEY=<your_google_drive_api_key>`.

**Rui ro con lai:** API key dua vao mobile app van co the bi trich xuat tu APK. Khong coi `--dart-define` la secret vault. Can restrict key trong Google Cloud theo Android package name, signing certificate SHA-1, API duoc phep va quota. Key da tung expose nen nen rotate trong Google Cloud.
---

## BUG-006 🟢 AmbientAudioService — Stub Không Hoạt Động

**Vị trí:** `lib/services/ambient_audio_service.dart`

**Mô tả:** Service chỉ quản lý state (`_isPlaying`, `_currentSound`, `_volume`) nhưng không thực sự play audio. Không có audio player package nào được import hay sử dụng.

**Ảnh hưởng:** UI có thể hiển thị ambient audio controls nhưng không phát âm thanh.

---

## BUG-007 🟢 HanVietTranslatorService — Chỉ Map Cố Định

**Vị trí:** `lib/services/han_viet_translator_service.dart`

**Mô tả:** Service chỉ chứa ~20 từ Hán-Việt hardcoded. Không có dictionary API hay file từ điển. Chức năng dịch thuật gần như không hiệu quả.

---

## BUG-008 🟡 flutter_js Package — Có Thể Không Dùng

**Vị trí:** `pubspec.yaml:37`

**Mô tả:** Package `flutter_js: ^0.8.2` được khai báo nhưng hệ thống extension hiện tại sử dụng native Kotlin engine (Duktape/QuickJS). 

**ĐÃ XÁC NHẬN:** Grep toàn bộ `lib/` — không có file nào import `flutter_js`. Package này có thể remove an toàn khỏi `pubspec.yaml`.

---

## BUG-009 🟡 PluginModel — Có Thể Không Dùng

**Vị trí:** `lib/services/plugin/plugin_model.dart`

**Mô tả:** Class `SourcePlugin` (16 dòng) có vẻ không được sử dụng bởi bất kỳ file nào khác. Đã có `PluginInfo` trong models/ và `PluginConfig` trong source_models.dart.

**ĐÃ XÁC NHẬN:** Grep toàn bộ `lib/` — `SourcePlugin` chỉ xuất hiện trong chính file `plugin_model.dart` (khai báo class + constructor). Không file nào import hay sử dụng nó. Có thể xóa file này.

---

## BUG-010 🟡 Firestore Rules — Community Messages ReadBy All

**Vị trí:** `firestore.rules:63`

**Mô tả:** `community_messages` collection cho phép `allow read: if true` — bất kỳ ai có Firestore project ID đều đọc được tất cả messages. Đây có thể là intentional cho public chat nhưng cần xác nhận.

---

## BUG-011 🟡 Encoding Issue trong Firebase Error Message

**Vị trí:** `firebase_backend_service.dart:264`

**Mô tả:** Dòng 264 chứa encoding bị hỏng:
```dart
'Cáº§n Ä'Äƒng nháº­p vÃ  xÃ¡c nháº­n email Ä'á»ƒ gá»­i tin nháº¯n.',
```
Nội dung mong muốn có thể là: "Cần đăng nhập và xác nhận email để gửi tin nhắn."

---

## BUG-012 🟢 DropdownButtonFormField Deprecated Usage

**Vị trí:** `home_screen.dart:154`

**Mô tả:** `DropdownButtonFormField` sử dụng `initialValue` — NEED VERIFICATION xem đây có phải deprecated parameter hay custom property.

---

## BUG-013 🟡 Extension Install — Non-blocking Engine Load Warning

**Status:** IMPLEMENTED — RUNTIME VERIFICATION PENDING

**Vị trí:** `extension_service.dart:128-133`

**Mô tả:** Khi cài plugin, nếu `VBookEngineChannel.loadSource()` fail, error bị nuốt (non-fatal warning). Plugin vẫn được đánh dấu là installed nhưng engine có thể chưa load thành công.

**Remediation (Phase 1):** Đã sửa `ExtensionService.installPlugin` và `installFromZipFile` bắt buộc `loadSource` phải thành công. Nếu load fail: tự động dọn dẹp directory extension, ném `Exception` báo lỗi lên UI (SnackBar) và KHÔNG lưu plugin vào `SharedPreferences`.

---

## BUG-014 🟡 plugin.id.hashCode Collision Risk & Instability

**Status:** IMPLEMENTED — RUNTIME VERIFICATION PENDING

**Vị trí:** `extension_service.dart`, `vbook_engine_channel.dart`, `MainActivity.kt`, `source_browse_screen.dart`, `online_story_detail_screen.dart`, `online_chapter_reader_screen.dart`, `offline_download_service.dart`

**Mô tả:** Native engine sử dụng `plugin.id.hashCode` làm ID để identify source. Dart `String.hashCode` không cố định qua các lần khởi động app và có nguy cơ collision → sai source hoặc NOT_LOADED.

**Remediation (Phase 1):** Đã chuyển toàn bộ giao tiếp Flutter-Kotlin MethodChannel sang `String id` (sử dụng trực tiếp `plugin.id` / `story.pluginId`). `MainActivity.kt` chuyển `sources` map sang `MutableMap<String, JsSource>()`. Toàn bộ call sites trong Dart đã được cập nhật, loại bỏ `plugin.id.hashCode`.

---

## BUG-015 🟢 Offline Download — Hardcoded Public Path

**Vị trí:** `offline_download_service.dart:60`

**Mô tả:** Trên Android, download folder cố định là `/storage/emulated/0/Download/VBook`. Nếu permission bị từ chối, fallback sang external storage directory. Không request runtime permission ở đây.

**NEED VERIFICATION:** Kiểm tra AndroidManifest.xml cho storage permissions.

---

## Điểm Có Nguy Cơ Gây Regression

| # | Khu vực                        | Lý do                                          |
|---|--------------------------------|-------------------------------------------------|
| 1 | `ApiService` (toàn bộ)        | God class, sửa 1 method có thể ảnh hưởng nhiều |
| 2 | Native Kotlin engine           | Thay đổi JS execution có thể break all plugins |
| 3 | `Story` model                  | 20 fields, serialize/deserialize nhiều nơi      |
| 4 | Authentication flow             | Local + Firebase dual path rất phức tạp         |
| 5 | `SharedPreferences` keys       | Đổi key name sẽ mất data user hiện tại          |
| 6 | `PluginInfo.fromRegistryJson()` | URL resolution logic, dễ break registry format  |

---

## Những Phần TUYỆT ĐỐI KHÔNG Nên Tự Ý Rewrite

1. **`ApiService`** — Quá lớn, quá nhiều dependency. Cần refactor từ từ, không rewrite.
2. **`FirebaseBackendService`** — Đang hoạt động tốt, không nên thay đổi.
3. **`GoogleDriveService`** — Logic phức tạp nhưng stable, đã handle nhiều edge cases.
4. **`Story` model** — Quá nhiều nơi sử dụng, thay đổi sẽ cần update everywhere.
5. **Firestore security rules** — Thay đổi có thể lock out existing users.
6. **Native Kotlin engine** — Cần hiểu sâu JS runtime trước khi sửa.
7. **`BookmarkService`** — Đang hoạt động tốt, clean code.
8. **`ThemeProvider` + `ReadingSettingsProvider`** — Stable, không cần thay đổi.
