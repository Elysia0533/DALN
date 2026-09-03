# vBook — PROJECT PROGRESS

- **Last Updated:** 2026-09-03 15:30 +07:00
- **Project Status:** STABILIZATION — 3 P0 unresolved; plugin installer and cross-process recovery are verified while extension execution isolation, auth lifecycle, and offline comic correctness remain open
- **Current Milestone:** Release hardening and core-flow verification
- **Active Task:** SEARCH-001-B — VERIFIED / DALN CHECKPOINT INCLUDED IN THIS COMMIT
- **Release Readiness:** NOT READY
- **Worktree:** CLEAN TRACKED SNAPSHOT AFTER THIS DALN CHECKPOINT

> SINGLE PROJECT PROGRESS DASHBOARD
>
> Before every task, read this file. After any task that changes source code,
> behavior, project status, or verification results, update the affected sections
> in `PROJECT_PROGRESS.md` before ending the task.

## Update Policy

- Treat actual code and current Git/test/runtime evidence as more reliable than older documentation.
- Update only the sections affected by the task; do not rewrite the whole dashboard each time.
- Never mark a task `FIXED` or `VERIFIED` without direct test or runtime evidence.
- Preserve important status history and record regressions when found.
- After a task, update Active Task, task status, Test Status, Current Worktree, Next Action, Last Updated, and Release Readiness when applicable.
- Do not expose credentials, API keys, tokens, signing passwords, or private user data in this file.

This is the only project-progress document tracked in DALN. Older local documents remain on the development machine but are intentionally ignored by Git.

## Status Legend

### Priority

- 🔴 P0 — Release blocker, security/data risk, or core failure
- 🟠 P1 — Core functionality issue
- 🟡 P2 — Important improvement
- 🟢 P3 — Cleanup or polish

### Task Status

- ⬜ `NOT STARTED`
- 🔎 `INVESTIGATING`
- 📝 `PLAN READY`
- `APPROVED`
- `IN PROGRESS`
- ✅ `IMPLEMENTED`
- 🧪 `RUNTIME VERIFICATION PENDING`
- ⚠️ `PARTIAL`
- ⛔ `BLOCKED`
- `FIXED`
- ✔ `VERIFIED`

`IMPLEMENTED` means code exists. It does not mean the behavior is verified on a device.

## Project Summary

| Group | Count | Current assessment |
|---|---:|---|
| P0 | 4 | 3 unresolved; SEC-PLUGIN-001 is verified, while execution isolation, auth migration, and offline comic correctness remain open |
| P1 | 11 | Core flows are partial or awaiting runtime verification; SEARCH-001-A/B database and Drive metadata indexing layers pass local verification while Phase C has not started |
| P2 | 9 | Reader quality, performance, platform, and legacy cleanup |
| Implemented but unverified | 9 | Includes best-effort EXT-EXEC-001 guards, remaining Firebase auth lifecycle behavior, and Drive edge cases |
| Blocked | 1 | Local account to Firebase migration policy |
| Runtime test areas pending | 13 | Plugin install/recovery is closed; Firebase, Drive, extension execution, and other core flows retain documented runtime gaps |

## ACTIVE TASK

- **Task ID:** `SEARCH-001`
- **Title:** Drive metadata index, SQLite search, and extension search
- **Status:** `SEARCH-001-A/B IMPLEMENTED` / `LOCAL VERIFICATION PASSED` / `DALN CHECKPOINT COMMITTED` / `STOPPED BEFORE PHASE C`
- **Owner:** AI Agent
- **Files audited:** `pubspec.yaml`, `pubspec.lock`, `lib/models/story.dart`, `lib/models/plugin_info.dart`, `lib/screens/explore_screen.dart`, `lib/screens/source_browse_screen.dart`, `lib/widgets/story_cover_image.dart`, `lib/services/api_service.dart`, `lib/services/google_drive_service.dart`, `lib/services/plugin/vbook_engine_channel.dart`, and the native extension search bridge.
- **Last action:** Implemented Phase B as an independent Drive-to-SQLite indexing layer, fixed misleading plugin/emulator test workflows, verified the accumulated app snapshot, and created the DALN repository checkpoint. Legacy backend/docs/diagnostic files were removed from Git tracking only and remain local.
- **Next action:** Review Phase B, then begin `SEARCH-001-C` only after a separate continuation checkpoint. Phase C will add parameterized SQLite title/author/genre queries and pagination without reading Explore's lazy-loaded list.
- **Blocking issue:** None inside Phase B. Production scheduling and index-progress UI remain intentionally unwired so this checkpoint does not add duplicate Drive work or change current Explore behavior.
- **Runtime verification:** Twenty scoped SQLite/parser/Drive tests pass, including a real temporary SQLite database, a 500-record index, unchanged/modified/deleted files, incomplete traversal, request failure preservation, stale catalogs, and single-flight. Analyzer, all 114 Flutter tests, and debug APK build pass. Android database runtime was not exercised because the coordinator is not yet invoked by a production call flow; no emulator was used.

## P0 — Release Blockers

### SEC-PLUGIN-001 — Harden Plugin Installer Paths and ZIP Extraction

**Priority:** P0

**Status:** `VERIFIED`

**Problem:** Registry/ZIP-controlled `pluginId` is used to construct paths. Extraction and recursive cleanup may reach outside the intended plugin directory. ZIP resource limits are absent.

**Root Cause:** Identifier validation was incomplete; descendant checks used string `startsWith()` rather than boundary-aware path checks; archive resources were unbounded. Runtime follow-up also found that manual ZIP metadata was parsed as a flat registry record and uninstall only removed SharedPreferences state.

**Files:** `lib/models/plugin_info.dart`, `lib/screens/extension_screen.dart`, `lib/services/plugin/plugin_loader.dart`, `lib/services/extension_service.dart`, and plugin loader tests/helpers.

**Implemented:** Plugin IDs now reject traversal, separators, absolute/ambiguous paths, reserved names, and unsupported characters. ZIP preflight enforces 20 MiB compressed size, 512 entries, 16 MiB per entry, 64 MiB total expanded data, 100:1 compression ratio, path-length limits, unique safe paths, and no symlink/special entries. All install routes extract to staging, validate with a temporary engine ID, atomically replace the target with backup/rollback, and only then persist installed state. A bounded append-only transaction journal records only safe basenames, phase, version, and a canonical plugin-state hash; startup recovery finalizes or rolls back without storing registry URLs or credentials. Direct ZIP installs parse nested vBook metadata and use a valid manifest name as stable ID when no explicit ID exists. Uninstall closes the engine and performs boundary-checked no-follow cleanup before removing persisted state.

**Verification:** `plugin_loader_security_test.dart` passes 20/20 cases, adding interrupted prepared-state cleanup, committed-update rollback with old preferences, and committed-update finalization with new preferences. Full Flutter suite passes 94/94; analyzer and debug APK build pass. Android core runtime passes for registry/direct/local install, replacement, malformed ZIP cleanup, and uninstall. The default integration harness passes 2/2 on Android 16: filesystem/preferences recovery and real native staging-load plus injected final-load failure with previous-source reload. On 2026-09-01 the two-phase harness also passed across two physical Android processes: preparation PID 29659 and recovery PID 29919, with ADB evidence of the persisted journal before relaunch and complete cleanup afterward.

**Remaining:** No open installer recovery acceptance item. Real-source browsing and JavaScript runtime isolation remain separate concerns under extension execution/network compatibility.

**Risk:** Arbitrary file write/delete, denial of service, or application data loss.

**Next Action:** Preserve the regression harness and proceed to `EXT-EXEC-001` in a separate phase.

### AUTH-MIG-001 — Define Local Account to Firebase Migration Policy

**Priority:** P0

**Status:** `BLOCKED`

**Problem:** Local passwords are correctly hashed, but pending cloud sync currently needs the original password and supplies an empty string. Automatic account creation/linking is therefore impossible.

