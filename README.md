# vBook - Ứng dụng đọc sách đa nền tảng

Ứng dụng đọc sách & đọc truyện đa nền tảng (Android, iOS, Web, Desktop), hỗ trợ quản lý sách từ Google Drive, tệp cục bộ (EPUB, PDF, TXT) và mở rộng nguồn đọc trực tuyến bằng hệ thống Plugin JavaScript.

---

## 👥 Thông tin thành viên thực hiện

| STT | Họ và tên | Mã sinh viên |
| :---: | :--- | :---: |
| 1 | **Trần Tiến Đức** | `23010777` |
| 2 | **Nguyễn Tiến Hoàng Vũ** | `23010233` |
| 3 | **Lê Thanh Bình** | `23010242` |

---

## 🔥 Các tính năng chính

* 📖 **Đọc sách đa định dạng**: Hỗ trợ định dạng EPUB, PDF, TXT và các nguồn truyện trực tuyến.
* ☁️ **Tích hợp Google Drive**: Quản lý kho sách cá nhân trên Cloud, quét và trích xuất metadata tự động.
* 🧩 **Hệ thống Plugin / Extension**: Mở rộng nguồn đọc trực tuyến linh hoạt bằng mã JavaScript chạy trong môi trường QuickJS Engine an toàn.
* 🔍 **Tìm kiếm hợp nhất (Unified Search)**: Tìm kiếm đồng thời trên Thư viện máy, Google Drive và các Extension online với cơ sở dữ liệu SQLite tối ưu tiếng Việt.
* 🔊 **Chuyển văn bản thành giọng nói (TTS)**: Đọc nội dung với tùy chỉnh giọng đọc, tốc độ, Pitch và bảng điều khiển trực quan.
* 📥 **Quản lý tải xuống Offline**: Tải các chương truyện về máy để đọc khi không có mạng Internet.
* 🔐 **Bảo mật & Tài khoản**: Đăng nhập Firebase Auth, Google Sign-In, đồng bộ tiến trình đọc trên Cloud Firestore & lưu trữ tài khoản cục bộ mã hóa PBKDF2 SHA-256.

---

## 🛠️ Công nghệ sử dụng

* **Frontend**: Flutter (Dart) - Chuẩn giao diện Material 3.
* **State Management**: Provider (`ThemeProvider`, `ReadingSettingsProvider`, `UserProvider`).
* **Extension Engine**: QuickJS Engine + Dart Isolates + Platform Channels (Kotlin trên Android).
* **Backend & Cloud**: Firebase Authentication, Cloud Firestore, Google Drive API.
* **Cơ sở dữ liệu cục bộ**: SQLite (`sqflite`), SharedPreferences.
* **Xử lý định dạng & Đọc**: `epub_view`, `epubx`, `syncfusion_flutter_pdfviewer`, `flutter_tts`.
* **Testing & Tools**: Node.js, Mocha, `@firebase/rules-unit-testing`, Flutter Integration Tests.

---

## 📂 Cấu trúc dự án chính

```text
DALN/
├── lib/
│   ├── main.dart               # Điểm khởi chạy ứng dụng
│   ├── models/                 # Các Data Model (Story, AppUser, PluginInfo,...)
│   ├── screens/                # Màn hình giao diện ứng dụng (Home, Explore, Reader,...)
│   ├── services/               # Logic nghiệp vụ (API, Extension, Drive, Firebase, TTS,...)
│   │   ├── database/           # SQLite database & migrations
│   │   ├── plugin/             # QuickJS Engine & Plugin Loader an toàn
│   │   └── search/             # Hệ thống Tìm kiếm Hợp nhất & SQLite Index
│   ├── theme/                  # Quản lý giao diện, cài đặt đọc & người dùng
│   └── widgets/                # Các widget tái sử dụng (TTS Player, Download Banner,...)
├── firestore.rules             # Quy tắc bảo mật Firestore
├── scripts/                    # Kịch bản Node.js cho Emulator Test & Admin Claim
└── test/                       # Bộ kiểm thử đơn vị & tích hợp (Over 40 test suites)
```

---

## 🚀 Hướng dẫn cài đặt & khởi chạy

### Yêu cầu môi trường
* **Flutter SDK**: `>= 3.11.4`
* **Dart SDK**: Phù hợp với phiên bản Flutter
* **Node.js** (chạy kịch bản kiểm thử Firestore rules nếu cần)

### Các bước khởi chạy
1. **Cloning / Mở dự án**:
   ```bash
   git clone <repository_url>
   cd DALN
   ```

2. **Cài đặt các gói phụ thuộc (Dependencies)**:
   ```bash
   flutter pub get
   ```

3. **Chạy ứng dụng**:
   ```bash
   flutter run
   ```

4. **Chạy kiểm thử (Unit / Integration Tests)**:
   ```bash
   flutter test
   ```

