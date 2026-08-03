import 'dart:async';
import 'package:flutter/foundation.dart';

enum AmbientSound { none, rain, lofi, nature, cafe }

class AmbientAudioService extends ChangeNotifier {
  static final AmbientAudioService instance = AmbientAudioService._internal();
  factory AmbientAudioService() => instance;

  AmbientAudioService._internal();

  AmbientSound _currentSound = AmbientSound.none;
  AmbientSound get currentSound => _currentSound;

  double _volume = 0.5;
  double get volume => _volume;

  bool _isPlaying = false;
  bool get isPlaying => _isPlaying;

  final Map<AmbientSound, String> _soundLabels = {
    AmbientSound.none: 'Tắt nhạc nền',
    AmbientSound.rain: 'Tiếng mưa rơi (Rain)',
    AmbientSound.lofi: 'Lofi Beats Chill',
    AmbientSound.nature: 'Rừng núi thiên nhiên',
    AmbientSound.cafe: 'Quán Cafe thư giãn',
  };

  String getLabel(AmbientSound sound) => _soundLabels[sound] ?? '';

  void selectSound(AmbientSound sound) {
    if (_currentSound == sound && _isPlaying) {
      stop();
      return;
    }

    _currentSound = sound;
    if (sound == AmbientSound.none) {
      stop();
    } else {
      _isPlaying = true;
      notifyListeners();
    }
  }

  void setVolume(double vol) {
    _volume = vol.clamp(0.0, 1.0);
    notifyListeners();
  }

  void stop() {
    _currentSound = AmbientSound.none;
    _isPlaying = false;
    notifyListeners();
  }
}