**Root Cause:** PBKDF2 is one-way; the product has no explicit re-authentication/link-account flow. Firebase failure can still create a pending local account.

**Files:** `lib/services/api_service.dart`, `lib/services/firebase_backend_service.dart`, `lib/providers/user_provider.dart`, `lib/screens/profile_screen.dart`.

**Implemented:** Versioned PBKDF2-HMAC-SHA256 storage, per-account salt, and safe legacy plaintext migration on successful local login.

**Verification:** Password hashing tests exist. End-to-end local-to-cloud linking is not implemented or verified.

**Remaining:** Product decision: preserve legacy local login while stopping new fallback accounts, or add an explicit password re-entry/linking workflow.

**Risk:** Users can receive a local account that never becomes a real Firebase account and may later be unable to sign in under cloud-first behavior.

**Next Action:** Obtain a product decision before editing authentication behavior.

### OFFLINE-COMIC-001 — Make Comic Downloads Truly Offline

**Priority:** P0

**Status:** `NOT STARTED`

**Problem:** Comic downloads primarily persist remote image URLs instead of image bytes. A single-page comic can follow the novel branch, and same-title stories from different sources can share a folder.

**Root Cause:** Download type is inferred from page count and storage identity is title-based rather than source/story based.

**Files:** `lib/services/offline_download_service.dart`, `lib/screens/download_manager_screen.dart`, `lib/screens/online_chapter_reader_screen.dart`, `lib/services/epub_export_service.dart`.

**Implemented:** Batch chapter download state, retry, cancel flag, novel TXT/EPUB export, and download manager UI.

**Verification:** No offline-device comic test or collision regression test is recorded.

**Remaining:** Persist image files, define deterministic storage IDs, classify source content explicitly, and make export behavior type-aware.

**Risk:** “Downloaded” comics fail without network; content can collide or be overwritten.

**Next Action:** Specify the on-disk comic format and backward-compatibility migration before implementation.

### EXT-EXEC-001 — Bound Extension JavaScript Execution

**Priority:** P0

**Status:** `PARTIAL` / `RUNTIME VERIFICATION PENDING`

**Problem:** Extension scripts have no proven execution timeout/resource budget. Promise/async behavior is incomplete and many failures are masked as null/empty data.

**Root Cause:** Native execution had no deadline or structured error contract, and Kotlin/Dart wrappers converted failures into null or empty data. The bundled `quickjs-android:0.9.2` Java API also exposes no interrupt handler, heap limit, or pending-job execution API.

**Files:** `android/app/src/main/kotlin/com/vbook/reader/vbook_engine/VBookEngine.kt`, `EngineException.kt`, `JsEnvironment.kt`, `android/app/src/main/kotlin/com/vbook/reader/source/JsSource.kt`, `android/app/src/main/kotlin/com/vbook/reader/MainActivity.kt`, `lib/services/plugin/vbook_engine_channel.dart`, `test/vbook_engine_channel_test.dart`.

**Implemented:** Each engine now runs calls on a dedicated daemon worker with a 30-second caller deadline, 100 ms cancellation/session checks, source-generation invalidation, and lifecycle cleanup. Inputs and host resources are bounded to 2 MiB scripts, 16 MiB network bodies/results, 8 million HTML characters, 10,000 JSoup handles, and 5-second host sleeps. Native and Dart layers preserve typed timeout, network, JavaScript, parse, resource, cancellation, unavailable-engine, and unsupported-async failures. Promise/thenable results are rejected explicitly instead of becoming null/empty data.

**Verification:** Kotlin debug compilation passed. Five bridge contract tests cover valid empty data, timeout propagation, parse failure propagation, unsupported Promise results, and unexpected null native responses. `flutter analyze --no-pub`, all 78 Flutter tests, and the debug APK build passed on 2026-08-24.

**Remaining:** Run the Android runtime matrix for timeout, cancellation, malformed results, network failures, valid empty data, and source reload. A full sandbox still requires replacing/forking the wrapper or process isolation: a CPU-bound native loop cannot be interrupted safely, the heap cannot be capped through this Java API, and pending Promise jobs cannot be executed.

**Risk:** The caller recovers with a typed timeout and the engine is invalidated, but a native CPU-bound loop can leave its daemon worker occupied until process exit. Resource bounds reduce memory exposure but are not a runtime heap limit. Async extensions remain unsupported with an explicit error.

**Next Action:** Complete device/runtime verification, then make an explicit architecture decision on a forked/replacement QuickJS binding or isolated execution process before promoting this task to `VERIFIED`.

## P1 — Core Functionality

### ONLINE-READER-001 — Progress, Concurrency, and Error Fidelity

**Priority:** P1

**Status:** `PARTIAL`

**Problem:** Online progress/history are incomplete; rapid slider/search navigation can start overlapping requests; stale responses may overwrite current state. The bridge now preserves typed engine failures, but screens still need user-facing recovery states. Comic image requests do not share the complete extension cookie session.

**Root Cause:** Screen-level requests lack a complete generation/cancellation contract, deterministic online identity, progress persistence, and a shared cookie-aware image path.

**Files:** `lib/screens/source_browse_screen.dart`, `online_story_detail_screen.dart`, `online_chapter_reader_screen.dart`, `lib/services/plugin/vbook_engine_channel.dart`.

**Verification:** No online browse/detail/reader widget or native integration test is recorded.

**Remaining:** Add stale-response protection, explicit error states, progress/history persistence, deterministic online story identity, deduplication, and cookie-compatible image loading.

**Risk:** Wrong chapter display, duplicate library entries, lost progress, and false “no content” messages.

**Next Action:** Define request identity and online story identity before implementation.

### CLOUD-SYNC-001 — Reconcile Library and Progress Safely

**Priority:** P1

**Status:** `PARTIAL`

**Problem:** Full story upserts previously rewrote `createdAt` and conflicted with current Firestore update rules. That path is fixed locally; merge still mainly inserts missing records and does not reconcile progress conflicts for existing stories. Random online IDs can duplicate across devices.

**Root Cause:** The client sent a new server timestamp for immutable `createdAt` on every merge. The remaining reconciliation issues come from the absence of deterministic source identity and a conflict policy.

**Files:** `lib/services/firebase_backend_service.dart`, `lib/services/api_service.dart`, `firestore.rules`, `test/firestore.rules.test.cjs`, `test/firebase_library_sync_test.dart`.

**Verification:** Firestore emulator tests pass 22/22, including rejection of a recreated `createdAt`, successful repeated full merge while preserving the original timestamp, and creation without the optional field. Three Dart tests verify the production payload and valid/malformed cloud record parsing. The full Flutter suite passes 89/89, analyzer and debug APK build pass. On Android, the rebuilt APK restored the existing session and startup sync path with no permission or library-sync error; direct cloud document inspection and multi-device reconciliation remain unverified.

**Remaining:** Define last-write/conflict semantics, normalize online IDs with a backward-compatible migration, and add controlled end-to-end reconciliation coverage. Durable deletion remains tracked separately under `CLOUD-DELETE-001`.

**Risk:** Rejected sync, stale progress, duplicated stories, or one malformed document breaking a fetch.

**Next Action:** Specify the progress conflict and online identity contracts before implementing or testing merge replacement behavior.

### CLOUD-DELETE-001 — Add Durable Delete and Retry Semantics

**Priority:** P1

**Status:** `NOT STARTED`

**Problem:** Failed story/bookmark deletion has no durable outbox, retry queue, or tombstone and may be resurrected by later cloud merge.

**Root Cause:** Cloud operations are best-effort and failures are primarily logged rather than persisted.

**Files:** `lib/services/api_service.dart`, `lib/services/firebase_backend_service.dart`.

**Verification:** No offline-delete/reconnect regression test exists.

