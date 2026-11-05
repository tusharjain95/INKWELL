import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'models.dart';

/// Choices offered in the export dialog.
class PdfExportOptions {
  const PdfExportOptions({
    this.includeAttachments = true,
    this.pageBreakPerNote = false,
    this.title,
  });

  final bool includeAttachments;
  final bool pageBreakPerNote;

  /// Cover title used when exporting several notes.
  final String? title;
}

// ---------------------------------------------------------------- delta

/// One line or paragraph of a note, reduced to what the PDF needs.
class PdfLine {
  PdfLine(this.spans, {this.kind = 'p', this.indent = 0, this.number = 0});

  final List<PdfSpan> spans;

  /// p, h1, h2, h3, bullet, number, todo, done, quote, code.
  String kind;
  int indent;

  /// 1-based position for numbered lists.
  int number;

  String get text => spans.map((s) => s.text).join();
}

class PdfSpan {
  const PdfSpan(this.text,
      {this.bold = false,
      this.italic = false,
      this.underline = false,
      this.strike = false,
      this.link = false,
      this.mono = false});

  final String text;
  final bool bold, italic, underline, strike, link, mono;
}

/// Turns a Quill delta (JSON string) into lines. Never throws: a body that
/// cannot be parsed is treated as plain text.
List<PdfLine> parseDelta(String body, {String fallback = ''}) {
  List<dynamic> ops;
  try {
    final j = body.trim().isEmpty ? <dynamic>[] : jsonDecode(body);
    ops = j is List ? j : (j is Map && j['ops'] is List ? j['ops'] as List : const []);
  } catch (_) {
    ops = const [];
  }
  if (ops.isEmpty) {
    return [
      for (final l in fallback.split('\n')) PdfLine([PdfSpan(l)]),
    ];
  }

  final lines = <PdfLine>[];
  var cur = <PdfSpan>[];
  for (final op in ops) {
    if (op is! Map) continue;
    final ins = op['insert'];
    if (ins is! String) continue; // embeds (images etc.) are skipped
    final attrs = (op['attributes'] is Map)
        ? (op['attributes'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final parts = ins.split('\n');
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part.isNotEmpty) {
        cur.add(PdfSpan(
          part,
          bold: attrs['bold'] == true,
          italic: attrs['italic'] == true,
          underline: attrs['underline'] == true,
          strike: attrs['strike'] == true,
          link: attrs['link'] != null,
          mono: attrs['code'] == true,
        ));
      }
      // Every piece except the last ends with a newline, and the newline
      // carries the block formatting for the line it closes.
      if (i < parts.length - 1) {
        lines.add(_closeLine(cur, attrs));
        cur = <PdfSpan>[];
      }
    }
  }
  if (cur.isNotEmpty) lines.add(PdfLine(cur));

  // Number consecutive ordered items per indent level.
  final counters = <int, int>{};
  for (final l in lines) {
    if (l.kind == 'number') {
      counters.removeWhere((k, _) => k > l.indent);
      l.number = (counters[l.indent] ?? 0) + 1;
      counters[l.indent] = l.number;
    } else {
      counters.clear();
    }
  }
  // Drop trailing blank lines.
  while (lines.isNotEmpty && lines.last.kind == 'p' && lines.last.text.trim().isEmpty) {
    lines.removeLast();
  }
  return lines;
}

PdfLine _closeLine(List<PdfSpan> spans, Map<String, dynamic> a) {
  var kind = 'p';
  final h = a['header'];
  if (h is num) kind = 'h${h.toInt().clamp(1, 3)}';
  final list = a['list'];
  if (list == 'bullet') kind = 'bullet';
  if (list == 'ordered') kind = 'number';
  if (list == 'unchecked') kind = 'todo';
  if (list == 'checked') kind = 'done';
  if (a['blockquote'] == true) kind = 'quote';
  if (a['code-block'] != null && a['code-block'] != false) kind = 'code';
  final ind = a['indent'];
  return PdfLine(spans, kind: kind, indent: ind is num ? ind.toInt().clamp(0, 6) : 0);
}

// ------------------------------------------------------------- images

