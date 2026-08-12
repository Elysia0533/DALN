import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../models/tts_paragraph.dart';

enum TtsState { stopped, playing, paused }

/// Backward compatibility class mapping TtsChunk to paragraph subchunk
class TtsChunk {
  final String text;
  final int startOffset;
  final int endOffset;

  const TtsChunk({
    required this.text,
    required this.startOffset,
    required this.endOffset,
  });
}

class TtsService extends ChangeNotifier {
  static final TtsService instance = TtsService._internal();
  factory TtsService() => instance;

  final FlutterTts _flutterTts = FlutterTts();
  final Completer<void> _initCompleter = Completer<void>();

  TtsState _state = TtsState.stopped;
  TtsState get state => _state;
  bool get isPlaying => _state == TtsState.playing;
  bool get isPaused => _state == TtsState.paused;
  bool get isStopped => _state == TtsState.stopped;

  double _speechRate = 0.5; // FlutterTts standard rate (0.5 = 1.0x normal)
  double get speechRate => _speechRate;

  double _pitch = 1.0;
  double get pitch => _pitch;

  double _volume = 1.0;
  double get volume => _volume;

  String _currentLanguage = 'vi-VN';
  String get currentLanguage => _currentLanguage;

  List<String> _availableEngines = [];
  List<String> get availableEngines => _availableEngines;

  String? _currentEngine;
  String? get currentEngine => _currentEngine;

  List<dynamic> _availableVoices = [];
  List<dynamic> get availableVoices => _availableVoices;

  dynamic _currentVoice;
  dynamic get currentVoice => _currentVoice;

  String _audioStream = 'Media';
  String get audioStream => _audioStream;
  static const List<String> availableAudioStreams = [
    'Media',
    'Notification',
    'Alarm',
    'Voice Call',
    'System',
  ];

  Timer? _sleepTimer;
  int _timerMinutesRemaining = 0;
  int get timerMinutesRemaining => _timerMinutesRemaining;

  bool _stopAtEndOfChapter = false;
  bool get stopAtEndOfChapter => _stopAtEndOfChapter;

  /// Decoupled Event Callback for Chapter Navigation
  void Function(int nextChapterIndex)? onChapterChangeRequested;
  VoidCallback? _onChapterComplete;

  String? _currentStoryId;
  String? get currentStoryId => _currentStoryId;

  int? _currentChapterIndex;
  int? get currentChapterIndex => _currentChapterIndex;

  bool _isSelection = false;
  bool get isSelection => _isSelection;

  // Smart Paragraph & SubChunk Reading Tracking
  List<TtsParagraph> _paragraphs = [];
  List<TtsParagraph> get paragraphs => List.unmodifiable(_paragraphs);

  int _currentParagraphIndex = 0;
  int get currentParagraphIndex => _currentParagraphIndex;
  int get totalParagraphs => _paragraphs.length;

  int _currentSubChunkIndex = 0;
  int get currentSubChunkIndex => _currentSubChunkIndex;

  TtsParagraph? get currentParagraph =>
      _paragraphs.isNotEmpty && _currentParagraphIndex < _paragraphs.length
          ? _paragraphs[_currentParagraphIndex]
          : null;

  TtsSubChunk? get currentSubChunk {
    final p = currentParagraph;
    if (p != null && _currentSubChunkIndex < p.subChunks.length) {
      return p.subChunks[_currentSubChunkIndex];
    }
    return null;
  }

  // Backward compatibility getters
  List<TtsChunk> get chunks => _paragraphs
      .expand((p) => p.subChunks)
      .map((sc) => TtsChunk(
            text: sc.text,
            startOffset: sc.startOffset,
            endOffset: sc.endOffset,
          ))
      .toList();

  int get currentChunkIndex => _currentParagraphIndex;
  int get totalChunks => _paragraphs.length;
  String get currentChunkText => currentSubChunk?.text ?? '';

  int _speechSessionId = 0;
  int get speechSessionId => _speechSessionId;

  /// Safety limit for Android TextToSpeech input buffer (1000 chars)
  static const int _maxChunkLength = 1000;

  TtsService._internal() {
    _initTts();
  }