**Remaining:** Define tombstone retention, retry policy, conflict ordering, and user-visible failure state.

**Risk:** Deleted user data unexpectedly reappears.

**Next Action:** Design deletion state before changing the storage schema.

### FIREBASE-SESSION-001 — Prevent Stale Session and Clarify Android Configuration

**Priority:** P1

**Status:** `PARTIAL` / `CONFIGURATION RUNTIME VERIFIED`

**Problem:** Token refresh failure can leave a saved user displayed as logged in. Android is treated as eligible for native Firebase initialization even when no generated native configuration pipeline is present.

**Root Cause:** Refresh failure does not always clear persisted state; platform detection is used as a proxy for actual native configuration. Firebase values use compile-time `String.fromEnvironment`, while not every run/build path passes `.env`. Android native fallback is advertised but the project has no Google Services Gradle plugin or generated Firebase resources.

**Files:** `lib/theme/user_provider.dart`, `lib/services/firebase_backend_service.dart`, `lib/firebase_config.dart`, `lib/main.dart`, IDE launch configuration, and Android Gradle configuration.

**Verification:** Missing-config startup was first reproduced on device `23113RKC6C` running Android 16. After the fix, Gradle resource processing, analyzer, all 78 Flutter tests, a no-dart-define debug APK, and APK resource inspection passed. On 2026-08-25 that APK installed successfully; Firebase initialized without configuration errors, restored an existing Auth session after process restart, and refreshed the ID token/admin claim successfully.

**Remaining:** Complete a user-controlled fresh login/logout/clean-install matrix, define stale-session clearing, and keep local-to-cloud account migration under `AUTH-MIG-001`. Do not request or store a user's password for automated verification.

**Risk:** Misleading logged-in UI and authentication startup failures.

**Next Action:** Record a user-driven fresh credential login/logout result, then specify stale-session behavior before promoting the whole task to `VERIFIED`.

### PERF-001 — Startup, Drive Pagination, and Explore Infinite Scroll

**Priority:** P1

**Status:** `PARTIAL` / `LOCAL DEBUG PERFORMANCE VERIFIED`

**Phase 1:** Early `runApp()`, background offline initialization, splash delay removal, deferred cover repair, and performance logging are implemented. A process-cold Android launch measured 2.482 seconds to activity startup completion.

**Phase 2:** `DrivePage<T>`, Explore page size 15, page tokens, concurrency limit 3, recursive Drive pagination, metadata paging, Android app identity headers, and pagination tests exist. Folder cursors are fetched in ordered batches of at most three, and limiter permits are transferred directly to queued callers so concurrent traversals cannot exceed the cap. Android reads the Drive key from a Gradle-generated native resource when no `--dart-define` is supplied; no hardcoded fallback was added.

**Phase 3:** Explore initial paging, infinite scroll, retry UI, and load-more state exist in source. A monotonically increasing load generation prevents stale initial-page, load-more, and metadata responses from mutating a newer refresh. Initial-page and refresh loads use a UI-level single-flight future, and refresh controls are disabled while that load is active. Refresh during load-more remains allowed so the newer generation can discard the stale continuation result. Injectable page/plugin loaders provide deterministic widget coverage without changing production defaults.

**Files:** `lib/main.dart`, `lib/screens/explore_screen.dart`, `lib/services/google_drive_service.dart`, `lib/services/app_identity_service.dart`, `android/.../MainActivity.kt`, `test/google_drive_pagination_test.dart`, `test/explore_drive_race_test.dart`.

**Verification:** Targeted Drive configuration/pagination/race tests pass 11/11, including an explicit page-size-15 contract, empty folder, paged catalog-only folder, independent traversal streams, rapid-refresh single-flight, refresh-during-load-more, ordered folder batching, and limiter contention. On 2026-09-01 `flutter analyze --no-pub` passed, all 94 Flutter tests passed, and the debug APK built after the page-size change. On physical Android, Drive returned 15 items in 4.308s and Explore committed them in 4.421s. Historical page-size-50 device measurements remain useful as a batching baseline: 17.655s before batching, 6.163s after batching for page one, 4.049s for page two, and a later 7.075s initial load.

**Remaining:** Benchmark page-size-15 load-more and image completion separately. Exercise a real catalog-only Drive folder and verify the restricted key against the real release signing certificate when available. Reconcile the paged Explore path with the legacy full-scan path: saved admin folder inputs and the 30-minute catalog cache are currently bypassed by initial paging, `info.json` metadata is not applied consistently, and manual scans replace the list without resetting pagination state. A true on-device load-more/refresh overlap was not achieved through ADB, although deterministic widget coverage verifies response ordering. Runtime confirmed that cover fallback can download an entire EPUB and fail above 150 MiB; this is assigned to SEARCH-001 metadata/catalog design rather than solved by further shrinking UI pages.

**Risk:** Empty Explore results, stale pages, slow scans, and Android key restriction mismatch.

**Next Action:** Keep Explore pagination independent and address metadata/cover latency through the proposed SEARCH-001 catalog/index pipeline after approval.

### SEARCH-001 — Drive Metadata Index, SQLite Search, and Extension Search

**Priority:** P1

**Status:** `SEARCH-001-A/B IMPLEMENTED` / `LOCAL VERIFICATION PASSED` / `PHASES C-G NOT STARTED`

**Current Persistence:** Phase A provides one app-owned `DatabaseService` for `vbook_index.db`, schema version 1, and a versioned migration entrypoint. Existing compatible `sqflite 2.4.2+1` is declared directly; `sqflite_common_ffi 2.4.0+3` is a test-only dependency compatible with the current Dart 3.11.4 SDK. Phase B adds a production-capable coordinator and repository lifecycle APIs, but the database is still not opened during app startup and no automatic production call flow invokes indexing yet. Existing Drive/local story JSON in SharedPreferences remains untouched.

**Current Drive Search Problem:** Explore search/filter still reads only `_serverStories`, so the UI cannot yet find a story outside loaded pages. Phase B now retains Drive `modifiedTime`, `size`, and `md5Checksum` in the metadata path and can persist all traversed records independently of Explore pagination. Phase C SQL queries and the later scheduling/UI connection are still required before users can search that index.

**Current Cover Flow:** `StoryCoverImage` first renders `Story.iconUrl`. Network covers use `Image.network` and several Drive URL candidates without persistent disk image caching. If every URL fails or no cover exists, EPUB cards call `getCachedDriveCoverPath()`, which may download the entire EPUB up to 150 MiB, parse it, convert the cover to JPEG, and save it under `app_flutter/drive_covers`. Explore also enriches up to 12 EPUB records sequentially, while visible card fallbacks can start separate per-file tasks. Runtime on 2026-09-01 reproduced an oversized full-EPUB cover attempt after the 15-item list had already loaded.

**Required Separation:**

```text
Google Drive
  +-- Explore pagination (15/page, UI only)
  +-- Metadata index coordinator
        +-- catalog.vbook.json/catalog.json when available
        +-- Drive file metadata scan
        +-- bounded format-specific extraction for missing fields
        +-- SQLite vbook_index.db

Search
  +-- Drive/local SQLite repository
  +-- selected extension search APIs
```

Explore pagination must never be the search index. Search returns indexed records immediately and exposes `NOT_STARTED`, `INDEXING`, `READY`, `PARTIAL`, or `ERROR` plus indexed/total counts so partial results are not presented as complete.

**Proposed Publisher Catalog:** JSON is the portable Drive manifest imported into SQLite; it is not a replacement for the local database. Prefer a versioned `catalog.vbook.json`, while retaining read compatibility with current `catalog.json`. It must contain no API key, token, cookie, or credential.

