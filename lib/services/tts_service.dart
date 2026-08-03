import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

enum TtsState { stopped, playing, paused }

class TtsService extends ChangeNotifier {
  static final TtsService instance = TtsService._internal();
  factory TtsService() => instance;

  final FlutterTts _flutterTts = FlutterTts();

  TtsState _state = TtsState.stopped;
  TtsState get state => _state;
  bool get isPlaying => _state == TtsState.playing;
  bool get isPaused => _state == TtsState.paused;

  double _speechRate = 0.5; // FlutterTts standard rate (0.5 = 1.0x normal)
  double get speechRate => _speechRate;

  double _pitch = 1.0;
  double get pitch => _pitch;

  double _volume = 1.0;
  double get volume => _volume;

  String _currentLanguage = 'vi-VN';
  String get currentLanguage => _currentLanguage;

  List<dynamic> _availableVoices = [];
  List<dynamic> get availableVoices => _availableVoices;

  Timer? _sleepTimer;
  int _timerMinutesRemaining = 0;
  int get timerMinutesRemaining => _timerMinutesRemaining;

  bool _stopAtEndOfChapter = false;
  bool get stopAtEndOfChapter => _stopAtEndOfChapter;

  VoidCallback? _onChapterComplete;
  
  // Chunking and Queue Management
  List<String> _chunks = [];
  int _currentChunkIndex = 0;
  String _rawText = '';

  int get currentChunkIndex => _currentChunkIndex;
  int get totalChunks => _chunks.length;
  String get currentChunkText => _chunks.isNotEmpty && _currentChunkIndex < _chunks.length 
      ? _chunks[_currentChunkIndex] 
      : '';

  static const int _maxChunkLength = 2000;

  TtsService._internal() {
    _initTts();
  }

  Future<void> _initTts() async {
    try {
      await _flutterTts.awaitSpeakCompletion(false);
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

        if (_currentChunkIndex < _chunks.length - 1) {
          _currentChunkIndex++;
          notifyListeners();
          await _flutterTts.speak(_chunks[_currentChunkIndex]);
        } else {
          // Reached end of current chapter / text
          _state = TtsState.stopped;
          notifyListeners();

          if (_stopAtEndOfChapter) {
            _stopAtEndOfChapter = false;
            await stop();
          } else if (_onChapterComplete != null) {
            _onChapterComplete?.call();
          }
        }
      });

      _flutterTts.setErrorHandler((msg) {
        debugPrint('[TtsService] Error: $msg');
        _state = TtsState.stopped;
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
      debugPrint('[TtsService] Exception during initialization: $e');
    }
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

  /// Split long story content into sentence-bounded chunks (max 2000 chars)
  List<String> _splitTextIntoChunks(String text) {
    // Clean up excessive whitespace
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return [];

    final chunks = <String>[];
    int start = 0;

    while (start < cleaned.length) {
      int end = (start + _maxChunkLength).clamp(0, cleaned.length);
      if (end < cleaned.length) {
        // Try to break at sentence end (. ! ? \n)
        int boundary = cleaned.lastIndexOf(RegExp(r'[.!?。！？]\s'), end);
        if (boundary > start + 200) {
          end = boundary + 1;
        } else {
          // Fallback to space
          int space = cleaned.lastIndexOf(' ', end);
          if (space > start + 200) {
            end = space;
          }
        }
      }

      final chunkStr = cleaned.substring(start, end).trim();
      if (chunkStr.isNotEmpty) {
        chunks.add(chunkStr);
      }
      start = end;
    }
    return chunks;
  }

  /// Speak a new text/chapter
  Future<void> speak(String text, {VoidCallback? onChapterComplete}) async {
    if (text.trim().isEmpty) return;

    _rawText = text;
    _onChapterComplete = onChapterComplete;
    _chunks = _splitTextIntoChunks(text);
    _currentChunkIndex = 0;

    if (_chunks.isEmpty) return;

    await _flutterTts.stop();
    await _configureLanguage();
    await _flutterTts.setSpeechRate(_speechRate);
    await _flutterTts.setPitch(_pitch);
    await _flutterTts.setVolume(_volume);

    _state = TtsState.playing;
    notifyListeners();

    await _flutterTts.speak(_chunks[_currentChunkIndex]);
  }

  Future<void> pause() async {
    await _flutterTts.pause();
    _state = TtsState.paused;
    notifyListeners();
  }

  Future<void> resume() async {
    if (_state == TtsState.paused && _chunks.isNotEmpty) {
      _state = TtsState.playing;
      notifyListeners();
      await _flutterTts.speak(_chunks[_currentChunkIndex]);
    }
  }

  Future<void> stop() async {
    await _flutterTts.stop();
    _state = TtsState.stopped;
    _cancelTimer();
    notifyListeners();
  }

  Future<void> nextChunk() async {
    if (_chunks.isNotEmpty && _currentChunkIndex < _chunks.length - 1) {
      await _flutterTts.stop();
      _currentChunkIndex++;
      _state = TtsState.playing;
      notifyListeners();
      await _flutterTts.speak(_chunks[_currentChunkIndex]);
    } else if (_onChapterComplete != null) {
      _onChapterComplete?.call();
    }
  }

  Future<void> previousChunk() async {
    if (_chunks.isNotEmpty && _currentChunkIndex > 0) {
      await _flutterTts.stop();
      _currentChunkIndex--;
      _state = TtsState.playing;
      notifyListeners();
      await _flutterTts.speak(_chunks[_currentChunkIndex]);
    }
  }

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
