import 'package:flutter/foundation.dart';

import '../../models/search_index_page.dart';
import '../../models/search_index_state.dart';
import '../database/database_service.dart';
import '../google_drive_service.dart';
import 'drive_metadata_indexer.dart';
import 'search_index_repository.dart';

typedef DriveFolderSynchronizer =
    Future<DriveMetadataIndexResult> Function(
      String folderInput, {
      DriveIndexProgressCallback? onProgress,
      bool retryFailedExtractions,
    });
typedef DriveSearchClock = DateTime Function();

class DriveSearchIndexState {
  const DriveSearchIndexState({
    required this.status,
    required this.indexedCount,
    required this.totalCount,
    required this.completedSources,
    required this.totalSources,
    this.lastIndexedAt,
    this.errorCode,
    this.dataRevision = 0,
  });

  const DriveSearchIndexState.notStarted()
    : status = SearchIndexStatus.notStarted,
      indexedCount = 0,
      totalCount = null,
      completedSources = 0,
      totalSources = 0,
      lastIndexedAt = null,
      errorCode = null,
      dataRevision = 0;

  final SearchIndexStatus status;
  final int indexedCount;
  final int? totalCount;
  final int completedSources;
  final int totalSources;
  final DateTime? lastIndexedAt;
  final String? errorCode;
  final int dataRevision;
}

abstract interface class DriveSearchGateway implements Listenable {
  DriveSearchIndexState get state;

  Future<void> restoreState(Iterable<String> folderInputs);

  Future<void> synchronize(
    Iterable<String> folderInputs, {
    bool force = false,
    bool retryFailedExtractions = false,
  });

  Future<SearchIndexPage> search({
    String query = '',
    Iterable<String> authors = const [],
    Iterable<String> genres = const [],
    int limit = SearchIndexRepository.defaultSearchPageSize,
    int offset = 0,
  });

  Future<List<String>> loadAuthors();

  Future<List<String>> loadGenres();
}

