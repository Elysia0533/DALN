// Data models representing paragraph and sub-chunk units for smart TTS reading.


class TtsSubChunk {
  final String id;
  final String text;
  final int startOffset;
  final int endOffset;
  final int paragraphIndex;
  final int subChunkIndex;

  const TtsSubChunk({
    required this.id,
    required this.text,
    required this.startOffset,
    required this.endOffset,
    required this.paragraphIndex,
    required this.subChunkIndex,
  });

  @override
  String toString() =>
      'TtsSubChunk(id: $id, pIdx: $paragraphIndex, subIdx: $subChunkIndex, len: ${text.length})';
}

class TtsParagraph {
  final String id;
  final String text;
  final int paragraphIndex;
  final int? chapterIndex;
  final List<TtsSubChunk> subChunks;

  const TtsParagraph({
    required this.id,
    required this.text,
    required this.paragraphIndex,
    this.chapterIndex,
    required this.subChunks,
  });

  bool get isSplit => subChunks.length > 1;

  @override
  String toString() =>
      'TtsParagraph(id: $id, pIdx: $paragraphIndex, subChunks: ${subChunks.length}, len: ${text.length})';
}
