import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

const sampleOpfMetadata = '''
<dc:title>Trời Xanh</dc:title>
<dc:creator>Nguyễn An</dc:creator>
<dc:subject>Tiên Hiệp</dc:subject>
<dc:description>A short description.</dc:description>
''';

Uint8List epubMetadataFixture({
  String metadata = sampleOpfMetadata,
  String? container,
  String? opf,
  bool compress = true,
  Map<String, List<int>> extraEntries = const {},
  bool includeContainer = true,
  bool includeOpf = true,
}) {
  final archive = Archive();
  void add(String name, List<int> bytes, bool compressed) {
    archive.addFile(
      ArchiveFile(name, bytes.length, bytes)..compress = compressed,
    );
  }

  add('mimetype', utf8.encode('application/epub+zip'), false);
  for (final entry in extraEntries.entries) {
    add(entry.key, entry.value, false);
  }
  if (includeContainer) {
    add(
      'META-INF/container.xml',
      utf8.encode(
        container ??
            '''
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
<rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''',
      ),
      compress,
    );
  }
  if (includeOpf) {
    add(
      'OPS/book.opf',
      utf8.encode(
        opf ??
            '''
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">$metadata</metadata>
<manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
</package>''',
      ),
      compress,
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

// Deliberate corruption of encoder-generated fixtures, never a production ZIP parser.
Uint8List corruptEpubEntry(
  Uint8List bytes,
  String name, {
  int? crc,
  int? size,
  int? flags,
  int? method,
  String? rename,
}) {
  final output = Uint8List.fromList(bytes);
  final data = ByteData.sublistView(output);
  final directory = ZipDirectory.read(InputStream(bytes));
  var position = directory.centralDirectoryOffset;
  for (final header in directory.fileHeaders) {
    final nameLength = data.getUint16(position + 28, Endian.little);
    final extraLength = data.getUint16(position + 30, Endian.little);
    final commentLength = data.getUint16(position + 32, Endian.little);
    if (header.filename == name) {
      final local = header.localHeaderOffset!;
      if (crc != null) {
        data.setUint32(position + 16, crc, Endian.little);
        data.setUint32(local + 14, crc, Endian.little);
      }
      if (size != null) {
        data.setUint32(position + 24, size, Endian.little);
        data.setUint32(local + 22, size, Endian.little);
      }
      if (flags != null) {
        data.setUint16(position + 8, flags, Endian.little);
        data.setUint16(local + 6, flags, Endian.little);
      }
      if (method != null) {
        data.setUint16(position + 10, method, Endian.little);
        data.setUint16(local + 8, method, Endian.little);
      }
      if (rename != null) {
        final replacement = utf8.encode(rename);
        if (replacement.length != nameLength) {
          throw ArgumentError('Fixture name length must match.');
        }
        output.setRange(position + 46, position + 46 + nameLength, replacement);
        output.setRange(local + 30, local + 30 + nameLength, replacement);
      }
      return output;
    }
    position += 46 + nameLength + extraLength + commentLength;
  }
  throw ArgumentError('Fixture entry not found.');
}