class DriveSearchCoordinator extends ChangeNotifier
    implements DriveSearchGateway {
  DriveSearchCoordinator({
    required SearchIndexRepository repository,
    required DriveFolderSynchronizer synchronizeFolder,
    DriveSearchClock? clock,
    this.refreshInterval = const Duration(minutes: 30),
  }) : _repository = repository,
       _synchronizeFolder = synchronizeFolder,
       _clock = clock ?? DateTime.now;

  static final DriveSearchCoordinator instance = DriveSearchCoordinator(
    repository: SearchIndexRepository(DatabaseService.instance),
    synchronizeFolder: DriveMetadataIndexer.instance.synchronizeFolder,
  );

  final SearchIndexRepository _repository;
  final DriveFolderSynchronizer _synchronizeFolder;
  final DriveSearchClock _clock;
  final Duration refreshInterval;

  Map<String, SearchIndexState> _sourceStates = {};
  DriveSearchIndexState _state = const DriveSearchIndexState.notStarted();
  Future<void>? _activeSync;
  Set<String> _runningSourceIds = const {};
  bool _runningForce = false;
  final Set<String> _pendingSourceIds = {};
  bool _pendingForce = false;
  bool _runningRetryFailedExtractions = false;
  bool _pendingRetryFailedExtractions = false;
  int _dataRevision = 0;
  bool _disposed = false;

  @override
  DriveSearchIndexState get state => _state;

  @override
  Future<void> restoreState(Iterable<String> folderInputs) async {
    final sourceIds = _sourceIds(folderInputs);
    final restored = <String, SearchIndexState>{};
    for (final sourceId in sourceIds) {
      restored[sourceId] = await _repository.readIndexState(
        sourceType: DriveMetadataIndexer.sourceType,
        sourceId: sourceId,
      );
    }
    _sourceStates = restored;
    _setState(
      _aggregateState(
        sourceIds: sourceIds,
        sourceStates: restored,
        completedSources: restored.values
            .where(
              (state) =>
                  state.status != SearchIndexStatus.notStarted &&
                  state.status != SearchIndexStatus.indexing,
            )
            .length,
      ),
    );
  }

  @override
  Future<void> synchronize(
    Iterable<String> folderInputs, {
    bool force = false,
    bool retryFailedExtractions = false,
  }) {
    force = force || retryFailedExtractions;
    final requestedSourceIds = _sourceIds(folderInputs).toSet();
    final activeSync = _activeSync;
    if (activeSync != null) {
      final includesNewSource = !requestedSourceIds.every(
        _runningSourceIds.contains,
      );
      if (includesNewSource ||
          (force && !_runningForce) ||
          (retryFailedExtractions && !_runningRetryFailedExtractions)) {
        _pendingSourceIds.addAll(requestedSourceIds);
        _pendingForce = _pendingForce || force;
        _pendingRetryFailedExtractions =
            _pendingRetryFailedExtractions || retryFailedExtractions;
      }
      return activeSync;
    }

    late final Future<void> sync;
    sync =
        _runSynchronizationLoop(
          requestedSourceIds,
          force: force,
          retryFailedExtractions: retryFailedExtractions,
        ).whenComplete(() {
          if (identical(_activeSync, sync)) {
            _activeSync = null;
            _runningSourceIds = const {};
            _runningForce = false;
            _pendingSourceIds.clear();
            _pendingForce = false;
            _runningRetryFailedExtractions = false;
            _pendingRetryFailedExtractions = false;
          }
        });
    _activeSync = sync;
    return sync;
  }

  Future<void> _runSynchronizationLoop(
    Set<String> initialSourceIds, {
    required bool force,
    required bool retryFailedExtractions,
  }) async {
    var sourceIds = initialSourceIds;
    var currentForce = force;
    var currentRetry = retryFailedExtractions;
    while (true) {
      _runningSourceIds = Set.unmodifiable(sourceIds);
      _runningForce = currentForce;
      _runningRetryFailedExtractions = currentRetry;
      await _synchronize(
        sourceIds,
        force: currentForce,
        retryFailedExtractions: currentRetry,
      );

      if (_pendingSourceIds.isEmpty) return;
      sourceIds = Set.of(_pendingSourceIds);
      currentForce = _pendingForce;
      currentRetry = _pendingRetryFailedExtractions;
      _pendingSourceIds.clear();
      _pendingForce = false;
      _pendingRetryFailedExtractions = false;
    }
  }

  Future<void> _synchronize(
    Iterable<String> folderInputs, {
    required bool force,
    required bool retryFailedExtractions,
  }) async {
    final sourceIds = _sourceIds(folderInputs);
    if (sourceIds.isEmpty) {
      _sourceStates = {};
      _setState(const DriveSearchIndexState.notStarted());
      return;
    }

    final sourceStates = <String, SearchIndexState>{};
    for (final sourceId in sourceIds) {
      sourceStates[sourceId] =
          _sourceStates[sourceId] ??
          await _repository.readIndexState(
            sourceType: DriveMetadataIndexer.sourceType,
            sourceId: sourceId,
          );
    }
    _sourceStates = sourceStates;

    final now = _clock().toUtc();
    final dueSourceIds = sourceIds
        .where((sourceId) {
          if (force) return true;
          final sourceState = sourceStates[sourceId]!;
          if (sourceState.status == SearchIndexStatus.notStarted ||
              sourceState.status == SearchIndexStatus.error ||
              sourceState.status == SearchIndexStatus.indexing) {
            return true;
          }
          final lastIndexedAt = sourceState.lastIndexedAt;
          return lastIndexedAt == null ||
              now.difference(lastIndexedAt.toUtc()) >= refreshInterval;
        })
        .toList(growable: false);

    if (dueSourceIds.isEmpty) {
      _setState(
        _aggregateState(
          sourceIds: sourceIds,
          sourceStates: sourceStates,
          completedSources: sourceIds.length,
        ),
      );
      return;
    }

    var completedSources = sourceIds.length - dueSourceIds.length;
    _setState(
      _aggregateState(
        sourceIds: sourceIds,
        sourceStates: sourceStates,
        completedSources: completedSources,
        isSynchronizing: true,
      ),
    );

    for (final sourceId in dueSourceIds) {
      final previous = sourceStates[sourceId]!;
      var acceptingProgress = true;
      try {
        final result = await _synchronizeFolder(
          sourceId,
          retryFailedExtractions: retryFailedExtractions,
          onProgress: (progress) {
            if (!acceptingProgress || _disposed) return;
            if (progress.metadataChanged) _dataRevision++;
            sourceStates[sourceId] = SearchIndexState(
              status: SearchIndexStatus.indexing,
              indexedCount: progress.indexedCount,
              totalCount: progress.totalCount,
              lastIndexedAt: previous.lastIndexedAt,
            );
            _sourceStates = Map.unmodifiable(sourceStates);
            _setState(
              _aggregateState(
                sourceIds: sourceIds,
                sourceStates: sourceStates,
                completedSources: completedSources,
                isSynchronizing: true,
              ),
            );
          },
        );
        sourceStates[sourceId] = SearchIndexState(
          status: switch (result.status) {
            SearchIndexRunStatus.indexing => SearchIndexStatus.indexing,
            SearchIndexRunStatus.ready => SearchIndexStatus.ready,
            SearchIndexRunStatus.partial => SearchIndexStatus.partial,
            SearchIndexRunStatus.error => SearchIndexStatus.error,
          },
          indexedCount: result.indexedCount,
          totalCount: result.totalCount,
          lastIndexedAt: _clock().toUtc(),
          errorCode: result.errorCode,
        );
      } catch (_) {
        final retained = sourceStates[sourceId]!;
        sourceStates[sourceId] = SearchIndexState(
          status: SearchIndexStatus.error,
          indexedCount: retained.indexedCount,
          totalCount: retained.totalCount,
          lastIndexedAt: previous.lastIndexedAt,
          errorCode: 'source_sync_failed',
        );
      } finally {
        acceptingProgress = false;
      }
      completedSources++;
      _sourceStates = Map.unmodifiable(sourceStates);
      _setState(
        _aggregateState(
          sourceIds: sourceIds,
          sourceStates: sourceStates,
          completedSources: completedSources,
          isSynchronizing: completedSources < sourceIds.length,
        ),
      );
    }
  }

  @override
  Future<SearchIndexPage> search({
    String query = '',
    Iterable<String> authors = const [],
    Iterable<String> genres = const [],
    int limit = SearchIndexRepository.defaultSearchPageSize,
    int offset = 0,
  }) {
    return _repository.searchByKeyword(
      query: query,
      authors: authors,
      genres: genres,
      sourceType: DriveMetadataIndexer.sourceType,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<List<String>> loadAuthors() {
    return _repository.listAuthors(sourceType: DriveMetadataIndexer.sourceType);
  }

  @override
  Future<List<String>> loadGenres() {
    return _repository.listGenres(sourceType: DriveMetadataIndexer.sourceType);
  }

  void _setState(DriveSearchIndexState nextState) {
    _state = nextState;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static List<String> _sourceIds(Iterable<String> folderInputs) {
    return {
      for (final input in folderInputs)
        if (GoogleDriveService.extractFolderId(input) case final String id)
          if (id.trim().isNotEmpty) id.trim(),
    }.toList(growable: false);
  }

  DriveSearchIndexState _aggregateState({
    required List<String> sourceIds,
    required Map<String, SearchIndexState> sourceStates,
    required int completedSources,
    bool isSynchronizing = false,
  }) {
    if (sourceIds.isEmpty) return const DriveSearchIndexState.notStarted();

    final states = [
      for (final sourceId in sourceIds)
        sourceStates[sourceId] ?? const SearchIndexState.notStarted(),
    ];
    final indexedCount = states.fold<int>(
      0,
      (total, state) => total + state.indexedCount,
    );
    final hasUnknownTotal = states.any((state) => state.totalCount == null);
    final totalCount = hasUnknownTotal
        ? null
        : states.fold<int>(0, (total, state) => total + state.totalCount!);
    DateTime? lastIndexedAt;
    for (final state in states) {
      final candidate = state.lastIndexedAt;
      if (candidate != null &&
          (lastIndexedAt == null || candidate.isAfter(lastIndexedAt))) {
        lastIndexedAt = candidate;
      }
    }

    final status = isSynchronizing
        ? SearchIndexStatus.indexing
        : states.every((state) => state.status == SearchIndexStatus.notStarted)
        ? SearchIndexStatus.notStarted
        : states.every((state) => state.status == SearchIndexStatus.ready)
        ? SearchIndexStatus.ready
        : states.every((state) => state.status == SearchIndexStatus.error)
        ? SearchIndexStatus.error
        : states.any((state) => state.status == SearchIndexStatus.indexing)
        ? SearchIndexStatus.indexing
        : SearchIndexStatus.partial;

    return DriveSearchIndexState(
      status: status,
      indexedCount: indexedCount,
      totalCount: totalCount,
      completedSources: completedSources.clamp(0, sourceIds.length),
      totalSources: sourceIds.length,
      lastIndexedAt: lastIndexedAt,
      dataRevision: _dataRevision,
      errorCode: states
          .map((state) => state.errorCode)
          .whereType<String>()
          .firstOrNull,
    );
  }
}
