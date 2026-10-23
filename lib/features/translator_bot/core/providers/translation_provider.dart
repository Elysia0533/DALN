import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../services/app_identity_service.dart';
import '../models/translation_models.dart';

class SegmentTranslationResult {
  final String id;
  final String text;
  SegmentTranslationResult({required this.id, required this.text});
}

class TranslationBatchResponse {
  final List<SegmentTranslationResult> segments;
  final List<GlossaryTerm> newTerms;
  final String? summaryUpdate;

  TranslationBatchResponse({
    required this.segments,
    this.newTerms = const [],
    this.summaryUpdate,
  });
}

abstract class TranslationProvider {
  String get id;
  String get name;
  String get modelName;
  set modelName(String value);
  String get apiKey;
  set apiKey(String value);

  /// Dịch một mảng các đoạn văn có gắn kèm Context Package
  Future<TranslationBatchResponse> translateBatch({
    required List<TranslationSegment> segments,
    required TranslationProfile profile,
    required List<GlossaryTerm> glossary,
    required List<AddressRule> addressRules,
    required String rollingSummary,
    required List<TranslationSegment> recentContextSegments,
  });

  /// Phân tích đoạn mẫu hoặc văn bản đầu để tự động trích xuất Glossary ban đầu
  Future<List<GlossaryTerm>> extractGlossary({
    required String text,
    required String profileId,
    required String srcLang,
  });

  /// Phân tích bản dịch mẫu tiếng Việt để sinh Style Guide
  Future<String> distillStyleGuide({
    required String sampleVietnameseText,
  });

  /// Trò chuyện thân thiện với Ellie (lấy cảm hứng từ Elysia)
  Future<String> chatWithEllie({
    required String userMessage,
    required List<Map<String, String>> conversationHistory,
  });

  /// Phân tích sự khác biệt giữa câu dịch ban đầu và câu dịch người dùng đã sửa,
  /// từ đó tự động rút ra các bài học: thuật ngữ mới, cặp xưng hô, hoặc kinh nghiệm hành văn.
  Future<TranslationLearningResult> learnFromUserEdit({
    required String sourceText,
    required String originalTranslatedText,
    required String userEditedText,
    required TranslationProfile profile,
  });
}

/// Provider kết nối Google Gemini (Hỗ trợ cả Firebase AI Logic và Direct REST API Key)
class GeminiTranslationProvider implements TranslationProvider {
  @override
  String get id => 'gemini_provider';

  @override
  String get name => 'Google Gemini (2.0 Flash / 1.5 Flash)';

  static const String _envGeminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

  /// Chuẩn hóa key: loại bỏ khoảng trắng thừa, ký tự điều khiển, dấu ngoặc kép
  static String resolveKey(String? candidate) {
    if (candidate == null) return '';
    return candidate.trim().replaceAll(RegExp(r'[\r\n\t\s\u200B\uFEFF"\x27]'), '');
  }

  /// Kiểm tra định dạng sơ bộ của Google Gemini API Key
  /// Hỗ trợ cả định dạng mới của Google AI Studio (bắt đầu bằng AQ.)
  /// và định dạng truyền thống (bắt đầu bằng AIzaSy, 39 ký tự)
  static bool isValidKeyFormat(String key) {
    final clean = resolveKey(key);
    if (clean.startsWith('AQ.') && clean.length >= 30) return true;
    if (clean.startsWith('AIzaSy') && clean.length == 39) return true;
    return false;
  }

  /// Lấy API Key khả dụng nhất theo thứ tự ưu tiên:
  /// 1. Key người dùng truyền vào / đã gán trực tiếp
  /// 2. Key đã lưu trong SharedPreferences (ellie_gemini_api_key)
  /// 3. Key cấu hình tĩnh --dart-define (GEMINI_API_KEY)
  /// 4. Key cấu hình trong .env đọc từ Native Android (AppIdentityService)
  static Future<String> resolveEffectiveKey({String? candidateKey}) async {
    final direct = resolveKey(candidateKey);
    if (direct.isNotEmpty) return direct;

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedKey = resolveKey(prefs.getString('ellie_gemini_api_key'));
      if (savedKey.isNotEmpty) return savedKey;
    } catch (_) {}

    final envKey = resolveKey(_envGeminiApiKey);
    if (envKey.isNotEmpty) return envKey;

