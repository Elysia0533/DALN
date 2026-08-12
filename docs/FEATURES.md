# FEATURES — vBook

> Danh sách chức năng hiện có và dự kiến, cập nhật: 2026-08-10.

## A. Chức Năng Đang Hoạt Động ✅

### A1. Thư Viện Cá Nhân (Library)
- [x] Hiển thị danh sách truyện đã import/lưu
- [x] Grid view và List view toggle
- [x] Tùy chỉnh số cột grid (2-4)
- [x] Sắp xếp: mới thêm / tên A-Z / đang đọc trước
- [x] Tìm kiếm truyện theo tên, tác giả, thể loại
- [x] Import file EPUB/PDF/TXT từ thiết bị
- [x] Xóa truyện khỏi thư viện
- [x] Tự động extract metadata từ EPUB (title, author, cover, genres, description)
- [x] Lazy loading với pagination (20 items/lần)
- [x] Mở truyện online (nếu có pluginId)

### A2. Khám Phá (Explore)
- [x] Hiển thị truyện từ Google Drive folders
- [x] Thêm folder Drive thủ công
- [x] Demo folders tích hợp sẵn (6 folders)
- [x] Cache catalog 30 phút
- [x] Tìm kiếm trong danh sách
- [x] Auto-enrich metadata cho EPUB trên Drive
- [x] Thêm truyện từ Drive vào thư viện

### A3. Đọc Sách (Reader)
- [x] **EPUB Reader** — via `epub_view` package, hiển thị chapter navigation
- [x] **PDF Reader** — via `syncfusion_flutter_pdfviewer`
- [x] **TXT Reader** — Custom ScrollView, paginated chapters
- [x] **Chapter Reader** — Multi-chapter reader cho các truyện có nhiều chapter
- [x] Tùy chỉnh font (6 fonts Google Fonts)
- [x] Tùy chỉnh cỡ chữ (12-28)
- [x] Tùy chỉnh khoảng cách dòng (1.2-2.2)
- [x] 5 màu nền đọc (trắng, sepia, xanh nhạt, xám tối, đen OLED)
- [x] Lưu tiến độ đọc (debounced)
- [x] Bookmark vị trí đọc

### A4. Text-to-Speech (TTS)
- [x] TTS engine tích hợp (FlutterTts)
- [x] Tự động detect và chọn ngôn ngữ vi-VN
- [x] Split text thành chunk (max 2000 chars, sentence boundary)
- [x] Play/Pause/Stop controls
- [x] Next/Previous chunk navigation
- [x] Điều chỉnh speed, pitch, volume
- [x] Sleep timer (phút)
- [x] Stop at end of chapter option
- [x] Auto-next chapter callback
- [x] TTS control bottom sheet UI

### A5. Authentication (Firebase)
- [x] Đăng ký email/password
- [x] Đăng nhập
- [x] Xác nhận email (verification link)
- [x] Gửi lại email xác nhận
- [x] Quên mật khẩu (password reset email)
- [x] Chỉnh sửa profile (display name, avatar)
- [x] Auto-refresh session khi mở app
- [x] Offline local accounts (fallback khi không có Firebase)
- [x] Admin role (hardcoded email check)

### A6. Cloud Sync (Firebase)
- [x] Sync thư viện lên Firestore
- [x] Sync tiến độ đọc
- [x] Sync bookmarks
- [x] Merge cloud library vào local khi login
- [x] Auto sync pending data

### A7. Community Chat
- [x] Đọc tin nhắn cộng đồng
- [x] Gửi tin nhắn (yêu cầu email verified)
- [x] Admin xóa tin nhắn
- [x] Hiển thị avatar, display name
- [x] Hỗ trợ attachment type/path (cấu trúc có nhưng UI NEED VERIFICATION)
- [x] Local community messages khi Firebase offline

### A8. Bookmarks & Reading History
- [x] Bookmark vị trí đọc (chapter, paragraph, scroll offset)
- [x] Ghi chú bookmark
- [x] Màu highlight bookmark
- [x] Lịch sử đọc (30 entries gần nhất)
- [x] Cloud sync bookmarks
- [x] Bookmark management screen

### A9. Offline Download
- [x] Download batch chapters từ extension source
- [x] Skip đã download
- [x] Retry logic (3 lần, adaptive delay)
- [x] Cancel download
- [x] Download progress tracking
- [x] Export to TXT
- [x] Export to EPUB
- [x] Download manager screen
- [x] Delete downloaded stories

### A10. Khác
- [x] Dark mode / Light mode
- [x] Material 3 theming (cyan seed color)
- [x] Splash screen
- [x] In-app web browser
- [x] Share story
- [x] Cover image smart loading (local file, Drive, network)

---

## B. Chức Năng Có Nhưng Chưa Hoàn Thiện ⚠️

### B1. Extension/Source System
- [⚠️] Fetch registry từ GitHub
- [⚠️] Install plugin từ ZIP URL
- [⚠️] Install plugin từ local ZIP file
- [⚠️] Install plugin từ direct ZIP URL
- [⚠️] Uninstall plugin
- [⚠️] Multi-registry support (built-in + custom)
- [⚠️] NSFW content filter
- [❌] Browse source content — engine bridge không ổn định
- [❌] Search trong source — phụ thuộc engine
- [❌] Hiển thị story detail từ source — thường fail
- [❌] Đọc chapter online — content thường rỗng

### B2. Online Reader
- [⚠️] Novel reader (text content) — khi engine trả về data thì OK
- [⚠️] Comic reader (image pages) — image loading phụ thuộc cookies
- [❌] Consistent content fetching — tùy plugin, tùy website

### B3. Ambient Audio
- [❌] Chọn loại âm thanh (rain, lofi, nature, cafe) — state only, no audio
- [❌] Volume control — state only, no audio
- [❌] Play/Stop — state toggle, không phát âm thanh thực

### B4. Hán-Việt Translator
- [❌] Dịch Hán-Việt — chỉ map ~20 từ cố định, không có dictionary

---

## C. Chức Năng Dự Kiến / Có Thể Thêm 📋

> Chưa có trong code, nhưng cấu trúc project gợi ý:

1. **Notifications** — Push notification cho chapter mới
2. **Reading statistics** — ReadingStatsScreen có nhưng cần verify data source
3. **Cloud backup/restore** — Ngoài library sync, backup toàn bộ settings
4. **Multi-language UI** — Hiện chỉ có Vietnamese
5. **Book categorization** — Organize library theo thể loại/tags
6. **Review/Rating** — Đánh giá truyện
7. **Social features** — Follow users, share reading list
8. **Full Hán-Việt dictionary** — Từ điển Hán-Việt đầy đủ cho truyện TQ
9. **Audio playback** — Ambient sound thực sự hoạt động
10. **Offline-first extension** — Cache extension data cho offline reading
