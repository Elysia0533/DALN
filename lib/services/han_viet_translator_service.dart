import 'package:flutter/foundation.dart';

class HanVietTranslatorService extends ChangeNotifier {
  static final HanVietTranslatorService instance = HanVietTranslatorService._internal();
  factory HanVietTranslatorService() => instance;

  HanVietTranslatorService._internal();

  bool _enabled = false;
  bool get enabled => _enabled;

  void toggleTranslator() {
    _enabled = !_enabled;
    notifyListeners();
  }

  // Common Hanzi to Han-Viet Sino-Vietnamese Pinyin dictionary lookup
  static final Map<String, String> _hanVietMap = {
    '第一章': 'Chương 1',
    '第二章': 'Chương 2',
    '第三章': 'Chương 3',
    '第四章': 'Chương 4',
    '第五章': 'Chương 5',
    '第六章': 'Chương 6',
    '第七章': 'Chương 7',
    '第八章': 'Chương 8',
    '第九章': 'Chương 9',
    '第十章': 'Chương 10',
    '修仙': 'Tu Tiên',
    '玄幻': 'Huyền Huyễn',
    '都市': 'Đô Thị',
    '穿越': 'Xuyên Không',
    '重生': 'Trọng Sinh',
    '系统': 'Hệ Thống',
    '宗门': 'Tông Môn',
    '长老': 'Trưởng Lão',
    '宗主': 'Tông Chủ',
    '弟子': 'Đệ Tử',
    '师父': 'Sư Phụ',
    '师兄': 'Sư Huynh',
    '师妹': 'Sư Muội',
    '功法': 'Công Pháp',
    '丹药': 'Đan Dược',
    '灵气': 'Linh Khí',
    '神仙': 'Thần Tiên',
    '魔王': 'Ma Vương',
    '无敌': 'Vô Địch',
    '天才': 'Thiên Tài',
    '废柴': 'Phế Sài',
  };

  /// Translates raw Chinese text to Sino-Vietnamese (Hán-Việt) text
  String translate(String rawChineseText) {
    if (!_enabled || rawChineseText.isEmpty) return rawChineseText;

    String translated = rawChineseText;
    _hanVietMap.forEach((chinese, vietnamese) {
      translated = translated.replaceAll(chinese, vietnamese);
    });

    return translated;
  }
}
