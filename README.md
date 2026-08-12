# vBook

Flutter app doc truyen EPUB, PDF va TXT. App lay catalog/file truyen truc tiep
tu Google Drive, con tai khoan, xac nhan email, chat cong dong, thu vien ca
nhan va tien do doc duoc luu bang Firebase Auth + Cloud Firestore.

## Kien truc release

```text
Flutter APK
  -> Google Drive API: catalog va file truyen
  -> Firebase Auth: dang ky, dang nhap, gui link xac nhan email
  -> Cloud Firestore: profile, chat cong dong, thu vien, tien do doc
  -> Local storage: cache truyen, file offline, vi tri doc gan nhat
```

APK release khong can chay backend Python tren may tinh. Khi mo app, app goi
Firebase va Google Drive truc tiep.

## Chay app

```sh
flutter pub get
flutter run
```

Man Kham pha lay danh sach truyen truc tiep tu Google Drive. Link Drive co the
truyen bang `--dart-define` hoac gan san trong
`lib/services/google_drive_service.dart` tai `hardcodedFolderUrls`.

```sh
flutter run --dart-define=GOOGLE_DRIVE_API_KEY=<your_google_drive_api_key>
```

Neu co nhieu thu muc Drive, dung `GOOGLE_DRIVE_FOLDER_URLS` va ngan cach bang
dau phay, dau cham phay, dau `|`, hoac xuong dong.

Neu khong truyen `GOOGLE_DRIVE_API_KEY`, app van build duoc nhung chuc nang
Drive se bao loi cau hinh ro rang khi nguoi dung truy cap danh sach/tai file
Drive.

## Cau hinh Firebase

1. Tao Firebase project.
2. Them Android app voi package name `com.vbook.reader`.
3. Bat `Authentication > Sign-in method > Email/Password`.
4. Tao Cloud Firestore database.
5. Sua email admin trong `firestore.rules`.
6. Deploy rules:

```sh
firebase deploy --only firestore:rules
```

Chay app voi Firebase:

```sh
flutter run ^
  --dart-define=FIREBASE_API_KEY=your_firebase_api_key ^
  --dart-define=FIREBASE_APP_ID=your_firebase_app_id ^
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=your_sender_id ^
  --dart-define=FIREBASE_PROJECT_ID=your_project_id ^
  --dart-define=FIREBASE_STORAGE_BUCKET=your_project.appspot.com ^
  --dart-define=VBOOK_ADMIN_EMAILS=your_admin_email@gmail.com
```

Co the dien cac gia tri public cua Firebase truc tiep vao
`lib/firebase_config.dart` neu khong muon truyen `--dart-define` moi lan build.
Cac gia tri nay khong phai mat khau; bao mat du lieu nam o Firebase Auth va
Firestore Rules.

## Build APK release

Release APK bat buoc phai dung release keystore rieng. Debug signing key chi
duoc dung cho debug build; release build se dung `android/key.properties` local
hoac environment variables trong CI. Khong commit keystore hoac mat khau vao
repository.

Tao keystore tren may ca nhan:

```sh
keytool -genkeypair -v ^
  -keystore %USERPROFILE%\upload-keystore.jks ^
  -storetype JKS ^
  -keyalg RSA ^
  -keysize 2048 ^
  -validity 10000 ^
  -alias upload
```

Tao file local `android/key.properties`:

```properties
storeFile=C:\\Users\\<you>\\upload-keystore.jks
storePassword=<your_store_password>
keyAlias=upload
keyPassword=<your_key_password>
```

Hoac cau hinh CI bang environment variables:

```text
VBOOK_RELEASE_STORE_FILE=/secure/path/upload-keystore.jks
VBOOK_RELEASE_STORE_PASSWORD=<your_store_password>
VBOOK_RELEASE_KEY_ALIAS=upload
VBOOK_RELEASE_KEY_PASSWORD=<your_key_password>
```

```sh
flutter build apk --release ^
  --dart-define=GOOGLE_DRIVE_API_KEY=<your_google_drive_api_key> ^
  --dart-define=FIREBASE_API_KEY=your_firebase_api_key ^
  --dart-define=FIREBASE_APP_ID=your_firebase_app_id ^
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=your_sender_id ^
  --dart-define=FIREBASE_PROJECT_ID=your_project_id ^
  --dart-define=FIREBASE_STORAGE_BUCKET=your_project.appspot.com ^
  --dart-define=VBOOK_ADMIN_EMAILS=your_admin_email@gmail.com
```

Android package hien tai: `com.vbook.reader`.

## Kiem tra

```sh
flutter analyze
flutter test
flutter build apk --debug
```

## Ghi chu bao mat

- App tam thoi van bat cleartext HTTP tren Android de tuong thich extension va
  source dong. HTTP khong bao dam tinh bi mat hoac tinh toan ven: registry,
  file ZIP extension, noi dung truyen hoac anh co the bi doc/sua tren duong
  truyen. Tac gia registry/extension nen dung HTTPS. Chuyen sang HTTPS-only la
  thay doi chinh sach san pham trong tuong lai va can migration rieng cho
  extension/source HTTP hien co.
- Google Drive API key neu nam trong APK thi khong bi xem la bi mat tuyet doi.
  `--dart-define` chi la cau hinh build-time, khong phai secret vault.
  Bao ve thuc te phai dua vao Google Cloud API restriction, Android application
  restriction va quota.
- Trong Google Cloud Console, vao `APIs & Services > Credentials`, chon API key
  dung cho app, dat `Application restrictions` thanh `Android apps`, them package
  name `com.vbook.reader` va SHA-1 signing certificate cua debug/release key can
  dung. Dat `API restrictions` thanh `Restrict key` va chi cho phep Google Drive
  API. Dat quota/canh bao chi phi phu hop cho project.
- Firebase API key/config la dinh danh public cua app, khong phai mat khau.
  Bao mat Firestore bang `firestore.rules`.
- Firestore admin quyen xoa community message phai dung Firebase Auth custom
  claim `admin: true`, gan bang Firebase Admin SDK trong trusted environment
  truoc khi deploy rules. Khong dua service-account JSON vao repository. Sau
  khi gan claim, admin co the can refresh ID token hoac dang nhap lai. UI hien
  co van co the hien nut admin theo app role/email, nhung security rule chi tin
  custom claim.
- SMTP password/backend secret khong can dua vao APK nua vi app da chuyen sang
  Firebase Auth gui email xac nhan.
