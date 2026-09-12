import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdfx/pdfx.dart';

import '../llm/llm.dart';

/// A file the user attached to a coach message.
class Attachment {
  final String name;
  final Uint8List bytes;

  const Attachment(this.name, this.bytes);

  String get extension => name.contains('.') ? name.split('.').last.toLowerCase() : '';

  bool get isImage => const {'png', 'jpg', 'jpeg', 'webp', 'gif'}.contains(extension);
  bool get isPdf => extension == 'pdf';
  bool get isText => const {'csv', 'txt', 'md', 'json', 'log', 'tsv'}
      .contains(extension);

  String get imageMime =>
      extension == 'png' ? 'image/png' : extension == 'webp' ? 'image/webp' : extension == 'gif' ? 'image/gif' : 'image/jpeg';

  static const supportedExtensions = [
    'png', 'jpg', 'jpeg', 'webp', 'gif', 'csv', 'txt', 'md', 'json', 'log', 'tsv', 'pdf',
  ];
}

/// Turns a user message plus attachments into a multimodal chat message:
/// images and rendered PDF pages travel as data URLs, text-like files are
/// inlined. Everything goes only to the user's configured endpoint.
Future<ChatMessage> buildUserMessage(String text, List<Attachment> attachments) async {
  final textBlocks = <String>[if (text.trim().isNotEmpty) text.trim()];
  final images = <String>[];

  for (final a in attachments) {
    if (a.isImage) {
      images.add('data:${a.imageMime};base64,${base64Encode(a.bytes)}');
    } else if (a.isPdf) {
      try {
        final pages = await renderPdfPages(a.bytes);
        images.addAll(pages);
        textBlocks.add('[The user attached PDF "${a.name}" — ${pages.length} page(s) '
            'are included as images. Read them carefully before answering.]');
      } catch (e) {
        textBlocks.add('[The user attached PDF "${a.name}" but it could not be read: $e]');
      }
    } else if (a.isText) {
      const maxChars = 12000;
      var body = utf8.decode(a.bytes, allowMalformed: true);
      final truncated = body.length > maxChars;
      if (truncated) body = body.substring(0, maxChars);
      textBlocks.add('[Attached file "${a.name}"]\n$body'
          '${truncated ? "\n[...truncated by the app for length...]" : ""}');
    } else {
      textBlocks.add('[The user attached unsupported file "${a.name}".]');
    }
  }

  final joined = textBlocks.join('\n\n');
  if (images.isEmpty) return ChatMessage.user(joined);
  return ChatMessage.userWithParts(joined, images);
}

/// Renders the first pages of a PDF to PNG data URLs so a vision model can read it.
Future<List<String>> renderPdfPages(Uint8List bytes, {int maxPages = 4}) async {
  final document = await PdfDocument.openData(bytes);
  final urls = <String>[];
  try {
    for (var n = 1; n <= math.min(document.pagesCount, maxPages); n++) {
      final page = await document.getPage(n);
      try {
        final longest = math.max(page.width, page.height);
        final scale = (1080 / longest).clamp(0.5, 2.0);
        final image = await page.render(
          width: (page.width * scale).roundToDouble(),
          height: (page.height * scale).roundToDouble(),
          format: PdfPageImageFormat.png,
          backgroundColor: '#FFFFFF',
        );
        if (image != null) {
          urls.add('data:image/png;base64,${base64Encode(image.bytes)}');
        }
      } finally {
        await page.close();
      }
    }
  } finally {
    await document.close();
  }
  return urls;
}
