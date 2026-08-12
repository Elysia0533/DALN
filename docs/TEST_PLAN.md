# TEST PLAN — vBook

> Kế hoạch kiểm thử ban đầu, cập nhật: 2026-08-10.

## Mục tiêu

Xác định trạng thái hoạt động của từng chức năng trước khi tiến hành sửa lỗi. Ưu tiên kiểm tra các phần đang có vấn đề (Extension, TTS, Online Reader).

---

## Phase 1: Smoke Test — Chức Năng Core

> **Mục tiêu:** Xác nhận các chức năng chính vẫn hoạt động.

### T1.1 App Startup
| # | Test Case                                    | Expected                     | Actual | Pass? |
|---|----------------------------------------------|------------------------------|--------|-------|
| 1 | Mở app                                      | Splash → Home trong ~1.2s    |        |       |
| 2 | Chuyển tab Thư viện → Khám phá → Chat → Hồ sơ | Mỗi tab load đúng            |        |       |
| 3 | Toggle dark/light mode                       | Theme chuyển đúng            |        |       |

### T1.2 Local Reading
| # | Test Case                                    | Expected                     | Actual | Pass? |
|---|----------------------------------------------|------------------------------|--------|-------|
| 1 | Import file EPUB từ máy                     | Story xuất hiện trong thư viện|        |       |
| 2 | Mở EPUB đã import → đọc                    | EPUB reader hiển thị nội dung|        |       |
| 3 | Import file PDF → mở đọc                    | PDF reader hiển thị          |        |       |
| 4 | Import file TXT → mở đọc                    | TXT reader hiển thị          |        |       |
| 5 | Thoát reader → mở lại → kiểm tra progress   | Trở lại vị trí đã đọc       |        |       |

### T1.3 Google Drive
| # | Test Case                                    | Expected                     | Actual | Pass? |
|---|----------------------------------------------|------------------------------|--------|-------|
| 1 | Tab Khám phá → load danh sách Drive         | Hiển thị truyện từ Drive     |        |       |
| 2 | Chọn truyện Drive → thêm vào thư viện       | Story xuất hiện trong library|        |       |
| 3 | Mở truyện từ Drive → đọc                    | Download và hiển thị reader  |        |       |

### T1.4 Authentication
| # | Test Case                                    | Expected                     | Actual | Pass? |
|---|----------------------------------------------|------------------------------|--------|-------|
| 1 | Đăng ký tài khoản mới                       | Account created              |        |       |
| 2 | Đăng nhập tài khoản đã có                   | Login thành công             |        |       |
| 3 | Thoát đăng nhập                             | Session cleared              |        |       |
| 4 | Mở lại app → tự động restore session        | Auto login                   |        |       |

---

## Phase 2: Extension System Test

> **Mục tiêu:** Xác định chính xác trạng thái hệ thống extension.

### T2.1 Registry & Install
| # | Test Case                                    | Expected                     | Actual | Pass? |
|---|----------------------------------------------|------------------------------|--------|-------|
| 1 | Mở Extension screen → load registry          | Danh sách plugin hiển thị    |        |       |
| 2 | Cài đặt 1 plugin (ví dụ: TruyenFull)         | Install thành công           |        |       |
| 3 | Kiểm tra plugin.json tồn tại sau install      | File exists in vbook_plugins/|        |       |
| 4 | Gỡ cài đặt plugin                            | Plugin removed               |        |       |
| 5 | Cài đặt plugin từ file ZIP local             | Install thành công           |        |       |

### T2.2 Browse & Search
| # | Test Case                                    | Expected                     | Actual | Pass? |
|---|----------------------------------------------|------------------------------|--------|-------|
| 1 | Mở source đã cài → browse trang chủ          | Hiển thị danh sách truyện    |        |       |
| 2 | Tìm kiếm truyện trong source                 | Kết quả hiển thị             |        |       |
| 3 | Xem chi tiết truyện online                   | Title, cover, description OK |        |       |
| 4 | Xem mục lục (chapter list)                   | Chapters hiển thị            |        |       |

### T2.3 Online Reading
| # | Test Case                                    | Expected                     | Actual | Pass? |
|---|----------------------------------------------|------------------------------|--------|-------|
| 1 | Đọc 1 chapter novel online                   | Nội dung text hiển thị       |        |       |
| 2 | Đọc 1 chapter comic online                   | Ảnh hiển thị                 |        |       |
| 3 | Chuyển chapter (next/prev)                    | Content load đúng            |        |       |

