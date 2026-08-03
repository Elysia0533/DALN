import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

class EpubExportService {
  static final EpubExportService instance = EpubExportService._internal();
  factory EpubExportService() => instance;
  EpubExportService._internal();

  /// Clean raw text/HTML content into sanitized plain text for EPUB formatting
  static String cleanTextForEpub(String rawContent) {
    if (rawContent.isEmpty) return '';

    String text = rawContent;

    // 1. Remove vbook-text:// prefix
    if (text.startsWith('vbook-text://')) {
      text = text.substring(13);
    }

    final List<String> extractedNotes = [];

    // 2. Extract HTML note elements (<div class="note...">, <span class="footnote">, etc.)
    final noteRegExp = RegExp(
      r'<(div|span|blockquote|p|aside)[^>]*(?:note|footnote|annotation|chu-thich)[^>]*>(.*?)</\1>',
      caseSensitive: false,
      dotAll: true,
    );

    text = text.replaceAllMapped(noteRegExp, (match) {
      final noteText = match.group(2) ?? '';
      final cleanedNote = noteText.replaceAll(RegExp(r'<[^>]*>'), '').trim();
      if (cleanedNote.isNotEmpty) {
        extractedNotes.add(cleanedNote);
      }
      return '';
    });

    // 3. Decode common double-encoded HTML entities
    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&ensp;', ' ')
        .replaceAll('&emsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");

    // 4. Replace HTML paragraph and line break tags with newlines
    text = text
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'</div>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'</li>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<p[^>]*>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<div[^>]*>', caseSensitive: false), '');

    // 5. Strip remaining HTML tags
    text = text.replaceAll(RegExp(r'<[^>]*>'), '');

    // 6. Decode ampersands
    text = text.replaceAll('&amp;', '&').trim();

    // 7. Append extracted HTML notes to the end of the chapter
    if (extractedNotes.isNotEmpty) {
      text += '\n\n--- GHI CHÚ / CHÚ THÍCH THÀNH PHẦN ---\n';
      for (int i = 0; i < extractedNotes.length; i++) {
        text += '[Ghi chú ${i + 1}]: ${extractedNotes[i]}\n';
      }
    }

    return text;
  }

  /// Export offline chapters into a standard .epub file
  Future<File?> exportToEpub({
    required String storyTitle,
    required String author,
    required List<Map<String, String>> chapters, // [{ 'title': ..., 'content': ... }]
  }) async {
    if (chapters.isEmpty) return null;

    final archive = Archive();

    // 1. mimetype (Must be first file and uncompressed)
    final mimetypeData = utf8.encode('application/epub+zip');
    archive.addFile(ArchiveFile('mimetype', mimetypeData.length, mimetypeData)..compress = false);

    // 2. META-INF/container.xml
    final containerXml = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
   <rootfiles>
      <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
   </rootfiles>
</container>''';
    archive.addFile(ArchiveFile('META-INF/container.xml', utf8.encode(containerXml).length, utf8.encode(containerXml)));

    // 3. Generate chapters XHTML files
    final List<String> manifestItems = [];
    final List<String> spineItems = [];
    final List<String> navPoints = [];

    for (int i = 0; i < chapters.length; i++) {
      final title = chapters[i]['title'] ?? 'Chương ${i + 1}';
      final rawContent = chapters[i]['content'] ?? '';
      
      final cleanedText = cleanTextForEpub(rawContent);

      final formattedLines = cleanedText
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .map((line) => '<p>${htmlEscape.convert(line)}</p>')
          .join('\n');

      final chapterHtml = '''<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <title>${htmlEscape.convert(title)}</title>
  <style type="text/css">
    body { font-family: sans-serif; line-height: 1.6; padding: 15px; }
    h2 { text-align: center; margin-bottom: 24px; font-size: 1.4em; }
    p { text-indent: 1.5em; margin-bottom: 0.8em; }
  </style>
</head>
<body>
  <h2>${htmlEscape.convert(title)}</h2>
  $formattedLines
</body>
</html>''';

      final filename = 'chapter_$i.html';
      archive.addFile(ArchiveFile('OEBPS/$filename', utf8.encode(chapterHtml).length, utf8.encode(chapterHtml)));

      manifestItems.add('<item id="chap_$i" href="$filename" media-type="application/xhtml+xml"/>');
      spineItems.add('<itemref idref="chap_$i"/>');
      navPoints.add('''<navPoint id="navPoint-${i + 1}" playOrder="${i + 1}">
  <navLabel><text>${htmlEscape.convert(title)}</text></navLabel>
  <content src="$filename"/>
</navPoint>''');
    }

    // 4. OEBPS/toc.ncx
    final ncxContent = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:vbook-export-${DateTime.now().millisecondsSinceEpoch}"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>${htmlEscape.convert(storyTitle)}</text></docTitle>
  <navMap>
    ${navPoints.join('\n    ')}
  </navMap>
</ncx>''';
    archive.addFile(ArchiveFile('OEBPS/toc.ncx', utf8.encode(ncxContent).length, utf8.encode(ncxContent)));

    // 5. OEBPS/content.opf
    final opfContent = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>${htmlEscape.convert(storyTitle)}</dc:title>
    <dc:creator>${htmlEscape.convert(author)}</dc:creator>
    <dc:language>vi</dc:language>
    <dc:identifier id="BookId">urn:uuid:vbook-export-${DateTime.now().millisecondsSinceEpoch}</dc:identifier>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    ${manifestItems.join('\n    ')}
  </manifest>
  <spine toc="ncx">
    ${spineItems.join('\n    ')}
  </spine>
</package>''';
    archive.addFile(ArchiveFile('OEBPS/content.opf', utf8.encode(opfContent).length, utf8.encode(opfContent)));

    // Zip and write file
    final zipEncoder = ZipEncoder();
    final epubBytes = zipEncoder.encode(archive);
    if (epubBytes == null) return null;

    final downloadsDir = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final sanitizeName = storyTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final epubFile = File('${downloadsDir.path}/$sanitizeName.epub');
    await epubFile.writeAsBytes(epubBytes);

    return epubFile;
  }
}

