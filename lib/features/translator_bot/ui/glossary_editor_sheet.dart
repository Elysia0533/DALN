import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/models/translation_models.dart';
import '../core/storage/bot_database.dart';

class GlossaryEditorSheet extends StatefulWidget {
  final String profileId;
  final String storyTitle;

  const GlossaryEditorSheet({
    super.key,
    required this.profileId,
    required this.storyTitle,
  });

  static Future<void> show(BuildContext context, {required String profileId, required String storyTitle}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GlossaryEditorSheet(profileId: profileId, storyTitle: storyTitle),
    );
  }

  @override
  State<GlossaryEditorSheet> createState() => _GlossaryEditorSheetState();
}

class _GlossaryEditorSheetState extends State<GlossaryEditorSheet> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final BotDatabase _db = BotDatabase.instance;

  TranslationProfile? _profile;
  List<GlossaryTerm> _terms = [];
  List<AddressRule> _addressRules = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    _profile = await _db.getProfile(widget.profileId);
    _terms = await _db.getTermsByProfile(widget.profileId);
    _addressRules = await _db.getAddressRulesByProfile(widget.profileId);
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _addTermDialog() async {
    final srcCtrl = TextEditingController();
    final tgtCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    var type = GlossaryType.character;

    try {
      await showDialog(
        context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Thêm thuật ngữ / Tên riêng'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: srcCtrl,
                  decoration: const InputDecoration(labelText: 'Từ gốc (vd: Lin Feng, 林风)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: tgtCtrl,
                  decoration: const InputDecoration(labelText: 'Bản dịch (vd: Lâm Phong)'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<GlossaryType>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: 'Loại'),
                  items: GlossaryType.values.map((t) {
                    return DropdownMenuItem(value: t, child: Text(t.name));
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) setDialogState(() => type = v);
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: noteCtrl,
                  decoration: const InputDecoration(labelText: 'Ghi chú / Vai trò (tùy chọn)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.pinkAccent),
              onPressed: () async {
                if (srcCtrl.text.trim().isEmpty || tgtCtrl.text.trim().isEmpty) return;
                final term = GlossaryTerm(
                  id: 'term_${DateTime.now().microsecondsSinceEpoch}',
                  profileId: widget.profileId,
                  source: srcCtrl.text.trim(),
                  target: tgtCtrl.text.trim(),
                  type: type,
                  note: noteCtrl.text.trim(),
                );
                await _db.saveGlossaryTerm(term);
                if (ctx.mounted) Navigator.pop(ctx);
                _loadData();
              },
              child: const Text('Lưu'),
            ),
          ],
        ),
      ),
    );
    } finally {
      srcCtrl.dispose();
      tgtCtrl.dispose();
      noteCtrl.dispose();
    }
  }

  Future<void> _addAddressRuleDialog() async {
    final speakerCtrl = TextEditingController();
    final listenerCtrl = TextEditingController();
    final selfCtrl = TextEditingController();
    final otherCtrl = TextEditingController();

    try {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Thêm quy tắc xưng hô'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: speakerCtrl,
                  decoration: const InputDecoration(labelText: 'Người nói (vd: Lâm Phong)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: listenerCtrl,
                  decoration: const InputDecoration(labelText: 'Người nghe (vd: Tô Tuyết)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: selfCtrl,
                  decoration: const InputDecoration(labelText: 'Tự xưng (vd: ta, anh, tôi)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: otherCtrl,
                  decoration: const InputDecoration(labelText: 'Gọi đối phương (vd: nàng, em, cô)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.pinkAccent),
              onPressed: () async {
                if (speakerCtrl.text.trim().isEmpty || listenerCtrl.text.trim().isEmpty) return;
                final rule = AddressRule(
                  id: 'addr_${DateTime.now().microsecondsSinceEpoch}',
                  profileId: widget.profileId,
                  speaker: speakerCtrl.text.trim(),
                  listener: listenerCtrl.text.trim(),
                  selfRef: selfCtrl.text.trim(),
                  otherRef: otherCtrl.text.trim(),
                );
                await _db.saveAddressRule(rule);
                if (ctx.mounted) Navigator.pop(ctx);
                _loadData();
              },
              child: const Text('Lưu'),
            ),
          ],
        ),
      );
    } finally {
      speakerCtrl.dispose();
      listenerCtrl.dispose();
      selfCtrl.dispose();
      otherCtrl.dispose();
    }
  }

  void _exportJson() {
    final map = {
      'story': widget.storyTitle,
      'preset': _profile?.preset ?? 'modern',
      'style_guide': _profile?.styleGuide ?? '',
      'terms': _terms.map((t) => t.toMap()).toList(),
      'address_rules': _addressRules.map((a) => a.toMap()).toList(),
    };
    final jsonStr = const JsonEncoder.withIndent('  ').convert(map);
    Clipboard.setData(ClipboardData(text: jsonStr));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Đã sao chép cấu hình Glossary (JSON) vào bộ nhớ tạm 📋')),
    );
  }

  Future<void> _importJsonDialog() async {
    final ctrl = TextEditingController();
    try {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Nhập Glossary từ JSON'),
          content: TextField(
            controller: ctrl,
            maxLines: 8,
            decoration: const InputDecoration(
              hintText: 'Dán mã JSON chứa danh sách terms & address_rules vào đây...',
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.pinkAccent),
              onPressed: () async {
                try {
                  final decoded = jsonDecode(ctrl.text.trim()) as Map<String, dynamic>;
                  if (decoded['terms'] is List) {
                    for (final item in decoded['terms']) {
                      final term = GlossaryTerm.fromMap(Map<String, dynamic>.from(item));
                      await _db.saveGlossaryTerm(term);
                    }
                  }
                  if (decoded['address_rules'] is List) {
                    for (final item in decoded['address_rules']) {
                      final rule = AddressRule.fromMap(Map<String, dynamic>.from(item));
                      await _db.saveAddressRule(rule);
                    }
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                  _loadData();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Đã nạp thành công dữ liệu Glossary! 🌸')),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Lỗi định dạng JSON: $e')),
                    );
                  }
                }
              },
              child: const Text('Nhập'),
            ),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.withAlpha(100),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Cấu hình thuật ngữ & Xưng hô 📖',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        widget.storyTitle,
                        style: const TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.file_upload_outlined),
                  tooltip: 'Xuất JSON',
                  onPressed: _exportJson,
                ),
                IconButton(
                  icon: const Icon(Icons.file_download_outlined),
                  tooltip: 'Nhập JSON',
                  onPressed: _importJsonDialog,
                ),
              ],
            ),
          ),
          TabBar(
            controller: _tabController,
            indicatorColor: Colors.pinkAccent,
            labelColor: Colors.pinkAccent,
            tabs: const [
              Tab(text: 'Tên & Thuật ngữ'),
              Tab(text: 'Xưng hô'),
              Tab(text: 'Văn phong'),
            ],
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Colors.pinkAccent))
                : TabBarView(
                    controller: _tabController,
                    children: [
                      // Tab 1: Glossary Terms
                      Scaffold(
                        body: _terms.isEmpty
                            ? const Center(
                                child: Text('Chưa có thuật ngữ nào.\nBấm + để thêm tên nhân vật/địa danh.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                              )
                            : ListView.builder(
                                itemCount: _terms.length,
                                itemBuilder: (ctx, i) {
                                  final t = _terms[i];
                                  return ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: Colors.pink.withAlpha(30),
                                      child: Text(t.source.isNotEmpty ? t.source[0].toUpperCase() : '?', style: const TextStyle(color: Colors.pinkAccent)),
                                    ),
                                    title: Text('${t.source}  ➔  ${t.target}', style: const TextStyle(fontWeight: FontWeight.bold)),
                                    subtitle: Text('${t.type.name}${t.note.isNotEmpty ? " • ${t.note}" : ""}'),
                                  );
                                },
                              ),
                        floatingActionButton: FloatingActionButton.small(
                          backgroundColor: Colors.pinkAccent,
                          onPressed: _addTermDialog,
                          child: const Icon(Icons.add, color: Colors.white),
                        ),
                      ),

                      // Tab 2: Address Rules
                      Scaffold(
                        body: _addressRules.isEmpty
                            ? const Center(
                                child: Text('Chưa có quy tắc xưng hô.\nBấm + để thêm quan hệ giữa 2 nhân vật.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                              )
                            : ListView.builder(
                                itemCount: _addressRules.length,
                                itemBuilder: (ctx, i) {
                                  final r = _addressRules[i];
                                  return ListTile(
                                    leading: const Icon(Icons.people_outline, color: Colors.pinkAccent),
                                    title: Text('${r.speaker}  ➔  ${r.listener}'),
                                    subtitle: Text('Tự xưng: "${r.selfRef}" • Gọi: "${r.otherRef}"'),
                                  );
                                },
                              ),
                        floatingActionButton: FloatingActionButton.small(
                          backgroundColor: Colors.pinkAccent,
                          onPressed: _addAddressRuleDialog,
                          child: const Icon(Icons.add, color: Colors.white),
                        ),
                      ),

                      // Tab 3: Style Guide & Presets
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Preset phong cách văn học:', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              children: [
                                ChoiceChip(
                                  label: const Text('Cổ trang / Tiên hiệp'),
                                  selected: _profile?.preset == 'ancient',
                                  onSelected: (s) {
                                    if (s && _profile != null) {
                                      setState(() => _profile!.preset = 'ancient');
                                      _db.saveProfile(_profile!);
                                    }
                                  },
                                ),
                                ChoiceChip(
                                  label: const Text('Hiện đại'),
                                  selected: _profile?.preset == 'modern',
                                  onSelected: (s) {
                                    if (s && _profile != null) {
                                      setState(() => _profile!.preset = 'modern');
                                      _db.saveProfile(_profile!);
                                    }
                                  },
                                ),
                                ChoiceChip(
                                  label: const Text('Học đường (tớ - cậu)'),
                                  selected: _profile?.preset == 'school',
                                  onSelected: (s) {
                                    if (s && _profile != null) {
                                      setState(() => _profile!.preset = 'school');
                                      _db.saveProfile(_profile!);
                                    }
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            const Text('Quy tắc văn phong (Style Guide):', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.grey.withAlpha(25),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  _profile?.styleGuide.isNotEmpty == true
                                      ? _profile!.styleGuide
                                      : 'Chưa có ghi chú đặc biệt. Bạn có thể gửi một đoạn dịch mẫu để Ellie tự động rút trích style guide 🌸',
                                  style: const TextStyle(fontSize: 14, height: 1.5),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
