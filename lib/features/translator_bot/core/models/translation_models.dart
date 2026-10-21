/// Trạng thái của một đoạn văn trong phiên dịch
enum SegmentState {
  pending,
  translating,
  done,
  edited,
  error,
}

/// Loại mục thuật ngữ / tên gọi
enum GlossaryType {
  character,   // Tên nhân vật (Lâm Phong)
  place,       // Địa danh / Môn phái (Thanh Vân Tông)
  item,        // Chiêu thức / Pháp bảo / Đan dược
  realm,       // Cảnh giới / Cấp bậc
  custom,      // Khác
}

/// Loại nguồn phiên dịch
enum SessionKind {
  text,
  file,
  chapter,
  link,
  manga,
}

/// Trạng thái lưu trữ của phiên dịch
enum SessionStatus {
  temp,   // Tạm thời (mặc định)
  saved,  // Người dùng đã bấm Lưu về máy
}

/// Đại diện cho một đoạn văn bản cần dịch
class TranslationSegment {
  final String id; // vd: p001, p002
  final String sourceText;
  String translatedText;
  SegmentState state;
  String? error;

  TranslationSegment({
    required this.id,
    required this.sourceText,
    this.translatedText = '',
    this.state = SegmentState.pending,
    this.error,
  });

  Map<String, dynamic> toMap(String sessionId) => {
    'session_id': sessionId,
    'seg_id': id,
    'src': sourceText,
    'tgt': translatedText,
    'state': state.name,
    'error': error,
  };

  factory TranslationSegment.fromMap(Map<String, dynamic> map) => TranslationSegment(
    id: map['seg_id'] as String,
    sourceText: map['src'] as String? ?? '',
    translatedText: map['tgt'] as String? ?? '',
    state: SegmentState.values.firstWhere(
      (s) => s.name == map['state'],
      orElse: () => SegmentState.pending,
    ),
    error: map['error'] as String?,
  );
}

/// Mục từ trong Glossary (Bảng thuật ngữ / tên riêng)
class GlossaryTerm {
  final String id;
  final String profileId;
  final String source;
  final String target;
  final GlossaryType type;
  final String note;
  final bool isConfirmed;
  final bool alwaysInclude;

  GlossaryTerm({
    required this.id,
    required this.profileId,
    required this.source,
    required this.target,
    this.type = GlossaryType.character,
    this.note = '',
    this.isConfirmed = true,
    this.alwaysInclude = false,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'profile_id': profileId,
    'source': source,
    'target': target,
    'type': type.name,
    'note': note,
    'is_confirmed': isConfirmed ? 1 : 0,
    'always_include': alwaysInclude ? 1 : 0,
  };

  factory GlossaryTerm.fromMap(Map<String, dynamic> map) => GlossaryTerm(
    id: map['id'] as String,
    profileId: map['profile_id'] as String,
    source: map['source'] as String? ?? '',
    target: map['target'] as String? ?? '',
    type: GlossaryType.values.firstWhere(
      (t) => t.name == map['type'],
      orElse: () => GlossaryType.character,
    ),
    note: map['note'] as String? ?? '',
    isConfirmed: (map['is_confirmed'] as int? ?? 1) == 1,
    alwaysInclude: (map['always_include'] as int? ?? 0) == 1,
  );
}

/// Quy tắc xưng hô giữa hai nhân vật
class AddressRule {
  final String id;
  final String profileId;
  final String speaker;   // Người nói
  final String listener;  // Người nghe
  final String selfRef;   // Tự xưng (vd: ta, tôi, đệ tử, muội)
  final String otherRef;  // Gọi người kia (vd: ngươi, nàng, huynh, sư tôn)
  final String context;   // Bối cảnh (vd: mặc định, khi giận dữ)

  AddressRule({
    required this.id,
    required this.profileId,
    required this.speaker,
    required this.listener,
    required this.selfRef,
    required this.otherRef,
    this.context = 'mặc định',
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'profile_id': profileId,
    'speaker': speaker,
    'listener': listener,
    'self_ref': selfRef,
    'other_ref': otherRef,
    'context': context,
  };

  factory AddressRule.fromMap(Map<String, dynamic> map) => AddressRule(
    id: map['id'] as String,
    profileId: map['profile_id'] as String,
    speaker: map['speaker'] as String? ?? '',
    listener: map['listener'] as String? ?? '',
    selfRef: map['self_ref'] as String? ?? '',
    otherRef: map['other_ref'] as String? ?? '',
    context: map['context'] as String? ?? 'mặc định',
  );
}

/// Hồ sơ dịch thuật của một bộ truyện (Profile)
class TranslationProfile {
  final String id;
  String title;
  String srcLang;
  String tgtLang;
  String preset;      // 'ancient', 'modern', 'school', 'romance'
  String styleGuide;   // Hướng dẫn văn phong học được từ bản dịch mẫu hoặc feedback
  int version;
  DateTime updatedAt;

