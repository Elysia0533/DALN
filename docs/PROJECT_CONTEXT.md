# PROJECT CONTEXT — vBook

> Tài liệu này mô tả tổng quan project vBook, cập nhật lần gần nhất: 2026-08-10.

## 1. Tên Project

- **Tên hiển thị:** vBook
- **Tên package:** `online_story_reader`
- **Version:** 1.1.0+2

## 2. Mô tả

vBook là ứng dụng đọc sách/truyện đa nền tảng xây dựng bằng Flutter, hỗ trợ:
- Đọc file EPUB, PDF, TXT từ thiết bị hoặc Google Drive
- Hệ thống Extension/Plugin để đọc truyện online từ nhiều nguồn (novel & comic)
- Tính năng Text-to-Speech (TTS) để nghe đọc truyện
- Cộng đồng chat (community messages)
- Đồng bộ thư viện & bookmark qua Firebase

## 3. Nền tảng mục tiêu

- **Chính:** Android (có native Kotlin code cho VBook Engine)
- **Flutter SDK:** ^3.11.4
- **Hỗ trợ thêm:** iOS, Web, Windows, Linux, macOS (scaffolded nhưng chưa xác nhận chức năng hoàn chỉnh)

## 4. Ngôn ngữ giao diện

- Tiếng Việt (vi-VN) là ngôn ngữ chính
- Một số error message và debug log bằng tiếng Anh

## 5. Cấu trúc thư mục gốc

```
online_book/
├── android/           # Android platform code (Kotlin native engine)
├── assets/            # Branding, covers, offline stories
├── backend/           # UNKNOWN / NEED VERIFICATION (chưa kiểm tra)
├── lib/               # Flutter source code chính
│   ├── docs/          # Thư mục documentation (mới tạo)
│   ├── firebase_config.dart
│   ├── main.dart
│   ├── models/        # Data models
│   ├── screens/       # UI screens
│   ├── services/      # Business logic services
│   ├── theme/         # Theme & Provider (state management)
│   ├── utils/         # Utilities
│   └── widgets/       # Reusable widgets
├── test/              # Test directory (chưa kiểm tra nội dung)
├── test_extensions/   # Test fixtures cho extension system
├── firestore.rules    # Firebase security rules
├── firebase.json      # Firebase config
├── pubspec.yaml       # Dependencies
└── .env               # Environment variables (Google Drive API key)
```

## 6. Nguồn dữ liệu

| Nguồn            | Mô tả                                                       |
|-------------------|-------------------------------------------------------------|
| Local files       | EPUB/PDF/TXT import từ thiết bị, lưu vào app documents dir |
| Google Drive      | Đọc truyện từ thư mục Drive công khai qua API key           |
| Extension/Plugin  | Plugin JS download từ registry URL, chạy qua native engine  |
| Firebase          | Auth, Firestore (users, library, bookmarks, community)      |
| SharedPreferences | Cache, reading progress, local accounts, installed plugins   |
| Offline downloads | Truyện tải về từ extension, lưu JSON theo chapter            |

## 7. Tài khoản & Quyền

- **Admin email mặc định:** `vglduc25@gmail.com`
- **Firebase config:** Truyền qua `--dart-define` khi build
- **Google Drive API Key:** Truyen qua `--dart-define=GOOGLE_DRIVE_API_KEY=<your_google_drive_api_key>`; khong co fallback hardcoded trong source.

## 8. Trạng thái tổng quan

- Ứng dụng đã chạy được, nhiều chức năng core hoạt động
- Hệ thống Extension/Source đang có lỗi (đặc biệt ở native engine bridge)
- TTS đã implement nhưng cần kiểm tra stability
- Một số service chưa hoàn thiện (AmbientAudioService, HanVietTranslatorService)

## 9. Build & Run

```bash
# Run debug
flutter run --dart-define=FIREBASE_API_KEY=xxx --dart-define=FIREBASE_APP_ID=xxx ...

# APK build
flutter build apk --dart-define=...
```

Firebase config values cần truyền qua `--dart-define` hoặc sử dụng native Android `google-services.json`.
