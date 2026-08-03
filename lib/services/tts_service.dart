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

  double _speechRate = 0.5; // FlutterTts default rate is ~0.5
  double get speechRate => _speechRate;

  double _pitch = 1.0;
  double get pitch => _pitch;

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
  String _currentText = '';
  int _currentWordStart = 0;
  int _currentWordEnd = 0;

  int get currentWordStart => _currentWordStart;
  int get currentWordEnd => _currentWordEnd;

  TtsService._internal() {
    _initTts();
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage(_currentLanguage);
    await _flutterTts.setSpeechRate(_speechRate);
    await _flutterTts.setPitch(_pitch);

    _flutterTts.setStartHandler(() {
      _state = TtsState.playing;
      notifyListeners();
    });

    _flutterTts.setCompletionHandler(() {
      _state = TtsState.stopped;
      notifyListeners();
      if (_stopAtEndOfChapter) {
        _stopAtEndOfChapter = false;
        stop();
      } else {
        _onChapterComplete?.call();
      }
    });

    _flutterTts.setErrorHandler((msg) {
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

    _flutterTts.setProgressHandler((text, start, end, word) {
      _currentWordStart = start;
      _currentWordEnd = end;
      notifyListeners();
    });

    try {
      final voices = await _flutterTts.getVoices;
      if (voices != null) {
        _availableVoices = voices as List<dynamic>;
      }
    } catch (_) {}
  }

  Future<void> speak(String text, {VoidCallback? onChapterComplete}) async {
    if (text.isEmpty) return;
    _currentText = text;
    _onChapterComplete = onChapterComplete;
    _state = TtsState.playing;
    notifyListeners();

    await _flutterTts.stop();
    await _flutterTts.setLanguage(_currentLanguage);
    await _flutterTts.setSpeechRate(_speechRate);
    await _flutterTts.setPitch(_pitch);
    await _flutterTts.speak(text);
  }

  Future<void> pause() async {
    await _flutterTts.pause();
    _state = TtsState.paused;
    notifyListeners();
  }

  Future<void> resume() async {
    if (_state == TtsState.paused && _currentText.isNotEmpty) {
      await _flutterTts.speak(_currentText);
      _state = TtsState.playing;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    await _flutterTts.stop();
    _state = TtsState.stopped;
    _cancelTimer();
    notifyListeners();
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