  TranslationProfile({
    required this.id,
    required this.title,
    this.srcLang = 'en',
    this.tgtLang = 'vi',
    this.preset = 'modern',
    this.styleGuide = '',
    this.version = 1,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'src_lang': srcLang,
    'tgt_lang': tgtLang,
    'preset': preset,
    'style_guide': styleGuide,
    'version': version,
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };

  factory TranslationProfile.fromMap(Map<String, dynamic> map) => TranslationProfile(
    id: map['id'] as String,
    title: map['title'] as String? ?? 'Chưa đặt tên',
    srcLang: map['src_lang'] as String? ?? 'en',
    tgtLang: map['tgt_lang'] as String? ?? 'vi',
    preset: map['preset'] as String? ?? 'modern',
    styleGuide: map['style_guide'] as String? ?? '',
    version: map['version'] as int? ?? 1,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      map['updated_at'] as int? ?? DateTime.now().millisecondsSinceEpoch,
    ),
  );
}

/// Một phiên dịch cụ thể (Session)
class TranslationSession {
  final String id;
  final String profileId;
  String folderName;   // Tên thư mục truyện (để gom nhiều chapter vào 1 folder)
  String chapterTitle; // Tên chương / tiêu đề
  SessionKind kind;
  String sourceRef;    // Đường dẫn file, URL, hoặc tên gốc
  SessionStatus status;
  String rollingSummary; // Tóm tắt ngữ cảnh cuộn
  DateTime createdAt;

  TranslationSession({
    required this.id,
    required this.profileId,
    this.folderName = 'Chưa phân loại',
    this.chapterTitle = 'Chương mới',
    this.kind = SessionKind.text,
    this.sourceRef = '',
    this.status = SessionStatus.temp,
    this.rollingSummary = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
    'id': id,
    'profile_id': profileId,
    'folder_name': folderName,
    'chapter_title': chapterTitle,
    'kind': kind.name,
    'source_ref': sourceRef,
    'status': status.name,
    'rolling_summary': rollingSummary,
    'created_at': createdAt.millisecondsSinceEpoch,
  };

  factory TranslationSession.fromMap(Map<String, dynamic> map) => TranslationSession(
    id: map['id'] as String,
    profileId: map['profile_id'] as String,
    folderName: map['folder_name'] as String? ?? 'Chưa phân loại',
    chapterTitle: map['chapter_title'] as String? ?? 'Chương mới',
    kind: SessionKind.values.firstWhere(
      (k) => k.name == map['kind'],
      orElse: () => SessionKind.text,
    ),
    sourceRef: map['source_ref'] as String? ?? '',
    status: SessionStatus.values.firstWhere(
      (s) => s.name == map['status'],
      orElse: () => SessionStatus.temp,
    ),
    rollingSummary: map['rolling_summary'] as String? ?? '',
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      map['created_at'] as int? ?? DateTime.now().millisecondsSinceEpoch,
    ),
  );
}

/// Kết quả tự học của AI khi người dùng chỉnh sửa câu dịch
class TranslationLearningResult {
  final List<GlossaryTerm> newTerms;
  final List<AddressRule> newAddressRules;
  final String? styleLesson;
  final String summary;

  const TranslationLearningResult({
    this.newTerms = const [],
    this.newAddressRules = const [],
    this.styleLesson,
    this.summary = '',
  });