```json
{
  "schemaVersion": 1,
  "generatedAt": "ISO-8601 timestamp",
  "source": {"type": "googleDrive", "rootFolderId": "placeholder"},
  "stories": [
    {
      "driveFileId": "placeholder",
      "fileName": "book.epub",
      "mimeType": "application/epub+zip",
      "modifiedTime": "ISO-8601 timestamp",
      "size": 0,
      "md5Checksum": null,
      "title": "Original title",
      "authors": ["Author"],
      "genres": ["Genre"],
      "description": "",
      "cover": {"driveFileId": "placeholder"},
      "metadataStatus": "complete"
    }
  ]
}
```

Catalog generation belongs to an admin/publisher workflow. The mobile app currently has public read access through an API key, not trusted Drive write authorization, so the client must not try to upload or rewrite the shared catalog.

**Implemented SQLite Schema (Phase A):** `vbook_index.db` schema version 1 contains `stories`, `authors`, `story_authors`, `genres`, `story_genres`, `index_runs`, and `index_jobs`. `stories` stores source identity, unique optional Drive file ID, original/normalized title, MIME type, modified time, size, checksum, description, cover references, metadata status, last-seen run, and last-indexed time. Foreign keys, source identity uniqueness, normalized lookup indexes, job/run indexes, and indexes on both sides of author/genre joins are enabled. Repository writes validate the complete input first, cap each write at 100 stories, then update entities and relations in batches inside one transaction with no network work.

**Implemented Drive Indexer (Phase B):** `GoogleDriveService` now has a separate full metadata traversal that requests only listing metadata and downloads bounded `info.json`/catalog files, never EPUB/PDF/TXT content. `catalog.vbook.json` is preferred while legacy `catalog.json` remains readable; catalog source/version/size/count are validated, and stale catalog entries cannot resurrect files absent from the Drive traversal. `DriveMetadataIndexer` fetches network data before database transactions, batches writes at 100 records, compares checksum or modified-time/size evidence, preserves richer unchanged metadata, records fixed non-sensitive run/job error codes, coalesces concurrent syncs per source, and removes stale rows only after a complete traversal. The coordinator is callable but deliberately not auto-started at this checkpoint.

**Search Normalization:** Phase A preserves original story/label text and stores deterministic aliases using trim, lowercase, collapsed whitespace, Vietnamese precomposed-character folding, and combining-mark removal. Unit tests prove `Tiên Hiệp`, decomposed Unicode, and `tien hiep` normalize compatibly without changing displayed story text. FTS remains unimplemented; Phase C must use parameterized SQL and detect runtime FTS support before enabling FTS4/FTS5.

**Metadata Extraction Strategy:** Prefer shared catalog or `info.json`, then Drive metadata/app properties, then format extraction, filename fallback, and finally `MISSING`. TXT may use `Range: bytes=0-524287` and parse explicit title/author/genre headers. EPUB safe mode downloads and parses a changed file once in a background isolate with extraction concurrency 2; do not assume the first 512 KiB contains ZIP metadata. PDF prefers sidecar/catalog and only performs a bounded one-time background parse when the current parser supports it. SQLite stores metadata only, never full books.

**Cover Strategy:** Prefer a separate public cover file referenced by `cover.driveFileId` in the catalog so the list never downloads an EPUB for presentation. Use the existing `cached_network_image` dependency for persistent resized cover caching after confirming required Drive headers, and cap cover/metadata extraction concurrency. Existing EPUB extraction remains a fallback for uncatalogued files and must not run for every visible card concurrently.

**Extension Search:** Existing extensions already support keyword/page calls through `getSearchManga`, but a missing `search` script silently returns an empty page and no capability model exists. Add explicit `SearchCapabilities` for keyword, author, genre, pagination, and available genres. Query selected extensions through their website/plugin rather than copying entire source catalogs into Drive SQLite. Unified search should cap concurrent extensions at 2, preserve each source's timeout/error independently, and never claim an exhaustive genre result when a source lacks genre support.

**Files To Modify After Approval:** `pubspec.yaml`, `lib/models/story.dart` only if shared identity fields are required, `lib/models/plugin_info.dart`, `lib/services/google_drive_service.dart`, `lib/services/api_service.dart`, `lib/services/plugin/vbook_engine_channel.dart`, `lib/screens/explore_screen.dart`, `lib/screens/source_browse_screen.dart`, and the native bridge only if the capability contract requires it.

**Phase A/B Files:** Phase A added `lib/models/search_index_story.dart`, `lib/services/database/database_service.dart`, `lib/services/database/search_index_migrations.dart`, `lib/services/search/search_text_normalizer.dart`, `lib/services/search/search_index_repository.dart`, and its repository test. Phase B adds `lib/models/drive_metadata.dart`, `lib/models/search_index_state.dart`, `lib/services/search/drive_catalog_parser.dart`, `lib/services/search/drive_metadata_indexer.dart`, three focused test files, and scoped metadata changes in `lib/services/google_drive_service.dart`/the repository. No private Drive ID, credential, or production catalog fixture was added.

**Migration:** Schema v1 creation is implemented without deleting or changing SharedPreferences. There was no pre-existing app-owned SQLite schema to migrate. Revision comparison and safe deleted-file reconciliation are implemented for coordinator-managed Drive records. Importing valid cached Drive/local metadata as `PARTIAL` and retaining old preference keys until a successful import remain deferred to Phase G.

**Risks:** Initial indexing can consume Drive quota/network, full EPUB parsing can cause memory/jank, shared catalog data can become stale, `%query%` LIKE scans can degrade at large scale, FTS availability varies, and bad deletion reconciliation can hide valid stories. Each risk requires explicit progress/error state, bounded concurrency, resumable jobs, and tests before replacing current search.

**Implementation Phases:** `SEARCH-001-A` database/schema/repository and `B` Drive metadata indexer/catalog import are implemented and locally verified. `C` title/author/genre queries, `D` filter/index-progress UI, `E` extension capabilities, `F` unified search, and `G` migration/runtime/quota/performance work are not started. Stop here for review before Phase C.

**Required Tests:** Phase A's eight repository tests remain passing. Phase B adds twelve passing tests for versioned/legacy catalog validation, source mismatch, Drive revision fields, metadata-only downloads, stale catalog records, a 500-record index independent of Explore pages, partial/error state, unchanged/modified/deleted files, richer metadata preservation, and per-source single-flight. Finding item 400 through a user query, TXT/EPUB/PDF extraction, query/filter behavior, catalog runtime, extension capability mismatch, and extension timeout isolation remain for Phases C-G.

**Next Action:** Review `SEARCH-001-B`; then approve/continue `SEARCH-001-C`. Keep Explore pagination independent, and do not present SQLite results as complete until query/state UI and production scheduling are implemented.

### TTS-001 — Centralized TTS Service

**Priority:** P1

**Status:** `IMPLEMENTED` / `RUNTIME VERIFICATION PENDING`

**Problem:** Historical duplicate TTS instances could desynchronize playback and UI.

**Implemented:** Reader flows use `TtsService.instance`; Android TTS service visibility and 1000-character safety limit exist.

**Files:** `lib/services/tts_service.dart`, reader screens, `android/app/src/main/AndroidManifest.xml`.

**Verification:** Historical implementation report only; current Android runtime matrix is blank.

**Remaining:** Verify service binding, pause/resume/stop, app backgrounding, and chapter transitions on device.

**Next Action:** Include in the consolidated TTS runtime session.

### TTS-002 — Selection Player and Settings

**Priority:** P1

**Status:** `IMPLEMENTED` / `RUNTIME VERIFICATION PENDING`

**Implemented:** Selection playback, language/voice/engine controls, rate/pitch, timer, preview, and responsive player container exist. Narrow-layout widget tests exist.

**Verification:** Widget tests were not run for this dashboard. Voice/engine availability varies by device.

**Remaining:** Verify 320/360/393/412 widths, text scale 1.0/1.3/1.5, portrait/landscape, and callback correctness. Confirm profile settings are actually applied to `TtsService`.