class PreparedImage {
  const PreparedImage(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int width, height;
}

/// Decodes, downsizes and re-encodes as JPEG so a phone photo does not turn
/// the PDF into a 40 MB file. Runs in an isolate; returns null when the
/// image cannot be decoded.
PreparedImage? prepareImage(Uint8List raw) {
  try {
    var im = img.decodeImage(raw);
    if (im == null) return null;
    const maxSide = 1600;
    if (im.width > maxSide || im.height > maxSide) {
      im = im.width >= im.height
          ? img.copyResize(im, width: maxSide)
          : img.copyResize(im, height: maxSide);
    }
    // JPEG has no alpha: flatten onto white so transparent PNGs stay legible.
    if (im.hasAlpha) {
      final bg = img.Image(width: im.width, height: im.height, numChannels: 3);
      img.fill(bg, color: img.ColorRgb8(255, 255, 255));
      img.compositeImage(bg, im);
      im = bg;
    }
    final out = Uint8List.fromList(img.encodeJpg(im, quality: 80));
    return PreparedImage(out, im.width, im.height);
  } catch (_) {
    return null;
  }
}

Future<PreparedImage?> _prepareInIsolate(Uint8List raw) =>
    compute(prepareImage, raw);

// ------------------------------------------------------------- builder

typedef AttachmentFetcher = Future<File?> Function(AttachmentRef ref);
typedef PdfFontLoader = Future<ByteData> Function(String asset);

Future<ByteData> _bundleFont(String asset) => rootBundle.load(asset);

/// Builds a PDF for one or more notes. Attachments come from [fetch], which
/// may download them first; returning null (or throwing) leaves a short
/// "not available" line in the PDF instead of failing the export.
class PdfExporter {
  PdfExporter({required this.fetch, PdfFontLoader? fonts, DateTime? now})
      : _fonts = fonts ?? _bundleFont,
        _now = now ?? DateTime.now();

  final AttachmentFetcher fetch;
  final PdfFontLoader _fonts;
  final DateTime _now;

  static const _pageMargin = 40.0;
  // A4 is 595pt wide; this is the printable width.
  static const _contentWidth = 595.28 - 2 * _pageMargin;
  static const _maxImageHeight = 420.0;

  Future<Uint8List> build(
    List<Note> notes,
    PdfExportOptions opts, {
    void Function(int done, int total)? onProgress,
  }) async {
    final regular = pw.Font.ttf(await _fonts('assets/fonts/NotoSans-Regular.ttf'));
    final bold = pw.Font.ttf(await _fonts('assets/fonts/NotoSans-Bold.ttf'));
    final italic = pw.Font.ttf(await _fonts('assets/fonts/NotoSans-Italic.ttf'));
    final boldItalic =
        pw.Font.ttf(await _fonts('assets/fonts/NotoSans-BoldItalic.ttf'));
    final theme = pw.ThemeData.withFont(
      base: regular,
      bold: bold,
      italic: italic,
      boldItalic: boldItalic,
    );

    final doc = pw.Document(title: opts.title ?? _titleOf(notes), creator: 'Inkwell');
    final styles = _Styles(bold);

    // Prepare every note's content first so the page build is synchronous.
    final prepared = <_PreparedNote>[];
    for (var i = 0; i < notes.length; i++) {
      prepared.add(await _prepare(notes[i], opts));
      onProgress?.call(i + 1, notes.length);
    }

    final widgets = <pw.Widget>[];
    if (notes.length > 1) {
      widgets.add(pw.Text(opts.title ?? 'Inkwell export', style: styles.h1));
      widgets.add(pw.Text(
          '${notes.length} items · exported ${_fmtDateTime(_now)}',
          style: styles.meta));
      widgets.add(pw.SizedBox(height: 14));
    }

    for (var i = 0; i < prepared.length; i++) {
      final p = prepared[i];
      if (i > 0) {
        widgets.add(opts.pageBreakPerNote
            ? pw.NewPage()
            : pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 14),
                child: pw.Divider(color: PdfColors.grey400, thickness: 0.6),
              ));
      }
      widgets.addAll(_noteWidgets(p, styles));
    }

