import 'dart:io';
import '../utils/file_name_utils.dart';

import 'package:path/path.dart' as p;

class BookFileNames {
  static String stem(String title) {
    var value = FileNameUtils.safeStem(
      title.replaceAll('\x7f', '_'),
      fallback: 'Truyen',
      maxBytes: 160,
    );
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
      caseSensitive: false,
    ).hasMatch(value)) {
      value = '_$value';
    }
    return value;
  }

  static Future<File> availableFile(
    Directory directory,
    String title,
    String extension,
  ) async {
    if (!RegExp(r'^[a-z0-9]+$').hasMatch(extension)) {
      throw ArgumentError('Invalid book extension.');
    }
    await directory.create(recursive: true);
    final name = stem(title);
    var index = 0;
    while (true) {
      final suffix = index == 0 ? '' : ' ($index)';
      final file = File(p.join(directory.path, '$name$suffix.$extension'));
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        try {
          return await file.create(exclusive: true);
        } on FileSystemException {
          if (await FileSystemEntity.type(file.path, followLinks: false) ==
              FileSystemEntityType.notFound) {
            rethrow;
          }
        }
      }
      index++;
    }
  }
}