**Risk:** Settings appear persisted but do not affect playback; preview can interfere with the active session.

**Next Action:** Run automated layout tests, then verify on Android with multiple TTS engines.

### TTS-003 — Smart Paragraph TTS

**Priority:** P1

**Status:** `IMPLEMENTED` / `RUNTIME VERIFICATION PENDING`

**Implemented:** Paragraph-first parsing, long-paragraph subchunks, paragraph navigation/highlight, auto-scroll, chapter callbacks, and player auto-show are present in source.

**Files:** `lib/services/tts_service.dart`, `lib/models/tts_paragraph.dart`, `lib/widgets/tts_player_container.dart`, `lib/screens/reading_screen.dart`, `lib/screens/chapter_reader_screen.dart`.

**Verification:** Source proves implementation, but no service/session/lifecycle regression suite exists. Background playback and stale completion callbacks remain NEED VERIFICATION.

**Remaining:** Bind completion to an utterance/session ID, verify preview isolation, apply/persist settings consistently, and clear chapter callbacks safely during disposal.

**Risk:** A stale completion or retained callback can advance the wrong chapter or access disposed reader state.

**Next Action:** Write lifecycle tests before adjusting playback behavior.

### COMMUNITY-001 — Realtime, Identity, and Read Policy

**Priority:** P1

**Status:** `PARTIAL`

**Problem:** Messages load as a latest-50 snapshot with manual refresh; no older-page navigation exists. Rules bind UID correctly but client-supplied display name/avatar are not tied to a trusted profile document. Public versus authenticated read remains a product decision.

**Files:** `lib/screens/community_screen.dart`, `lib/services/firebase_backend_service.dart`, `firestore.rules`, Firestore emulator tests.

**Implemented:** Verified-user create, admin-claim delete, text/field limits, server timestamp validation, and attachment rejection.

**Verification:** Rules tests exist; current tree was not run for this dashboard. Realtime/pagination are not implemented.

**Remaining:** Decide read policy and trusted identity behavior, then add snapshots/pagination if approved.

**Risk:** Visible identity spoofing and stale community content.

**Next Action:** Record the product decision before changing rules or UX.

### EXT-LIFE-001 — Complete Extension Lifecycle and Error Reporting

**Priority:** P1

**Status:** `PARTIAL`

**Problem:** The uninstall leak is fixed and core runtime-verified. Registry failures can still collapse into an empty list, and non-Android platforms are not clearly gated.

**Files:** `lib/services/extension_service.dart`, `lib/screens/extension_screen.dart`, `lib/services/plugin/vbook_engine_channel.dart`.

**Verification:** Real extension install/uninstall now closes the native source, removes preferences, and leaves the plugin root empty on Android 16. No restart persistence or all-registries-failed integration test exists.

**Remaining:** Verify restart persistence, preserve explicit all-registry failure details, and add platform guards.

**Risk:** Stale code/storage, misleading empty UI, and platform-specific silent failure.

**Next Action:** Add explicit all-registry failure state and Android platform gating without reopening installer path handling.

## P2 — Important Improvements

| Task | Status | Problem / Remaining | Main files |
|---|---|---|---|
| `PDF-PROGRESS-001` | `NOT STARTED` | Save and restore PDF page/progress/history | `pdf_reader_screen.dart` |
| `EPUB-RESUME-001` | `INVESTIGATING` | Progress is written; chapter/location restoration needs proof and completion | `epub_reader_screen.dart`, `api_service.dart` |
| `HOME-PROGRESS-001` | `NOT STARTED` | Zero-based chapter index can show chapter 0 as unread and never reach 100% | `home_screen.dart` |
| `READING-STATS-001` | `NOT STARTED` | Statistics are approximate snapshots and may be off by one chapter | `reading_stats_screen.dart` |
| `FILE-IO-001` | `INVESTIGATING` | EPUB/TXT import, parsing, and download scans can run synchronous work on the UI isolate | import/read/download services |
| `AMBIENT-001` | `PARTIAL` | State-only stub; no actual audio playback or active UI integration | `ambient_audio_service.dart` |
| `HANVIET-001` | `PARTIAL` | Minimal fixed replacement map, not a complete translator | `han_viet_translator_service.dart` |
| `EXT-PLATFORM-001` | `NOT STARTED` | Native extension engine is Android-only; platform guard/support policy is missing | MethodChannel and extension screens |
| `LEGACY-BACKEND-001` | `NOT STARTED` | Flutter does not use the legacy backend, while setup docs can imply otherwise | `backend/`, README/docs |

## Security

### Improved

- Local account password storage uses versioned PBKDF2-HMAC-SHA256 with a random per-account salt.
- Correct legacy local login migrates plaintext records and removes plaintext password data.
- Release signing has no fallback to debug signing and local keystore material is ignored.
- Firestore rules enforce authenticated/verified community writes, UID ownership, field limits, immutable messages, and admin custom-claim deletion.
- Community attachment creation is rejected and current UI is text-only.
- User-entered HTTP registry/ZIP URLs require validation and explicit confirmation; HTTPS does not add a prompt.
- Plugin installation now uses strict ID/path validation, bounded archive preflight, staging engine validation, atomic replacement with rollback, nested manifest metadata parsing, and no-follow install/uninstall cleanup. Core and cross-process failure-recovery paths are verified on physical Android.
- Extension calls now have a caller deadline, lifecycle/session invalidation, bounded host resources, typed cross-platform failures, and explicit unsupported-async errors. Native hard interruption and heap limits remain unavailable.
- No active Google API key, service-account private key, or signing password was found in the tracked source snapshot.

### Open

- `SEC-PLUGIN-001` is closed as `VERIFIED`; keep its security and two-process recovery tests as release regressions.
- `EXT-EXEC-001`: best-effort deadline and resource guards are implemented, but the bundled QuickJS Java API cannot hard-interrupt a CPU loop, cap the runtime heap, or execute pending Promise jobs.
- `AUTH-MIG-001`: local-to-Firebase account policy.
- Community display name/avatar trust and public versus authenticated read policy.
- Dynamic HTTP sources remain supported by product decision; HTTP provides neither confidentiality nor integrity.
- Historical commits contain an old Google API-key pattern. Rotation/restriction remains operationally important; never copy historical values back into source.

## Test Status

Current snapshot policy: historical claims are not treated as current-tree PASS. Older manual test plans remain local and are not tracked in DALN.

| Area | Static | Build | Runtime | Regression | Notes |
|---|---|---|---|---|---|
| App startup | PASS | PASS | PASS (PROCESS COLD) | PASS | Activity cold-start completion measured 2.482s on Android 16 |
| Google Drive | PASS | PASS | PASS (PAGE 15) | PASS (SCOPED) | Eleven scoped tests assert 15-item initial/load-more requests. Physical Android returned 15 items in 4.308s; paged/full-flow parity, real catalog, release certificate, and cover completion remain |
| Search index | PASS (PHASE A) | PASS | NOT WIRED / NOT TESTED | PASS (8 SCOPED) | SQLite schema/repository foundation passes locally; Drive indexer, cached-data import, SQL search, progress UI, and extension search are not started |
| Local EPUB | PASS | PASS | NOT TESTED | NOT TESTED | Import/read/resume runtime matrix pending |
| TXT | PASS | PASS | NOT TESTED | PARTIAL | Build passes; reader/TTS/progress runtime matrix pending |
| PDF | PASS | PASS | NOT TESTED | NOT TESTED | Page persistence missing |
| TTS | PASS | PASS | NOT TESTED | PARTIAL | Responsive widget tests pass; service lifecycle tests missing |
| Extension install | PASS | PASS | PASS (CROSS-PROCESS) | PASS | 20 installer tests, 2 default Android integration scenarios, and separate prepare/recover processes pass; ADB verified persisted journal state and complete rollback cleanup |
| Extension browse | PASS | PASS | NOT TESTED | PARTIAL | Five bridge contract tests pass; native Android timeout/runtime matrix pending |
| Online reader | PASS | PASS | NOT TESTED | NOT TESTED | Concurrency, progress, and cookie tests missing |
| Offline novel | PASS | PASS | NOT TESTED | NOT TESTED | Download/retry/export device verification pending |
| Offline comic | PASS | PASS | NOT TESTED | NOT TESTED | Core offline behavior not implemented |
| Firebase auth | PASS | PASS | PASS (INIT/RESTORE/TOKEN) | PARTIAL | Native no-define config verified on Android 16; fresh login/logout and stale-session matrix remain |
| Cloud sync | PASS | PASS | PASS (STARTUP SMOKE) | PARTIAL | Repeated upsert and malformed-record coverage pass; cross-device progress reconciliation, deterministic IDs, and direct cloud-state verification remain |
| Bookmarks | PASS | PASS | NOT TESTED | NOT TESTED | Offline delete/reconnect coverage missing |
| Community | PASS | PASS | NOT TESTED | PARTIAL | Existing rules/UI tests pass; realtime/pagination absent |
| Release build | PASS | PENDING | NOT TESTED | NOT TESTED | Debug APK passes; real release credentials/build not exercised |