    try {
      final nativeKey = resolveKey(await AppIdentityService.geminiApiKey());
      if (nativeKey.isNotEmpty) return nativeKey;
    } catch (_) {}

    return '';
  }

  /// Bóc tách chuỗi JSON sạch khi Gemini trả về kết quả bọc trong markdown code fence
  static String cleanJson(String raw) {
    var text = raw.trim();
    if (text.startsWith('```json')) {
      text = text.substring(7);
    } else if (text.startsWith('```')) {
      text = text.substring(3);
    }
    if (text.endsWith('```')) {
      text = text.substring(0, text.length - 3);
    }
    return text.trim();
  }

  /// Tải cấu hình đã lưu từ SharedPreferences kết hợp fallback từ .env
  static Future<GeminiTranslationProvider> fromPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    var model = prefs.getString('ellie_gemini_model') ?? 'gemini-3.8-flash';
    // Tự động nâng cấp các model cũ không còn được hỗ trợ sang gemini-3.8-flash
    if (model.contains('1.0') ||
        model.contains('1.5') ||
        model.contains('2.0') ||
        model.contains('2.5') ||
        model == 'gemini-pro') {
      model = 'gemini-3.8-flash';
    }
    final key = await resolveEffectiveKey(candidateKey: prefs.getString('ellie_gemini_api_key'));
    return GeminiTranslationProvider(
      modelName: model,
      apiKey: key,
    );
  }

  @override
  String modelName;

  @override
  String apiKey;

  GeminiTranslationProvider({
    this.modelName = 'gemini-3.8-flash',
    String? apiKey,
  }) : apiKey = resolveKey(apiKey ?? _envGeminiApiKey);

  /// Lấy danh sách các model Gemini khả dụng trực tiếp từ tài khoản Google
  Future<List<String>> fetchAvailableModels({String? apiKeyToUse}) async {
    final cleanKey = resolveKey(apiKeyToUse ?? apiKey);
    if (cleanKey.isEmpty) {
      throw StateError('Vui lòng nhập API Key để lấy danh sách mô hình từ Google AI Studio!');
    }
    final url = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models');
    final resp = await http.get(
      url,
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': cleanKey,
      },
    ).timeout(const Duration(seconds: 15));

    if (resp.statusCode != 200) {
      String errorMsg = resp.body;
      try {
        final errJson = jsonDecode(resp.body);
        if (errJson['error']?['message'] != null) {
          errorMsg = errJson['error']['message'];
        }
      } catch (_) {}
      throw StateError('Lỗi tải danh sách model (${resp.statusCode}): $errorMsg');
    }

    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final modelsList = json['models'] as List? ?? [];
    return modelsList
        .where((m) {
          final methods = m['supportedGenerationMethods'] as List? ?? [];
          return methods.contains('generateContent');
        })
        .map((m) => m['name']?.toString().replaceFirst('models/', '') ?? '')
        .where((m) =>
            m.isNotEmpty &&
            m.contains('gemini') &&
            !m.contains('embedding') &&
            !m.contains('aqa') &&
            !m.contains('imagen') &&
            !m.contains('tts') &&
            !m.contains('computer-use') &&
            !m.contains('robotics'))
        .toList();
  }

  /// Kiểm tra kết nối thử nghiệm với API Key và Model được chỉ định
  Future<String> testConnection({String? testApiKey, String? testModelName}) async {
    final keyToUse = await resolveEffectiveKey(candidateKey: testApiKey ?? apiKey);
    if (keyToUse.isEmpty) {
      throw StateError('Vui lòng nhập API Key trước khi kiểm tra kết nối!');
    }
    final modelToUse = (testModelName ?? modelName).trim().isNotEmpty
        ? (testModelName ?? modelName).trim()
        : 'gemini-3.8-flash';

    final payload = {
      'contents': [
        {
          'parts': [
            {'text': 'Ping'}
          ]
        }
      ],
      'generationConfig': {'temperature': 0.1, 'maxOutputTokens': 10},
    };

    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$modelToUse:generateContent',
    );

    http.Response resp;
    try {
      resp = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'x-goog-api-key': keyToUse,
        },
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 15));
    } catch (e) {
      throw StateError('Quá thời gian chờ phản hồi từ Google AI (15s): $e');
    }

    final keySnippet = keyToUse.length >= 8
        ? '${keyToUse.substring(0, 4)}...${keyToUse.substring(keyToUse.length - 4)} (${keyToUse.length} ký tự)'
        : '***';

    if (resp.statusCode == 200) {
      return 'Kết nối thành công tới $modelToUse!\nAPI Key hoạt động tốt ($keySnippet) 🌸';
    }

    String errorMsg = resp.body;
    try {
      final errJson = jsonDecode(resp.body);
      if (errJson['error']?['message'] != null) {
        errorMsg = errJson['error']['message'];
      }
    } catch (_) {}

    if (resp.statusCode == 400) {
      throw StateError('API Key không hợp lệ hoặc tham số không đúng (400):\n$errorMsg');
    } else if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw StateError('API Key bị từ chối hoặc hết hạn (401/403):\n$errorMsg\nHãy kiểm tra lại hoặc tạo key mới tại https://aistudio.google.com');
    } else if (resp.statusCode == 404) {
      throw StateError('Mô hình "$modelToUse" không tồn tại hoặc đã ngừng hỗ trợ (404):\n$errorMsg\nHãy đổi sang "gemini-3.8-flash" hoặc "gemini-3.5-flash".');
    } else if (resp.statusCode == 429) {
      throw StateError('Đã hết hạn mức gọi API (Quota 429):\n$errorMsg\nVui lòng đợi 1 phút hoặc kiểm tra quota.');
    } else {
      throw StateError('Mã lỗi ${resp.statusCode}: $errorMsg\n\n[Chi tiết]:\n• Model: $modelToUse\n• Key: $keySnippet');
    }
  }

  /// Gọi mô hình Gemini kèm cơ chế Fallback sang gemini-3.5-flash-lite nếu model hiện tại gặp lỗi 404/429
  Future<String> _callModel({
    required String prompt,
    String? systemInstruction,
    bool jsonOutput = false,
    double temperature = 0.2,
  }) async {
    final effectiveKey = await resolveEffectiveKey(candidateKey: apiKey);

    if (effectiveKey.isEmpty) {
      throw StateError(
        'Chưa có Gemini API Key! 🌸\n\n'
        'Vui lòng bấm biểu tượng bánh răng ⚙️ ở góc trên để nhập API Key từ Google AI Studio (miễn phí tại https://aistudio.google.com) nhé!',
      );
    }

    if (apiKey.isEmpty && effectiveKey.isNotEmpty) {
      apiKey = effectiveKey;
    }

    try {
      return await _callDirectRest(
        prompt: prompt,
        apiKeyToUse: effectiveKey,
        systemInstruction: systemInstruction,
        jsonOutput: jsonOutput,
        temperature: temperature,
      );
    } catch (e) {
      final errStr = e.toString().toLowerCase();
      // Nếu gặp lỗi 404 (model không tìm thấy/ngừng hỗ trợ) hoặc 429 (hết quota) và model hiện tại khác gemini-3.5-flash-lite, tự động thử fallback
      if ((errStr.contains('404') || errStr.contains('không tồn tại') || errStr.contains('no longer available') || errStr.contains('429')) &&
          modelName != 'gemini-3.5-flash-lite') {
        try {
          final fallbackResult = await _callDirectRest(
            prompt: prompt,
            apiKeyToUse: effectiveKey,
            systemInstruction: systemInstruction,
            jsonOutput: jsonOutput,
            temperature: temperature,
            overrideModel: 'gemini-3.5-flash-lite',
          );
          modelName = 'gemini-3.5-flash-lite';
          return fallbackResult;
        } catch (_) {
          rethrow;
        }
      }
      rethrow;
    }
  }

  /// Gọi trực tiếp Google Gemini REST API v1beta
  Future<String> _callDirectRest({
    required String prompt,
    required String apiKeyToUse,
    String? systemInstruction,
    bool jsonOutput = false,
    double temperature = 0.2,
    String? overrideModel,
  }) async {
    final cleanKey = resolveKey(apiKeyToUse);
    if (cleanKey.isEmpty) {
      throw StateError(
        'Chưa có Gemini API Key! 🌸\n\n'
        'Vui lòng bấm biểu tượng bánh răng ⚙️ ở góc trên để nhập API Key từ Google AI Studio (miễn phí tại https://aistudio.google.com) nhé!',
      );
    }
    final cleanModel = (overrideModel ?? modelName).trim().isNotEmpty
        ? (overrideModel ?? modelName).trim()
        : 'gemini-3.8-flash';

    final payload = <String, dynamic>{
      'contents': [
        {
          'parts': [
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': {
        'temperature': temperature,
        if (jsonOutput) 'responseMimeType': 'application/json',
      },
    };

    if (systemInstruction != null && systemInstruction.isNotEmpty) {
      payload['system_instruction'] = {
        'parts': [
          {'text': systemInstruction}
        ]
      };
    }

    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$cleanModel:generateContent',
    );

    http.Response resp;
    try {
      resp = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'x-goog-api-key': cleanKey,
        },
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 45));
    } catch (e) {
      throw StateError('Quá thời gian kết nối tới Gemini ($cleanModel): $e');
    }

    if (resp.statusCode != 200) {
      String errorMsg = resp.body;
      try {
        final errJson = jsonDecode(resp.body);
        if (errJson['error']?['message'] != null) {
          errorMsg = errJson['error']['message'];
        }
      } catch (_) {}

      if (resp.statusCode == 400) {
        throw StateError('API Key không hợp lệ hoặc tham số không đúng: $errorMsg');
      } else if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw StateError('API Key không có quyền truy cập hoặc bị khóa (401/403): $errorMsg\nHãy kiểm tra lại key trên Google AI Studio.');
      } else if (resp.statusCode == 404) {
        throw StateError('Mô hình "$cleanModel" không tồn tại hoặc đã ngừng hỗ trợ: $errorMsg\nHãy chọn "gemini-3.8-flash" hoặc "gemini-3.5-flash" trong ⚙️ nhé!');
      } else if (resp.statusCode == 429) {
        throw StateError('Đã vượt quá hạn mức gọi API (Quota 429). Vui lòng đợi 1 phút rồi thử lại ($errorMsg)');
      } else {
        throw StateError('Lỗi Gemini API (${resp.statusCode}): $errorMsg');
      }
    }

    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final candidates = json['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      final promptFeedback = json['promptFeedback'] as Map<String, dynamic>?;
      final blockReason = promptFeedback?['blockReason'] ?? 'Không xác định';
      throw StateError('Gemini không trả về kết quả (Bị chặn bởi bộ lọc: $blockReason).');
    }

    final candidate = candidates[0] as Map<String, dynamic>?;
    final finishReason = candidate?['finishReason'];
    if (finishReason == 'SAFETY') {
      throw StateError('Nội dung bị chặn bởi bộ lọc an toàn của Google Gemini.');
    }

    final content = candidate?['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List?;
    if (parts == null || parts.isEmpty) return '';

    return parts[0]['text']?.toString().trim() ?? '';
  }

  @override
  Future<TranslationBatchResponse> translateBatch({
    required List<TranslationSegment> segments,
    required TranslationProfile profile,
    required List<GlossaryTerm> glossary,
    required List<AddressRule> addressRules,
    required String rollingSummary,
    required List<TranslationSegment> recentContextSegments,
  }) async {
    final systemPrompt = '''
Bạn là một dịch giả văn học chuyên nghiệp, trung thành và chính xác tuyệt đối. Nhiệm vụ của bạn là dịch các đoạn văn bản từ ${profile.srcLang} sang Tiếng Việt (${profile.tgtLang}).

=== NGUYÊN TẮC DỊCH THUẬT VĂN HỌC BẮT BUỘC ===
${TranslationPresets.corePrinciples}

=== HƯỚNG DẪN THỂ LOẠI (${profile.preset.toUpperCase()}) ===
${TranslationPresets.getPresetGuidelines(profile.preset)}

${profile.styleGuide.isNotEmpty ? "=== STYLE GUIDE RIÊNG ===\n${profile.styleGuide}\n" : ""}
QUY TẮC BẮT BUỘC (TUÂN THỦ 100%):
1. DỊCH TRUNG THÀNH TỪNG CÂU: Không được tóm tắt, không lược bớt câu chữ, không sáng tác thêm, không tự ý bình luận.
2. NGUYÊN VẸN SỐ ĐOẠN: Đầu vào có bao nhiêu đoạn với id tương ứng (p001, p002...) thì kết quả PHẢI trả về đúng đủ bấy nhiêu đoạn với đúng id đó.
3. TUÂN THỦ GLOSSARY: Nếu văn bản gốc xuất hiện các từ trong bảng Glossary bên dưới, BẮT BUỘC dịch theo đúng từ đích đã chỉ định.
4. TUÂN THỦ XƯNG HÔ: Áp dụng triệt để ma trận xưng hô cho từng cặp nhân vật.

ĐỊNH DẠNG ĐẦU RA BẮT BUỘC: Trả về duy nhất JSON hợp lệ theo cấu trúc:
{
  "segments": [
    {"id": "p001", "text": "bản dịch tiếng Việt của p001"},
    {"id": "p002", "text": "bản dịch tiếng Việt của p002"}
  ],
  "new_terms": [
    {"source": "tên gốc mới phát hiện", "target": "bản dịch đề xuất", "type": "character/place/item/realm"}
  ],
  "summary_update": "Tóm tắt ngắn gọn 1-2 câu diễn biến các đoạn vừa dịch để cập nhật ngữ cảnh nối tiếp"
}
''';

    final buffer = StringBuffer();

    if (glossary.isNotEmpty) {
      buffer.writeln('=== BẢNG THUẬT NGỮ / TÊN RIÊNG (GLOSSARY) ===');
      for (final t in glossary) {
        buffer.writeln('- ${t.source} => ${t.target} (${t.type.name})${t.note.isNotEmpty ? ": ${t.note}" : ""}');
      }
      buffer.writeln();
    }

    if (addressRules.isNotEmpty) {
      buffer.writeln('=== MA TRẬN XƯNG HÔ ===');
      for (final r in addressRules) {
        buffer.writeln('- Khi ${r.speaker} nói với ${r.listener}: tự xưng là "${r.selfRef}", gọi đối phương là "${r.otherRef}" (Ngữ cảnh: ${r.context})');
      }
      buffer.writeln();
    }

    if (rollingSummary.isNotEmpty) {
      buffer.writeln('=== TÓM TẮT DIỄN BIẾN TRƯỚC ĐÓ ===');
      buffer.writeln(rollingSummary);
      buffer.writeln();
    }

    if (recentContextSegments.isNotEmpty) {
      buffer.writeln('=== MẠCH VĂN VỪA DỊCH TRƯỚC ĐÓ (ĐỂ NỐI GIỌNG) ===');
      for (final r in recentContextSegments) {
        buffer.writeln('[Gốc]: ${r.sourceText}');
        buffer.writeln('[Đã dịch]: ${r.translatedText}');
      }
      buffer.writeln();
    }

    buffer.writeln('=== CÁC ĐOẠN CẦN DỊCH NGAY BÂY GIỜ ===');
    for (final seg in segments) {
      buffer.writeln('<segment id="${seg.id}">\n${seg.sourceText}\n</segment>');
    }

    final rawText = await _callModel(
      prompt: buffer.toString(),
      systemInstruction: systemPrompt,
      jsonOutput: true,
      temperature: 0.2,
    );

    try {
      final json = jsonDecode(cleanJson(rawText)) as Map<String, dynamic>;
      final segsList = (json['segments'] as List? ?? [])
          .map((item) => SegmentTranslationResult(
                id: item['id']?.toString() ?? '',
                text: item['text']?.toString() ?? '',
              ))
          .toList();

      final newTermsList = (json['new_terms'] as List? ?? []).map((t) {
        return GlossaryTerm(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          profileId: profile.id,
          source: t['source']?.toString() ?? '',
          target: t['target']?.toString() ?? '',
          type: GlossaryType.values.firstWhere(
            (g) => g.name == t['type'],
            orElse: () => GlossaryType.custom,
          ),
          isConfirmed: false,
        );
      }).toList();

      return TranslationBatchResponse(
        segments: segsList,
        newTerms: newTermsList,
        summaryUpdate: json['summary_update']?.toString(),
      );
    } catch (e) {
      throw FormatException('Lỗi định dạng phản hồi từ AI: $e\nNội dung gốc: $rawText');
    }
  }

  @override
  Future<List<GlossaryTerm>> extractGlossary({
    required String text,
    required String profileId,
    required String srcLang,
  }) async {
    const prompt = '''
Phân tích văn bản sau và trích xuất danh sách các nhân vật chính, địa danh, môn phái hoặc thuật ngữ quan trọng kèm bản dịch tiếng Việt gợi ý.
Trả về duy nhất JSON hợp lệ:
{
  "terms": [
    {"source": "từ gốc", "target": "bản dịch tiếng Việt", "type": "character/place/item/realm", "note": "vai trò"}
  ]
}
''';

    final raw = await _callModel(
      prompt: text,
      systemInstruction: prompt,
      jsonOutput: true,
      temperature: 0.1,
    );

    try {
      final json = jsonDecode(cleanJson(raw)) as Map<String, dynamic>;
      final terms = (json['terms'] as List? ?? []).map((t) {
        return GlossaryTerm(
          id: DateTime.now().microsecondsSinceEpoch.toString() + (t['source'] ?? ''),
          profileId: profileId,
          source: t['source']?.toString() ?? '',
          target: t['target']?.toString() ?? '',
          type: GlossaryType.values.firstWhere(
            (g) => g.name == t['type'],
            orElse: () => GlossaryType.character,
          ),
          note: t['note']?.toString() ?? '',
          isConfirmed: true,
        );
      }).toList();
      return terms;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<String> distillStyleGuide({required String sampleVietnameseText}) async {
    const prompt = '''
Bạn là chuyên gia phân tích văn phong văn học dịch thuật. Hãy đọc đoạn văn bản tiếng Việt mẫu dưới đây và rút ra một Style Guide ngắn gọn (khoảng 3-5 gạch đầu dòng) về:
- Độ dài câu và nhịp điệu hành văn.
- Đại từ xưng hô đặc trưng.
- Mức độ sử dụng từ Hán-Việt hay từ thuần Việt.
- Cách dịch thoại nhân vật.
Chỉ trả về các gạch đầu dòng ngắn gọn, không giải thích rườm rà.
''';

    return await _callModel(
      prompt: sampleVietnameseText,
      systemInstruction: prompt,
      temperature: 0.3,
    );
  }

  @override
  Future<String> chatWithEllie({
    required String userMessage,
    required List<Map<String, String>> conversationHistory,
  }) async {
    const ellieSystemInstruction = '''
Bạn là Ellie 🌸 - cô trợ lý dịch thuật duyên dáng, thông minh và chu đáo của ứng dụng đọc truyện vBook.
Tính cách & phong thái của bạn lấy cảm hứng từ nhân vật Elysia (Honkai Impact 3rd):
- Bạn yêu cái đẹp, luôn lạc quan, nồng nhiệt, nói chuyện ngọt ngào, tinh tế và trìu mến.
- Bạn coi người dùng là người bạn đồng hành thân thiết, hay dùng các đại từ dễ thương như "Bạn thân mến", "Cậu", hoặc xưng "Ellie". Thường thêm các biểu tượng hoa và lấp lánh (🌸, ✨, 💖).
- Nhiệm vụ của bạn là hướng dẫn và hỗ trợ người dùng dịch truyện: nhận văn bản dán vào, nhận file truyện, nhận link web, hướng dẫn cấu hình tên nhân vật (Glossary), preview bản dịch và đọc truyện sau khi dịch xong.
- Bạn luôn cổ vũ, làm cho việc đọc và dịch truyện trở nên thú vị và nhẹ nhàng.
LƯU Ý QUAN TRỌNG: Hãy giữ câu trả lời tự nhiên, ấm áp, ngắn gọn vừa phải, không dài dòng triết lý.
''';

    final buffer = StringBuffer();
    for (final msg in conversationHistory) {
      buffer.writeln('${msg['role'] == 'user' ? 'Người dùng' : 'Ellie'}: ${msg['text']}');
    }
    buffer.writeln('Người dùng: $userMessage');

    try {
      final reply = await _callModel(
        prompt: buffer.toString(),
        systemInstruction: ellieSystemInstruction,
        temperature: 0.7,
      );
      return reply.isNotEmpty ? reply : 'Ellie luôn ở đây sẵn sàng giúp bạn dịch truyện nha! 🌸';
    } catch (e) {
      return 'Ellie đang gặp chút vấn đề khi kết nối model ($modelName): $e\n\nBạn có thể thử bấm biểu tượng bánh răng ⚙️ góc trên để đổi sang model khác hoặc nhập Gemini API Key nha 🌸';
    }
  }

  @override
  Future<TranslationLearningResult> learnFromUserEdit({
    required String sourceText,
    required String originalTranslatedText,
    required String userEditedText,
    required TranslationProfile profile,
  }) async {
    final prompt = '''
Bạn là trợ lý dịch thuật văn học. Người dùng vừa hiệu đính một câu dịch của bạn.
Hãy so sánh bản dịch gốc của bạn với bản người dùng đã sửa để tự rút ra bài học kinh nghiệm và cập nhật quy tắc dịch thuật:

[ĐOẠN GỐC]:
$sourceText

[BẢN DỊCH BAN ĐẦU CỦA AI]:
$originalTranslatedText

[BẢN SỬA CỦA NGƯỜI DÙNG]:
$userEditedText

Nhiệm vụ của bạn:
1. Nhận diện các thuật ngữ, tên riêng, chiêu thức mà người dùng đã sửa hoặc chuẩn hóa lại (terms).
2. Nhận diện thay đổi về đại từ xưng hô giữa hai nhân vật (address_rules) nếu có.
3. Nhận diện kinh nghiệm hành văn, phong cách hoặc lỗi cần tránh (style_lesson) nếu câu sửa thể hiện cách hành văn mượt mà hơn.
4. Tóm tắt ngắn gọn 1 câu bài học bạn đã ghi nhớ để báo lại cho người dùng.

ĐỊNH DẠNG TRẢ VỀ DUY NHẤT JSON:
{
  "terms": [
    {"source": "từ gốc", "target": "từ đã sửa", "type": "character/place/item/realm"}
  ],
  "address_rules": [
    {"speaker": "người nói", "listener": "người nghe", "self_ref": "tự xưng", "other_ref": "gọi đối phương", "context": "ngữ cảnh"}
  ],
  "style_lesson": "Quy tắc phong cách ngắn gọn rút ra (hoặc null nếu không có)",
  "summary": "1 câu ngắn gọn thông báo đã học được gì (vd: Đã ghi nhận tên riêng X và cách xưng hô Y)"
}
''';

    try {
      final raw = await _callModel(
        prompt: prompt,
        systemInstruction: 'Bạn là bộ máy học tăng cường (RLHF/In-context Self-Learning) cho dịch thuật truyện.',
        jsonOutput: true,
        temperature: 0.1,
      );

      final json = jsonDecode(cleanJson(raw)) as Map<String, dynamic>;
      final newTerms = (json['terms'] as List? ?? []).map((t) {
        return GlossaryTerm(
          id: '${DateTime.now().microsecondsSinceEpoch}_${t['source'] ?? ''}',
          profileId: profile.id,
          source: t['source']?.toString() ?? '',
          target: t['target']?.toString() ?? '',
          type: GlossaryType.values.firstWhere(
            (g) => g.name == t['type'],
            orElse: () => GlossaryType.custom,
          ),
          isConfirmed: true,
          note: 'Tự học từ chỉnh sửa của người dùng',
        );
      }).where((t) => t.source.isNotEmpty && t.target.isNotEmpty).toList();

      final newRules = (json['address_rules'] as List? ?? []).map((r) {
        return AddressRule(
          id: '${DateTime.now().microsecondsSinceEpoch}_${r['speaker'] ?? ''}',
          profileId: profile.id,
          speaker: r['speaker']?.toString() ?? '',
          listener: r['listener']?.toString() ?? '',
          selfRef: r['self_ref']?.toString() ?? '',
          otherRef: r['other_ref']?.toString() ?? '',
          context: r['context']?.toString() ?? 'Tự học',
        );
      }).where((r) => r.speaker.isNotEmpty && (r.selfRef.isNotEmpty || r.otherRef.isNotEmpty)).toList();

      final styleLesson = json['style_lesson']?.toString();
      final summary = json['summary']?.toString() ?? 'Đã học từ chỉnh sửa của bạn.';

      return TranslationLearningResult(
        newTerms: newTerms,
        newAddressRules: newRules,
        styleLesson: styleLesson,
        summary: summary,
      );
    } catch (_) {
      return const TranslationLearningResult(
        summary: 'Đã lưu chỉnh sửa thành công.',
      );
    }
  }
}