    doc.addPage(pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(_pageMargin),
        theme: theme,
      ),
      footer: (ctx) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('${ctx.pageNumber} / ${ctx.pagesCount}', style: styles.meta),
      ),
      build: (_) => widgets,
    ));
    return doc.save();
  }

  String _titleOf(List<Note> notes) {
    if (notes.length == 1) {
      final t = notes.first.title.trim();
      return t.isEmpty ? 'Note' : t;
    }
    return 'Inkwell export';
  }

  Future<_PreparedNote> _prepare(Note n, PdfExportOptions opts) async {
    final images = <_PreparedAttachment>[];
    final others = <_PreparedAttachment>[];
    if (opts.includeAttachments) {
      for (final a in n.attachments) {
        File? file;
        try {
          file = await fetch(a);
        } catch (_) {
          file = null;
        }
        if (file == null || !await file.exists()) {
          others.add(_PreparedAttachment(a, note: 'not available on this device'));
          continue;
        }
        if (a.isImage) {
          PreparedImage? pi;
          try {
            pi = await _prepareInIsolate(await file.readAsBytes());
          } catch (_) {
            pi = null;
          }
          if (pi == null) {
            others.add(_PreparedAttachment(a, note: 'image could not be read'));
          } else {
            images.add(_PreparedAttachment(a, image: pi));
          }
        } else {
          others.add(_PreparedAttachment(
              a,
              note: a.isPdf
                  ? 'PDF, not embedded (open it in the app)'
                  : 'not embedded (open it in the app)'));
        }
      }
    }
    return _PreparedNote(n, parseDelta(n.body, fallback: n.plain), images, others);
  }

  List<pw.Widget> _noteWidgets(_PreparedNote p, _Styles s) {
    final n = p.note;
    final out = <pw.Widget>[];
    out.add(pw.Text(n.title.trim().isEmpty ? 'Untitled' : n.title.trim(),
        style: s.h1));

    final meta = <String>[];
    if (n.isTask) {
      meta.add(n.done ? 'Task · done' : 'Task · open');
      if (n.due != null) {
        meta.add('Due ${n.dueHasTime ? _fmtDateTime(n.due!) : _fmtDate(n.due!)}');
      }
      const prio = {1: 'High priority', 2: 'Medium priority', 3: 'Low priority'};
      if (prio[n.priority] != null) meta.add(prio[n.priority]!);
      if (n.repeat != null) meta.add(n.repeat!.label);
    }
    meta.add('Updated ${_fmtDateTime(n.updatedAt.toLocal())}');
    out.add(pw.Text(meta.join(' · '), style: s.meta));
    if (n.tags.isNotEmpty) {
      out.add(pw.Text(n.tags.map((t) => '#$t').join('  '), style: s.meta));
    }
    out.add(pw.SizedBox(height: 8));

    for (final l in p.lines) {
      out.add(_line(l, s));
    }

    if (p.images.isNotEmpty) {
      out.add(pw.SizedBox(height: 10));
      for (final a in p.images) {
        final im = a.image!;
        final natural = _contentWidth * im.height / im.width;
        final h = natural > _maxImageHeight ? _maxImageHeight : natural;
        final w = natural > _maxImageHeight ? h * im.width / im.height : _contentWidth;
        out.add(pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 10),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(
                width: w,
                height: h,
                child: pw.Image(pw.MemoryImage(im.bytes), fit: pw.BoxFit.contain),
              ),
              pw.SizedBox(height: 2),
              pw.Text(a.ref.name, style: s.meta),
            ],
          ),
        ));
      }
    }

    if (p.others.isNotEmpty) {
      out.add(pw.SizedBox(height: 6));
      out.add(pw.Text('Attachments', style: s.bold));
      for (final a in p.others) {
        out.add(pw.Text('• ${a.ref.name} (${_size(a.ref.size)}) — ${a.note}',
            style: s.meta));
      }
    }
    return out;
  }

  pw.Widget _line(PdfLine l, _Styles s) {
    final base = switch (l.kind) {
      'h1' => s.heading(18),
      'h2' => s.heading(15),
      'h3' => s.heading(13),
      'code' => s.mono,
      _ => s.body,
    };
    final text = l.spans.isEmpty || l.text.isEmpty
        ? pw.SizedBox(height: base.fontSize ?? 11)
        : pw.RichText(
            text: pw.TextSpan(
              style: base,
              children: [for (final sp in l.spans) _span(sp, base, s)],
            ),
          );

    final pad = 16.0 * l.indent;
    pw.Widget wrap(pw.Widget child, {pw.Widget? lead, double leadWidth = 16}) =>
        pw.Padding(
          padding: pw.EdgeInsets.only(left: pad, bottom: 3),
          child: lead == null
              ? child
              : pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.SizedBox(width: leadWidth, child: lead),
                    pw.Expanded(child: child),
                  ],
                ),
        );

    switch (l.kind) {
      case 'bullet':
        return wrap(text, lead: pw.Text('•', style: s.body));
      case 'number':
        return wrap(text,
            lead: pw.Text('${l.number}.', style: s.body), leadWidth: 22);
      case 'todo':
      case 'done':
        final checked = l.kind == 'done';
        return wrap(
          text,
          lead: pw.Padding(
            padding: const pw.EdgeInsets.only(top: 2),
            child: pw.Container(
              width: 9,
              height: 9,
              decoration: pw.BoxDecoration(
                color: checked ? PdfColors.grey700 : null,
                border: pw.Border.all(color: PdfColors.grey700, width: 0.8),
              ),
            ),
          ),
        );
      case 'quote':
        return pw.Padding(
          padding: pw.EdgeInsets.only(left: pad, bottom: 3),
          child: pw.Container(
            padding: const pw.EdgeInsets.only(left: 8),
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                  left: pw.BorderSide(color: PdfColors.grey500, width: 2)),
            ),
            child: text,
          ),
        );
      case 'code':
        return pw.Container(
          width: double.infinity,
          color: PdfColors.grey200,
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: text,
        );
      case 'h1':
      case 'h2':
      case 'h3':
        return pw.Padding(
          padding: const pw.EdgeInsets.only(top: 6, bottom: 3),
          child: text,
        );
      default:
        return wrap(text);
    }
  }

  pw.TextSpan _span(PdfSpan sp, pw.TextStyle base, _Styles s) {
    final deco = <pw.TextDecoration>[
      if (sp.underline || sp.link) pw.TextDecoration.underline,
      if (sp.strike) pw.TextDecoration.lineThrough,
    ];
    return pw.TextSpan(
      text: sp.text,
      style: pw.TextStyle(
        fontWeight: sp.bold ? pw.FontWeight.bold : null,
        fontStyle: sp.italic ? pw.FontStyle.italic : null,
        decoration: deco.isEmpty ? null : pw.TextDecoration.combine(deco),
        color: sp.link ? PdfColors.blue800 : null,
        font: sp.mono ? pw.Font.courier() : null,
      ),
    );
  }
}