### Last Verification

- 2026-09-03 DALN checkpoint: formatter checked all 41 changed Dart files with 0 changes; `flutter analyze --no-pub` PASS with no issues in 14.3s; `flutter test --no-pub` 114/114 PASS; `flutter build apk --debug --no-pub` PASS in 7.0s; admin-claim script tests 3/3 PASS; Firestore rules 22/22 and attachment audit 4/4 PASS. The attachment command now starts its emulator itself, suppresses ambient `DEBUG` so Firebase CLI does not dump the process environment, and removes the Windows emulator listener it created. The rebuilt APK installed on physical device `23113RKC6C` and process-cold launch PASS in 3.498s with Firebase initialized. The first post-install debug launch reported skipped frames, so startup smoothness still needs profile/release measurement.
- 2026-09-03 SEARCH-001-A: added direct `sqflite 2.4.2+1`, test-only `sqflite_common_ffi 2.4.0+3`, `vbook_index.db` schema/migration v1, normalized metadata model, Vietnamese search normalizer, and transaction/batch repository. `flutter pub get` PASS with exactly three dependency-state changes (`sqflite` transitive-to-direct plus `sqflite_common_ffi`/`sqlite3`); `dart format` checked 6 files with 0 remaining changes; scoped SQLite tests 8/8 PASS; `flutter analyze --no-pub` PASS with no issues in 12.8s; `flutter test --no-pub` 102/102 PASS; `flutter build apk --debug --no-pub` PASS in 81.7s. Phase A is not wired into app startup or Drive, so Android database runtime is not claimed and no emulator was used.
- 2026-09-01 PERF-001/SEARCH-001 checkpoint: Explore page size changed from 20 to 15 for initial, refresh, and load-more requests. `dart format` completed for 2 files; 11/11 scoped Drive tests PASS; `flutter analyze --no-pub` PASS with no issues in 53.5s; `flutter test --no-pub` 94/94 PASS; `flutter build apk --debug --no-pub` PASS in 15.9s; ADB install PASS. Physical Android Drive returned 15 items in 4.308s and Explore committed them in 4.421s. Runtime then logged an EPUB cover fallback rejected above the 150 MiB limit. SEARCH-001 persistence/index/extension design is recorded as `PLAN READY`; no database, JSON file, dependency, indexer, or search UI code was added.
- 2026-09-01 SEC-PLUGIN-001 cross-process closure: physical device `23113RKC6C`/Android 16 (API 36) ran separate `flutter drive` prepare/recover invocations with `--keep-app-running`. Prepare PASS in PID 29659; ADB confirmed the fixture marker plus `.transaction-*` and `.backup-*`; `am force-stop` removed the process; recover PASS in PID 29919 and restored version 1 while deleting version 2, journal, backup, marker, and sandbox. `dart format` checked 2 files with 0 changes; installer tests 20/20 PASS; `flutter analyze --no-pub` PASS with no issues in 12.1s; `flutter test --no-pub` 94/94 PASS; `flutter build apk --debug --no-pub` PASS in 30.0s. The normal APK reinstalled through ADB and cold-launched successfully in 2.390s. No emulator was used for the successful run.
- 2026-08-28 PERF-001/Drive page size: Explore now uses one `20`-item constant for initial load, refresh, and load-more instead of mixing 20 initially with 50 on continuation. Widget coverage asserts both initial and continuation request sizes. `dart format` completed for the two scoped files; 11/11 targeted Drive tests and 94/94 full Flutter tests passed; `flutter analyze --no-pub` passed with no issues in 128.8s; `flutter build apk --debug --no-pub` passed in 53.4s. Android runtime was not rerun because ADB reported no connected device.
- 2026-08-28 PERF-001/Drive read-only checkpoint: local `.env` configuration is present and ignored, all generated Android Drive-key resources are non-empty, and the current debug APK is `com.vbook.reader` signed by the expected debug certificate. A sanitized request using that Android identity returned HTTP 200 for all six configured roots; a bounded traversal found 51 EPUB files in 26 requests with zero API errors. The 11 scoped Drive configuration/pagination/Explore race tests passed. The connected phone only had legacy package `com.vbook.app` installed, not the current package; ADB disconnected before a current-APK runtime rerun. No source code changed.
- 2026-08-27 SEC-PLUGIN-001 interruption recovery: added a bounded versioned append-only journal and startup recovery keyed to canonical persisted plugin state. `dart format` PASS (final run: 1 file, 0 changed); targeted installer tests 20/20 PASS; default Android integration harness 2/2 PASS on `23113RKC6C`/Android 16, including real native staging load, injected final-load failure, rollback, and previous-source reload; final `flutter analyze --no-pub` PASS with no issues in 55.9s; `flutter test --no-pub` 94/94 PASS; `flutter build apk --debug --no-pub` PASS in 21.7s. The added two-process `prepare`/`recover` mode analyzes clean but was NOT RUN: MIUI rejected both installs with `INSTALL_FAILED_USER_RESTRICTED` while the device was locked, before app launch or fixture creation.
- 2026-08-27 SEC-PLUGIN-001 lifecycle/runtime: direct ZIP nested metadata and uninstall filesystem/native cleanup fixed. `dart format` PASS; targeted installer tests 17/17 PASS; `flutter analyze --no-pub` PASS with no issues in 22.7s; `flutter test --no-pub` 91/91 PASS; `flutter build apk --debug --no-pub` PASS in 75.1s; APK install PASS. On device `23113RKC6C`/Android 16, two HTTPS registries loaded 54 entries; registry install, direct URL install, MIUI local ZIP install, same-target replacement, native staging/final load, visible malformed-ZIP failure, and uninstall cleanup PASS. Plugin root was empty after failed install/uninstall and no transaction directories remained. Interrupted-process and injected final-load rollback remain pending.
- 2026-08-26 CLOUD-SYNC-001 library upsert: production payload no longer rewrites immutable `createdAt`; malformed cloud records are skipped per document. Firestore emulator 22/22 PASS; targeted Dart tests 3/3 PASS; `dart format` PASS; `flutter analyze --no-pub` PASS with no issues in 139.1s; `flutter test --no-pub` 89/89 PASS; `flutter build apk --debug --no-pub` PASS in 54.5s. Rebuilt APK install/startup PASS on device `23113RKC6C`/Android 16 with Firebase initialized and zero permission, library-fetch, or pending-sync errors. Direct cloud document and multi-device conflict verification remain pending.
- 2026-08-26 PERF-001 Explore refresh single-flight: the rebuilt debug APK installed and process-cold launched in 3.231s on device `23113RKC6C`/Android 16. Explore loaded 50 stories in 7.075s (Drive 6.994s). Four refresh taps 220 ms apart produced one refresh start, one Drive start/completion, one Explore completion in 5.778s, maximum active requests 3/3, zero page errors, and 50 visible stories. `dart format` PASS; scoped Drive tests 11/11 PASS; `flutter analyze --no-pub` PASS with no issues; `flutter test --no-pub` 86/86 PASS; `flutter build apk --debug --no-pub` PASS; APK install/runtime smoke PASS.
- 2026-08-26 PERF-001 Drive batching/limiter: baseline first page 17.655s with all requests sequential at 1/3. Ordered three-cursor batching reduced final first-page Drive time to 6.163s and next-page time to 4.049s on device `23113RKC6C`/Android 16; Explore displayed 100 stories without config/403/page errors. A runtime contention check found and then verified the fix for a transient 4/3 limiter race. Final four-refresh run completed four scans, accepted only the newest response, had no page error, and never exceeded 3/3; accepted result took 20.475s because stale scans are not canceled. `dart format` PASS; scoped Drive tests 11/11 PASS; `flutter analyze --no-pub` PASS with no issues; `flutter test --no-pub` 86/86 PASS; `flutter build apk --debug --no-pub` PASS; APK install and production-path smoke PASS.
- 2026-08-25 PERF-001 final local-debug verification: process-cold activity launch PASS in 2.482s on device `23113RKC6C`/Android 16; cold Explore first page returned 50 items in 15.091s (Drive 14.946s). Four rapid refreshes produced four Drive completions, one accepted Explore completion, 50 visible stories, and no config/403/page error. Deterministic Explore race widget tests passed 2/2. `dart format` completed for both edited files; `flutter analyze --no-pub` PASS; `flutter test --no-pub` 84/84 PASS; `flutter build apk --debug --no-pub` PASS; rebuilt APK install and 50-story production-path smoke PASS. A true ADB load-more/refresh overlap was not achieved and is not claimed as runtime evidence.
- 2026-08-25 PERF-001/Drive: sanitized Google API probe PASS (HTTP 200) with package `com.vbook.reader` and the current debug SHA-1; targeted tests 7/7 PASS; `flutter analyze --no-pub` PASS; `flutter test --no-pub` 82/82 PASS; no-dart-define debug APK build/install PASS. Device `23113RKC6C`/Android 16 loaded 50 stories in 15.675s, then 50 more in 8.399s; Explore displayed 100 with no key/config/403/load-more error, and captured logs did not contain the configured key. After catalog/race hardening, the rebuilt APK installed and displayed 50 stories without a Drive error; rapid refresh was not reliably injectable through ADB.
- 2026-08-25 FIREBASE-SESSION-001 runtime: no-dart-define APK install PASS on `23113RKC6C`/Android 16; Firebase initialization PASS; persisted Firebase Auth session restoration PASS; forced ID-token/admin-claim refresh PASS; no API-key, network, token, or config error observed. Fresh logout/login was not run. Firestore library sync separately failed with `PERMISSION_DENIED`.
- 2026-08-24 FIREBASE-SESSION-001 implementation: `app:processDebugResources` PASS from the Android Gradle root; five generated resources PASS; `flutter analyze --no-pub` PASS; `flutter test --no-pub` 78/78 PASS; no-dart-define debug APK build PASS; APK resource-table verification PASS. Installation was not run because the device disconnected.
- 2026-08-24 FIREBASE-SESSION-001: Android 16 startup reproduced missing `FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_MESSAGING_SENDER_ID`, and `FIREBASE_PROJECT_ID`; default native Firebase options were also unavailable. Login was disabled before any Firebase Auth request.
- 2026-08-24 EXT-EXEC-001: Kotlin debug compilation PASS, five targeted bridge tests PASS, `flutter analyze --no-pub` PASS with no issues, `flutter test --no-pub` 78/78 PASS, and `flutter build apk --debug --no-pub` PASS.
- 2026-08-24 SEC-PLUGIN-001: `flutter analyze --no-pub` PASS, targeted installer tests 15/15 PASS, `flutter test --no-pub` 73/73 PASS, and `flutter build apk --debug --no-pub` PASS.
- Physical Android core install/uninstall runtime now passes. The real `123ds` browse call reached the native engine but the remote website returned a typed network failure; this does not verify source compatibility. `plugin_test.dart` now uses a temporary plugin root and verifies actual visible-directory filtering without invoking an unavailable native `path_provider` channel.
- Before any status is promoted to `VERIFIED`, record the exact command/device, date, result, and relevant environment in this file.