### T2.4 Multi-Plugin Test
| # | Plugin     | Install | Browse | Search | Detail | Read |
|---|-----------|---------|--------|--------|--------|------|
| 1 | TruyenFull |        |        |        |        |      |
| 2 | Hako       |        |        |        |        |      |
| 3 | TruyenQQ   |        |        |        |        |      |
| 4 | (others)   |        |        |        |        |      |

---

## Phase 3: TTS Test

> **Mục tiêu:** Xác định trạng thái TTS trên thiết bị thật.

### T3.1 Basic TTS
| # | Test Case                                    | Expected                     | Actual | Pass? |
|---|----------------------------------------------|------------------------------|--------|-------|
| 1 | Mở truyện TXT → bật TTS                     | Bắt đầu đọc tiếng Việt      |        |       |
| 2 | Pause → Resume                               | TTS tiếp tục (có thể từ đầu chunk) |  |       |
| 3 | Stop                                         | TTS dừng                     |        |       |
| 4 | Next chunk → Previous chunk                  | Chuyển đoạn đọc              |        |       |
| 5 | Điều chỉnh speed                             | Tốc độ đọc thay đổi         |        |       |
| 6 | Điều chỉnh pitch                             | Pitch thay đổi               |        |       |
| 7 | Điều chỉnh volume                            | Volume thay đổi              |        |       |

### T3.2 TTS Advanced
| # | Test Case                                    | Expected                     | Actual | Pass? |
|---|----------------------------------------------|------------------------------|--------|-------|
| 1 | Set sleep timer 1 phút                       | TTS tự dừng sau 1 phút      |        |       |
| 2 | Stop at end of chapter                       | TTS dừng khi hết chương     |        |       |
| 3 | Auto-next chapter                            | TTS tự chuyển sang chương tiếp|       |       |
| 4 | TTS với text rất dài (>10000 chars)           | Chunking hoạt động OK       |        |       |
| 5 | TTS với text có HTML entities                 | Đọc text đã clean            |        |       |

---

## Phase 4: Integration Test

> **Mục tiêu:** Kiểm tra sự tương tác giữa các chức năng.

| # | Test Case                                    | Expected                     | Actual | Pass? |
|---|----------------------------------------------|------------------------------|--------|-------|
| 1 | Download truyện offline → đọc offline        | Nội dung hiển thị từ cache   |        |       |
| 2 | Bookmark → thoát → mở lại → tap bookmark     | Quay lại vị trí bookmark     |        |       |
| 3 | Login → add story → logout → login → thư viện | Story đã sync về             |        |       |
| 4 | Thêm truyện online vào library → mở từ library | Navigate đúng screen         |        |       |
| 5 | Export downloaded story to EPUB               | EPUB file tạo thành công     |        |       |
| 6 | Export downloaded story to TXT                | TXT file tạo thành công      |        |       |
| 7 | TTS đang chạy → thoát reader                 | TTS stop clean               |        |       |
| 8 | Download đang chạy → thoát app               | Download state handled       |        |       |

---

## Phase 5: Edge Cases & Error Handling

| # | Test Case                                    | Expected                     | Actual | Pass? |
|---|----------------------------------------------|------------------------------|--------|-------|
| 1 | Mở app không có internet                     | App vẫn mở, local stories OK|        |       |
| 2 | Login không có internet                      | Local login fallback         |        |       |
| 3 | Extension install không có internet           | Error message hiển thị      |        |       |
| 4 | Import file EPUB bị corrupt                  | Error handled, không crash   |        |       |
| 5 | Google Drive folder không tồn tại            | Error message hiển thị      |        |       |
| 6 | Firebase chưa config → mở app               | App vẫn hoạt động, auth disabled |    |       |

---

## Ghi Chú

- Tất cả test cần thực hiện trên **thiết bị Android thật** (extension engine cần native code)
- Test TTS cần thiết bị có TTS engine cài sẵn (Google TTS recommended)
- Extension test phụ thuộc vào server của từng website source
- Kết quả test sẽ được cập nhật trong file này sau khi thực hiện