class _Styles {
  _Styles(pw.Font boldFont)
      : body = pw.TextStyle(fontSize: 11, lineSpacing: 2),
        mono = pw.TextStyle(font: pw.Font.courier(), fontSize: 10),
        meta = pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
        h1 = pw.TextStyle(font: boldFont, fontSize: 20),
        bold = pw.TextStyle(font: boldFont, fontSize: 11),
        _bold = boldFont;

  final pw.TextStyle body, mono, meta, h1, bold;
  final pw.Font _bold;

  pw.TextStyle heading(double size) => pw.TextStyle(font: _bold, fontSize: size);
}

class _PreparedAttachment {
  _PreparedAttachment(this.ref, {this.image, this.note = ''});
  final AttachmentRef ref;
  final PreparedImage? image;
  final String note;
}

class _PreparedNote {
  _PreparedNote(this.note, this.lines, this.images, this.others);
  final Note note;
  final List<PdfLine> lines;
  final List<_PreparedAttachment> images;
  final List<_PreparedAttachment> others;
}

String _two(int v) => v.toString().padLeft(2, '0');
String _fmtDate(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
String _fmtDateTime(DateTime d) => '${_fmtDate(d)} ${_two(d.hour)}:${_two(d.minute)}';

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// A safe default file name for the save dialog.
String pdfFileName(List<Note> notes, {String? label}) {
  var base = label ??
      (notes.length == 1
          ? (notes.first.title.trim().isEmpty ? 'note' : notes.first.title.trim())
          : 'inkwell-export');
  base = base.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  if (base.length > 60) base = base.substring(0, 60).trim();
  if (base.isEmpty) base = 'note';
  return '$base.pdf';
}