## Current Repository Checkpoint

`DALN CHECKPOINT — INCLUDED IN THIS COMMIT`

- The accumulated Flutter, Android, Firebase, Drive, extension, download, and SEARCH-001-A/B changes are included with their automated tests.
- The legacy Python/SQLite backend, old detailed documents, `scratch/test_drive.dart`, and root `test_plugin.dart` are removed from Git tracking only. Their local copies remain intact and are ignored.
- README is intentionally reduced to the app description and technology list.
- No active Google API key, service-account private key, signing password, `.env`, keystore, APK, build output, or dependency cache is included.
- SEARCH-001-C remains the next implementation phase; this checkpoint does not wire the Phase B indexer into production startup or Explore.

## Next Task Queue

### Current Sprint

| Order | Task | Priority | Status | Depends On |
|---:|---|---|---|---|
| 1 | `PROGRESS-001` — Create central progress dashboard | P3 | IMPLEMENTED | None |
| 2 | `SEC-PLUGIN-001` — Plugin installer security | P0 | VERIFIED | Complete |
| 3 | `SEARCH-001` — Drive/SQLite/extension search | P1 | PHASE A/B IMPLEMENTED / LOCAL VERIFIED | Review checkpoint before Phase C |
| 4 | `EXT-EXEC-001` — Extension execution hardening | P0 | PARTIAL / RUNTIME VERIFICATION PENDING | Deferred while SEARCH-001 is the selected task |
| 5 | `FIREBASE-SESSION-001` — Reproducible Firebase login configuration | P1 | PARTIAL / CONFIGURATION VERIFIED | User-controlled fresh login/logout and stale-session policy |
| 6 | Confirm Phase 2 acceptance before Phase 3 | P0 | NOT STARTED | EXT-EXEC-001 runtime result/decision |

### Backlog Priority

| Order | Task | Priority | Status | Depends On |
|---:|---|---|---|---|
| 1 | `FIREBASE-SESSION-001` — Finish fresh login/logout and stale-session behavior | P1 | PARTIAL / CONFIG VERIFIED | User-controlled credential cycle and behavior decision |
| 2 | `EXT-EXEC-001` — Android runtime verification and runtime architecture decision | P0 | PARTIAL | Timeout/cancellation/failure/source-reload matrix |
| 3 | `SEC-PLUGIN-001` — Final Android process-relaunch evidence | P0 | VERIFIED | Complete on physical Android |
| 4 | `AUTH-MIG-001` — Local/Firebase account policy | P0 | BLOCKED | Product decision |
| 5 | `OFFLINE-COMIC-001` — Offline comic correctness | P0 | NOT STARTED | Storage/migration design |
| 6 | `ONLINE-READER-001` — Progress and request concurrency | P1 | PARTIAL | EXT-EXEC-001 runtime decision |
| 7 | `CLOUD-SYNC-001` and `CLOUD-DELETE-001` | P1 | PARTIAL / UPSERT FIXED | Conflict, identity, and delete policy |
| 8 | `PERF-001` — Drive stability and runtime verification | P1 | PARTIAL / LOCAL DEBUG PERFORMANCE VERIFIED | Live catalog, release certificate, and metadata policy review |
| 9 | `TTS-001/002/003` — Lifecycle/settings verification | P1 | VERIFY PENDING | Device/runtime matrix |
| 10 | Expand automated regression tests | P1 | NOT STARTED | Stable behavior contracts |
| 11 | Add CI gates for Flutter/npm/emulator/build | P2 | NOT STARTED | Reliable local commands |
| 12 | Documentation and legacy backend cleanup | P2 | VERIFIED | Removed from Git tracking; local copies preserved and ignored |