  bool get hasLearnings =>
      newTerms.isNotEmpty ||
      newAddressRules.isNotEmpty ||
      (styleLesson != null && styleLesson!.trim().isNotEmpty);
}

/// Các bộ nguyên tắc dịch thuật văn học chuyên nghiệp cài sẵn theo thể loại
class TranslationPresets {
  static const String corePrinciples = '''
1. VĂN PHONG VĂN HỌC THUẦN VIỆT:
   - Tuyệt đối không dịch thô cứng theo cấu trúc ngữ pháp ngoại ngữ (No Word-by-Word).
   - Tránh lạm dụng thể bị động "được/bị". Chuyển hóa tự nhiên sang câu chủ động thuần Việt.
   - Tránh lặp các từ chỉ định không cần thiết ("một cái...", "của anh ấy/cô ấy").
   - Câu văn gãy gọn, giàu nhạc điệu, giàu hình ảnh, biểu đạt đúng tâm trạng và cảm xúc nhân vật.
2. TRUNG THÀNH VỚI NGUYÊN TÁC:
   - Không được tóm tắt, không tự ý cắt xén, không bịa thêm tình tiết.
   - Giữ nguyên 100% số lượng phân đoạn (mỗi id p001, p002... tương ứng 1 đoạn dịch).
   - Bảo toàn dấu hội thoại: dấu ngoặc kép "", dấu ngoặc vuông thoại 「」, hoặc gạch đầu dòng —, cùng các định dạng in nghiêng, in đậm.
3. TUÂN THỦ GLOSSARY & XƯNG HÔ:
   - Luôn ưu tiên dùng đúng từ trong bảng Glossary và Ma trận xưng hô đã được thiết lập.
''';

  static String getPresetGuidelines(String preset) {
    switch (preset.toLowerCase()) {
      case 'wuxia':
      case 'ancient':
      case 'xianxia':
        return '''
[THỂ LOẠI: TIÊN HIỆP / KIẾM HIỆP / HUYỀN HUYỄN / CỔ TRANG]
- Xưng hô nhân vật: Ta - Ngươi, Huynh - Đệ, Sư tôn - Đồ nhi, Sư phụ - Đệ tử, Bản tọa, Tại hạ, Các hạ, Huynh đài, Tiền bối - Vãn bối, Muội muội...
- Từ vựng Hán - Việt: Sử dụng từ ngữ Hán-Việt chuẩn xác, đắt giá, hào sảng cho các khái niệm tu chân, cảnh giới, công pháp, pháp bảo, đan dược (Đan điền, Trúc Cơ, Kim Đan, Độ kiếp, Linh khí, Pháp trận, Thần thức, Đạo hữu...).
- Ngữ khí: Cổ phong, hào hùng hoặc thâm trầm tùy theo bối cảnh.''';

      case 'light_novel':
      case 'anime':
      case 'japanese':
        return '''
[THỂ LOẠI: LIGHT NOVEL / ANIME NHẬT BẢN]
- Xưng hô nhân vật: Cậu - Tớ, Tôi - Em, Cậu - Mình, Anh - Em, Tiền bối - Hậu bối, Đại ca, Tiểu thư, Thiếu gia...
- Kính ngữ: Chuyển hóa các kính ngữ Nhật (-san, -kun, -chan, -sama, -senpai) sang cách gọi tiếng Việt tự nhiên và tương xứng với mức độ thân thiết.
- Ngữ khí: Biểu cảm sống động, giàu cảm xúc tuổi trẻ, đối thoại gãy gọn dí dỏm, giữ đúng tính cách từng nhân vật (tsundere, kuudere, nhiệt huyết, hài hước...).''';

      case 'fantasy':
      case 'western':
        return '''
[THỂ LOẠI: KỲ ẢO PHƯƠNG TÂY / FANTASY]
- Xưng hô & Chức vị: Giữ ngữ khí trang trọng cho các tước hiệu, chức vị hiệp sĩ, ma pháp sư (Lãnh chúa, Kỵ sĩ, Đại pháp sư, Điện hạ, Bệ hạ, Ngài - Tôi...).
- Phép thuật & Địa danh: Dịch thoát nghĩa mượt mà tên ma pháp, chủng tộc (Elf -> Yêu tinh/Tinh linh, Dwarf -> Người lùn, Orc -> Thú nhân...).''';

      case 'modern':
      case 'romance':
      case 'urban':
      default:
        return '''
[THỂ LOẠI: HIỆN ĐẠI / ĐÔ THỊ / NGÔN TÌNH]
- Xưng hô nhân vật: Tôi - Bạn, Anh - Em, Tôi - Cô, Mày - Tao (khi thân mật hoặc căng thẳng), Bố - Con, Mẹ - Con...
- Ngữ khí: Đời thường, tự nhiên, gần gũi, sử dụng khẩu ngữ hiện đại phù hợp ngữ cảnh, đối thoại chân thực như người Việt nói chuyện hàng ngày.''';
    }
  }
}