  Future<void> _initTts() async {
    try {
      await _flutterTts.awaitSpeakCompletion(true);

      try {
        final engines = await _flutterTts.getEngines;
        if (engines != null && engines is List) {
          _availableEngines = engines.map((e) => e.toString()).toList();
        }
        final defaultEng = await _flutterTts.getDefaultEngine;
        if (defaultEng != null && defaultEng is String) {
          _currentEngine = defaultEng;
        }
      } catch (e) {
        debugPrint('[TTS] Error fetching engines: $e');
      }

      await _configureLanguage();
      await _flutterTts.setSpeechRate(_speechRate);
      await _flutterTts.setPitch(_pitch);
      await _flutterTts.setVolume(_volume);

      _flutterTts.setStartHandler(() {
        _state = TtsState.playing;
        notifyListeners();
      });

      _flutterTts.setCompletionHandler(() async {
        if (_state == TtsState.stopped) return;
        final currentSession = _speechSessionId;

        final p = currentParagraph;
        if (p == null) {
          await stop();
          return;
        }

        // 1. Continuous SubChunk playback within current paragraph
        if (_currentSubChunkIndex < p.subChunks.length - 1) {
          _currentSubChunkIndex++;
          debugPrint(
            '[TTS] Subchunk completion. Moving to subchunk $_currentSubChunkIndex (Paragraph $_currentParagraphIndex)',
          );
          notifyListeners();
          final nextText = p.subChunks[_currentSubChunkIndex].text;
          await _safeSpeak(nextText, session: currentSession);
        }
        // 2. Transition to next paragraph in chapter
        else if (_currentParagraphIndex < _paragraphs.length - 1) {
          _currentParagraphIndex++;
          _currentSubChunkIndex = 0;
          debugPrint(
            '[TTS] Paragraph completion. Moving to paragraph $_currentParagraphIndex / ${_paragraphs.length}',
          );
          notifyListeners();
          final nextText = currentParagraph!.subChunks[0].text;
          await _safeSpeak(nextText, session: currentSession);
        }
        // 3. Chapter completion
        else {
          debugPrint('[TTS] Chapter completed: $_currentChapterIndex');
          _state = TtsState.stopped;
          notifyListeners();

          if (_stopAtEndOfChapter) {
            _stopAtEndOfChapter = false;
            await stop();
          } else if (!_isSelection && onChapterChangeRequested != null && _currentChapterIndex != null) {
            final nextChap = _currentChapterIndex! + 1;
            debugPrint('[TTS] Requesting next chapter: $nextChap');
            onChapterChangeRequested?.call(nextChap);
          } else if (!_isSelection && _onChapterComplete != null) {
            _onChapterComplete?.call();
          }
          _isSelection = false;
        }
      });

      _flutterTts.setErrorHandler((msg) {
        debugPrint('[TTS] Error: $msg');
        _state = TtsState.stopped;
        _isSelection = false;
        notifyListeners();
      });

      _flutterTts.setPauseHandler(() {
        _state = TtsState.paused;
        notifyListeners();
      });

      _flutterTts.setContinueHandler(() {
        _state = TtsState.playing;
        notifyListeners();
      });

      final voices = await _flutterTts.getVoices;
      if (voices != null) {
        _availableVoices = voices as List<dynamic>;
      }
    } catch (e) {
      debugPrint('[TTS] Exception during initialization: $e');
    } finally {
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }
    }
  }

  /// Parses text into TtsParagraph items with sentence-aware sub-chunking.
  /// Handles HTML tags (<p>, <div>, <br>) or fallback plain line breaks.
  static List<TtsParagraph> parseParagraphs(
    String text, {
    int maxChunkLength = _maxChunkLength,
    int? chapterIndex,
  }) {
    if (text.trim().isEmpty) return [];

    final rawBlocks = <String>[];
    // HTML tag aware split or plain line split
    if (text.contains('<p>') || text.contains('<div>') || text.contains('<br>')) {
      final cleaned = text
          .replaceAll(RegExp(r'</?(p|div|h[1-6]|br)\s*/?>', caseSensitive: false), '\n')
          .replaceAll(RegExp(r'<[^>]*>'), '');
      rawBlocks.addAll(cleaned.split(RegExp(r'\r?\n+')));
    } else {
      rawBlocks.addAll(text.split(RegExp(r'\r?\n+')));
    }

    final paragraphs = <TtsParagraph>[];
    int paragraphIdx = 0;

    for (final raw in rawBlocks) {
      final pText = raw.trim();
      if (pText.isEmpty) continue;

      final subChunks = <TtsSubChunk>[];
      if (pText.length <= maxChunkLength) {
        subChunks.add(TtsSubChunk(
          id: 'p${paragraphIdx}_s0',
          text: pText,
          startOffset: 0,
          endOffset: pText.length,
          paragraphIndex: paragraphIdx,
          subChunkIndex: 0,
        ));
      } else {
        // Split long paragraph into sentence-bounded subchunks
        int start = 0;
        int subIdx = 0;
        while (start < pText.length) {
          int end = (start + maxChunkLength).clamp(0, pText.length);
          if (end < pText.length) {
            int boundary = pText.lastIndexOf(RegExp(r'[.!?。！？]\s'), end);
            if (boundary > start + 150) {
              end = boundary + 1;
            } else {
              int space = pText.lastIndexOf(' ', end);
              if (space > start + 150) {
                end = space;
              }
            }
          }
          final chunkText = pText.substring(start, end).trim();
          if (chunkText.isNotEmpty) {
            subChunks.add(TtsSubChunk(
              id: 'p${paragraphIdx}_s$subIdx',
              text: chunkText,
              startOffset: start,
              endOffset: end,
              paragraphIndex: paragraphIdx,
              subChunkIndex: subIdx,
            ));
            subIdx++;
          }
          start = end;
        }
      }

      if (subChunks.isNotEmpty) {
        paragraphs.add(TtsParagraph(
          id: 'p_$paragraphIdx',
          text: pText,
          paragraphIndex: paragraphIdx,
          chapterIndex: chapterIndex,
          subChunks: subChunks,
        ));
        paragraphIdx++;
      }
    }

    return paragraphs;
  }

  Future<void> setEngine(String engine) async {
    try {
      await _flutterTts.setEngine(engine);
      _currentEngine = engine;
      await _configureLanguage();
      final voices = await _flutterTts.getVoices;
      if (voices != null) {
        _availableVoices = voices as List<dynamic>;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[TTS] setEngine error: $e');
    }
  }

  Future<void> setVoice(dynamic voice) async {
    try {
      if (voice is Map) {
        final name = voice['name']?.toString() ?? '';
        final locale = voice['locale']?.toString() ?? '';
        if (name.isNotEmpty && locale.isNotEmpty) {
          await _flutterTts.setVoice({'name': name, 'locale': locale});
        }
      }
      _currentVoice = voice;
      notifyListeners();
    } catch (e) {
      debugPrint('[TTS] setVoice error: $e');
    }
  }

  Future<void> setAudioStream(String stream) async {
    _audioStream = stream;
    notifyListeners();
  }

  Future<void> _configureLanguage() async {
    try {
      final rawLanguages = await _flutterTts.getLanguages;
      final languages = rawLanguages is Iterable
          ? rawLanguages.map((item) => item.toString()).toList()
          : const <String>[];

      final selected = languages.firstWhere(
        (lang) => lang.toLowerCase() == 'vi-vn' || lang.toLowerCase() == 'vi_vn',
        orElse: () => languages.firstWhere(
          (lang) => lang.toLowerCase().startsWith('vi'),
          orElse: () => languages.contains('en-US') ? 'en-US' : (languages.isNotEmpty ? languages.first : 'vi-VN'),
        ),
      );
      _currentLanguage = selected;
      await _flutterTts.setLanguage(_currentLanguage);
    } catch (_) {
      _currentLanguage = 'vi-VN';
      await _flutterTts.setLanguage('vi-VN');
    }
  }

  Future<void> _safeSpeak(String text, {int? session}) async {
    if (!_initCompleter.isCompleted) {
      await _initCompleter.future;
    }
    if (session != null && session != _speechSessionId) {
      debugPrint('[TTS] Session invalidated: $session (current: $_speechSessionId)');
      return;
    }

    try {
      final result = await _flutterTts.speak(text);
      if (result == 0) {
        await Future.delayed(const Duration(milliseconds: 250));
        if (session == null || session == _speechSessionId) {
          await _flutterTts.speak(text);
        }
      }
    } catch (e) {
      debugPrint('[TTS] speak error, retrying init: $e');
      await _configureLanguage();
      if (session == null || session == _speechSessionId) {
        await _flutterTts.speak(text);
      }
    }
  }

  /// Speak chapter starting from paragraph 0 or specific paragraph index
  Future<void> speak(
    String text, {
    String? storyId,
    int? chapterIndex,
    int startParagraphIndex = 0,
    VoidCallback? onChapterComplete,
  }) async {
    if (text.trim().isEmpty) return;

    debugPrint('[TTS] Start chapter: $chapterIndex, startParagraph: $startParagraphIndex');
    _isSelection = false;
    _currentStoryId = storyId;
    _currentChapterIndex = chapterIndex;
    _onChapterComplete = onChapterComplete;
    _paragraphs = parseParagraphs(text, chapterIndex: chapterIndex);

    if (_paragraphs.isEmpty) return;

    _currentParagraphIndex = startParagraphIndex.clamp(0, _paragraphs.length - 1);
    _currentSubChunkIndex = 0;

    _speechSessionId++;
    final session = _speechSessionId;

    await _flutterTts.stop();
    await _configureLanguage();
    await _flutterTts.setSpeechRate(_speechRate);
    await _flutterTts.setPitch(_pitch);
    await _flutterTts.setVolume(_volume);

    _state = TtsState.playing;
    notifyListeners();

    await _safeSpeak(currentParagraph!.subChunks[0].text, session: session);
  }

  /// Called by Reader when new chapter content has finished loading
  Future<void> onChapterLoaded(
    String chapterText, {
    int? newChapterIndex,
    bool startAtEnd = false,
  }) async {
    debugPrint('[TTS] Chapter loaded: $newChapterIndex, startAtEnd: $startAtEnd');
    _currentChapterIndex = newChapterIndex;
    _paragraphs = parseParagraphs(chapterText, chapterIndex: newChapterIndex);

    if (_paragraphs.isEmpty) return;

    _currentParagraphIndex = startAtEnd ? _paragraphs.length - 1 : 0;
    _currentSubChunkIndex = 0;

    _speechSessionId++;
    final session = _speechSessionId;

    _state = TtsState.playing;
    notifyListeners();

    await _safeSpeak(currentParagraph!.subChunks[0].text, session: session);
  }

  /// Speak starting from a selected text snippet or target paragraph index.
  /// ALWAYS starts at subchunk 0 of the detected paragraph!
  Future<void> speakFromSelection({
    required String fullText,
    required String selectedText,
    int? selectionStart,
    int? selectionEnd,
    int? targetParagraphIndex,
    String? storyId,
    int? chapterIndex,
    VoidCallback? onChapterComplete,
  }) async {
    if (fullText.trim().isEmpty) return;

    debugPrint('[TTS] Selection received: "$selectedText" (start: $selectionStart)');
    _isSelection = false;
    _currentStoryId = storyId;
    _currentChapterIndex = chapterIndex;
    _onChapterComplete = onChapterComplete;
    _paragraphs = parseParagraphs(fullText, chapterIndex: chapterIndex);

    if (_paragraphs.isEmpty) return;

    int pIdx = 0;
    if (targetParagraphIndex != null && targetParagraphIndex >= 0 && targetParagraphIndex < _paragraphs.length) {
      pIdx = targetParagraphIndex;
    } else {
      // Find paragraph containing selectedText
      final cleanSel = selectedText.trim();
      final found = _paragraphs.indexWhere(
        (p) => p.text.contains(cleanSel) || cleanSel.contains(p.text),
      );
      if (found != -1) {
        pIdx = found;
      }
    }

    debugPrint('[TTS] Paragraph detected: $pIdx (length: ${_paragraphs[pIdx].text.length})');
    _currentParagraphIndex = pIdx;
    _currentSubChunkIndex = 0; // ALWAYS read from head of paragraph!

    _speechSessionId++;
    final session = _speechSessionId;

    await _flutterTts.stop();
    await _configureLanguage();
    await _flutterTts.setSpeechRate(_speechRate);
    await _flutterTts.setPitch(_pitch);
    await _flutterTts.setVolume(_volume);

    _state = TtsState.playing;
    notifyListeners();

    await _safeSpeak(currentParagraph!.subChunks[0].text, session: session);
  }

  /// Speak isolated preview (max 200 chars) without altering reading session
  Future<void> speakPreview(String text) async {
    if (text.trim().isEmpty) return;

    final previewText = text.length > 200 ? text.substring(0, 200) : text;
    _speechSessionId++;
    final session = _speechSessionId;

    await _flutterTts.stop();
    await _configureLanguage();
    await _flutterTts.setSpeechRate(_speechRate);
    await _flutterTts.setPitch(_pitch);

    await _safeSpeak(previewText, session: session);
  }

  /// Legacy selection speak fallback
  Future<void> speakSelection(String text) async {
    await speakFromSelection(
      fullText: text,
      selectedText: text,
    );
  }

  /// Toggle play/pause for a given text content
  Future<void> toggle(
    String text, {
    String? storyId,
    int? chapterIndex,
    VoidCallback? onChapterComplete,
  }) async {
    if (isPlaying) {
      await pause();
    } else if (isPaused) {
      await resume();
    } else {
      await speak(
        text,
        storyId: storyId,
        chapterIndex: chapterIndex,
        onChapterComplete: onChapterComplete,
      );
    }
  }

  Future<void> pause() async {
    await _flutterTts.pause();
    _state = TtsState.paused;
    notifyListeners();
  }

  Future<void> resume() async {
    if (_state == TtsState.paused && _paragraphs.isNotEmpty) {
      _speechSessionId++;
      final session = _speechSessionId;
      _state = TtsState.playing;
      notifyListeners();
      await _safeSpeak(currentSubChunk?.text ?? '', session: session);
    }
  }

  Future<void> stop() async {
    debugPrint('[TTS] Stop requested. Session invalidated: $_speechSessionId');
    _speechSessionId++;
    await _flutterTts.stop();
    _state = TtsState.stopped;
    _isSelection = false;
    _cancelTimer();
    notifyListeners();
  }

  Future<void> nextParagraph() async {
    if (_paragraphs.isNotEmpty && _currentParagraphIndex < _paragraphs.length - 1) {
      _speechSessionId++;
      final session = _speechSessionId;
      await _flutterTts.stop();
      _currentParagraphIndex++;
      _currentSubChunkIndex = 0;
      _state = TtsState.playing;
      debugPrint('[TTS] Next paragraph: $_currentParagraphIndex');
      notifyListeners();
      await _safeSpeak(currentParagraph!.subChunks[0].text, session: session);
    } else if (onChapterChangeRequested != null && _currentChapterIndex != null) {
      final nextChap = _currentChapterIndex! + 1;
      debugPrint('[TTS] Next chapter requested: $nextChap');
      onChapterChangeRequested?.call(nextChap);
    } else if (_onChapterComplete != null) {
      _onChapterComplete?.call();
    }
  }

  Future<void> previousParagraph() async {
    if (_paragraphs.isNotEmpty && _currentParagraphIndex > 0) {
      _speechSessionId++;
      final session = _speechSessionId;
      await _flutterTts.stop();
      _currentParagraphIndex--;
      _currentSubChunkIndex = 0;
      _state = TtsState.playing;
      debugPrint('[TTS] Previous paragraph: $_currentParagraphIndex');
      notifyListeners();
      await _safeSpeak(currentParagraph!.subChunks[0].text, session: session);
    } else if (onChapterChangeRequested != null && _currentChapterIndex != null && _currentChapterIndex! > 0) {
      final prevChap = _currentChapterIndex! - 1;
      debugPrint('[TTS] Previous chapter requested: $prevChap');
      onChapterChangeRequested?.call(prevChap);
    }
  }

  // Backward compatibility alias for nextChunk / previousChunk
  Future<void> nextChunk() => nextParagraph();
  Future<void> previousChunk() => previousParagraph();

  Future<void> setSpeechRate(double rate) async {
    _speechRate = rate;
    await _flutterTts.setSpeechRate(rate);
    notifyListeners();
  }

  Future<void> setPitch(double pitch) async {
    _pitch = pitch;
    await _flutterTts.setPitch(pitch);
    notifyListeners();
  }

  Future<void> setVolume(double volume) async {
    _volume = volume;
    await _flutterTts.setVolume(volume);
    notifyListeners();
  }

  Future<void> setLanguage(String lang) async {
    _currentLanguage = lang;
    await _flutterTts.setLanguage(lang);
    notifyListeners();
  }

  // ⏱️ Sleep Timer controls
  void startSleepTimer(int minutes) {
    _cancelTimer();
    _stopAtEndOfChapter = false;
    _timerMinutesRemaining = minutes;
    notifyListeners();

    _sleepTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      _timerMinutesRemaining--;
      if (_timerMinutesRemaining <= 0) {
        stop();
      } else {
        notifyListeners();
      }
    });
  }

  void setStopAtEndOfChapter(bool enable) {
    _stopAtEndOfChapter = enable;
    if (enable) _cancelTimer();
    notifyListeners();
  }

  void _cancelTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _timerMinutesRemaining = 0;
  }
}