Do not silently replace an active task with this queue. Once a task is selected, move it into `ACTIVE TASK` and keep its prior status/history.

## Release Readiness

| Area | Status | Blocking reason |
|---|---|---|
| Core Reading | PARTIAL | PDF/EPUB resume and progress correctness need verification |
| Online Reading | NOT READY | Error fidelity, progress, concurrency, and cookies |
| Extensions | NOT READY | Installer lifecycle and cross-process recovery are verified; execution isolation still lacks native hard interrupt, heap cap, and Promise-job support |
| Offline Download | NOT READY | Comics are not truly offline and storage identity can collide |
| Authentication | NOT READY | Android config/session/token refresh pass, but fresh login/logout, stale-session behavior, and local-to-Firebase migration remain incomplete |
| Cloud Sync | NOT READY | Cross-device conflict policy, deterministic identity, delete reliability, and direct cloud-state verification |
| TTS | PARTIAL | Implementation exists; lifecycle/device verification pending |
| Google Drive | PARTIAL | Native key delivery, page-15 listing, bounded concurrency, cold start, and refresh single-flight pass on Android; SQLite foundation plus Drive metadata/catalog indexing pass local tests, while production scheduling, saved-folder parity, cover latency, and release-certificate restriction remain |
| Community | PARTIAL | Core rules hardened; trust/read policy and realtime pending |
| Security | NOT READY | Plugin installer and cross-process recovery are verified; full extension runtime isolation remains an open P0 issue |
| Performance | PARTIAL | Page-size-15 listing measured 4.308s on Android; the new metadata scanner does not download book content, but current Explore cover fallback can still download full EPUB files until later UI/cache integration |
| Automated Testing | NOT READY | Large core flows lack regression/integration coverage |
| Documentation | PARTIAL | Central dashboard exists; older docs contain stale claims |

The application must not be declared release-ready while any P0 item remains open or while the current dirty tree lacks a clean verification baseline.

## Status History

| Date | Task | Change | Evidence |
|---|---|---|---|
| 2026-09-03 | `DALN-CHECKPOINT-001` | Verified and committed the accumulated app snapshot; fixed false-positive plugin testing and repeatable Firestore emulator execution; removed legacy/non-app files from Git tracking while preserving local copies | Formatter 41/41, analyzer, 114/114 Flutter tests, 3/3 admin tests, 22/22 rules tests, 4/4 attachment tests, debug APK build, ADB install, and cold launch PASS |
| 2026-09-03 | `SEARCH-001-B` | Added bounded Drive metadata/catalog snapshot import, revision-aware batched SQLite coordinator, explicit index state, run/job lifecycle, single-flight, and complete-traversal deletion reconciliation; stopped before SQL query/UI integration | 20/20 scoped and 114/114 full tests PASS; analyzer PASS in 14.4s; debug APK PASS in 8.8s; no Android runtime claim because production scheduling is intentionally unwired |
| 2026-09-03 | `SEARCH-001-A` | Added isolated SQLite metadata schema v1, versioned migration service, normalized story/author/genre repository, and compatible direct/test dependencies; stopped before Drive integration | 8/8 scoped and 102/102 full tests, analyzer, and debug APK build PASS; no Android runtime claim because production call flow is not wired |
| 2026-09-01 | `PERF-001` / `SEARCH-001` | Reduced Explore pages to 15 and completed JSON/SQLite/extension search design without implementing SEARCH code | 11/11 scoped and 94/94 full tests, analyzer, debug APK, ADB install PASS; 15 items in 4.308s; oversized EPUB cover fallback reproduced |
| 2026-09-01 | `SEC-PLUGIN-001` | Closed the final true process-relaunch recovery gap on physical Android | Separate prepare/recover PIDs 29659/29919 PASS; ADB journal/backup and cleanup checks PASS; 20/20 targeted, 94/94 full tests, analyzer, debug APK, reinstall, and cold launch PASS |
| 2026-08-24 | `PROGRESS-001` | Created central dashboard; no source code changed | Code/docs/diff static audit; no test/build/runtime run |
| 2026-08-24 | `SEC-PLUGIN-001` | Hardened all plugin install paths with bounded preflight, staging validation, atomic replacement, rollback, and safe cleanup | Analyzer PASS; 15/15 targeted and 73/73 full tests PASS; debug APK PASS; Android runtime pending |
| 2026-08-24 | `EXT-EXEC-001` | Added best-effort execution deadlines/resource bounds, engine-session invalidation, typed native/Dart failures, and explicit Promise rejection | Kotlin compile PASS; 5/5 targeted and 78/78 full tests PASS; analyzer/debug APK PASS; Android runtime and hard-isolation decision pending |
| 2026-08-24 | `FIREBASE-SESSION-001` | Diagnosed why login disappears across run/build paths; no source behavior changed | Android 16 startup FAIL (configuration): dart-defines absent and native Firebase options unavailable; local `.env` validated without exposing values |
| 2026-08-24 | `FIREBASE-SESSION-001` | Added automatic Android native Firebase resources and truthful initialization state/logging | Gradle resources, analyzer, 78/78 tests, no-define debug APK, and APK resource inspection PASS; device install/login pending after ADB disconnect |
| 2026-08-25 | `FIREBASE-SESSION-001` | Runtime-verified no-define Android configuration, persisted Auth session restoration, and forced token/admin-claim refresh | APK install/init/session/token PASS on Android 16; fresh logout/login intentionally not run; Firestore library permission failure assigned to `CLOUD-SYNC-001` |
| 2026-08-25 | `PERF-001` | Added deterministic Explore stale-response tests and completed local debug cold-start/rapid-refresh verification | Cold launch 2.482s; rapid refresh accepted newest result only; 9/9 scoped Drive tests, analyzer, 84/84 full tests, debug APK, install, and 50-story smoke PASS |
| 2026-08-26 | `PERF-001` | Batched folder traversal and fixed queued-permit transfer so Drive uses but never exceeds three concurrent requests | First page 17.655s to 6.163s; page two 8.399s to 4.049s; 11/11 scoped and 86/86 full tests, analyzer, debug APK, install, 100-story and rapid-refresh runtime checks PASS |
| 2026-08-26 | `PERF-001` | Added Explore initial/refresh single-flight and disabled duplicate refresh input while preserving refresh-during-load-more invalidation | Four rapid taps produced one 5.778s Drive traversal, max 3/3, zero page errors, 50 visible stories; 11/11 scoped and 86/86 full tests, analyzer, debug APK, install/runtime PASS |
| 2026-08-26 | `CLOUD-SYNC-001` | Stopped full library merges from rewriting `createdAt` and made malformed cloud records non-fatal | Emulator 22/22, targeted 3/3 and full Flutter 89/89 PASS; analyzer/debug APK/install PASS; restored-session startup sync had zero permission/library errors |
| 2026-08-27 | `SEC-PLUGIN-001` | Fixed nested manual-ZIP metadata identity and made uninstall close native state plus safely delete plugin files before clearing preferences | 17/17 targeted and 91/91 full tests, analyzer/debug APK/install PASS; registry/direct/local install, replacement, malformed ZIP cleanup, and uninstall runtime PASS on Android 16 |
| 2026-08-27 | `SEC-PLUGIN-001` | Added durable versioned install journal, startup recovery, rollback-resume markers, and Android failure-injection harness | 20/20 targeted and 94/94 full tests PASS; analyzer/debug APK PASS; default Android integration 2/2 PASS; true two-process mode blocked before launch by locked-device MIUI install policy |
