import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:inkwell/core/models.dart';
import 'package:inkwell/core/pdf_export.dart';

Note note({
  String title = 'T',
  String body = '',
  String plain = '',
  List<AttachmentRef> attachments = const [],
  bool task = false,
}) =>
    Note(
      id: 'a',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 2),
      title: title,
      body: body,
      plain: plain,
      attachments: attachments,
      isTask: task,
      due: task ? DateTime(2026, 3, 4, 9, 30) : null,
      dueHasTime: task,
      priority: task ? 1 : 0,
    );

Future<ByteData> diskFont(String asset) async {
  final b = await File(asset).readAsBytes();
  return ByteData.sublistView(Uint8List.fromList(b));
}

void main() {
  group('parseDelta', () {
    test('plain lines and formatting', () {
      final lines = parseDelta(jsonEncode([
        {'insert': 'Hello '},
        {'insert': 'bold', 'attributes': {'bold': true}},
        {'insert': '\n'},
        {'insert': 'Title'},
        {'insert': '\n', 'attributes': {'header': 2}},
      ]));
      expect(lines.length, 2);
      expect(lines[0].text, 'Hello bold');
      expect(lines[0].spans[1].bold, isTrue);
      expect(lines[1].kind, 'h2');
    });

    test('lists are numbered per run and restart after a break', () {
      final lines = parseDelta(jsonEncode([
        {'insert': 'a'},
        {'insert': '\n', 'attributes': {'list': 'ordered'}},
        {'insert': 'b'},
        {'insert': '\n', 'attributes': {'list': 'ordered'}},
        {'insert': 'break\n'},
        {'insert': 'c'},
        {'insert': '\n', 'attributes': {'list': 'ordered'}},
      ]));
      expect(lines.where((l) => l.kind == 'number').map((l) => l.number), [1, 2, 1]);
    });

    test('checklists and bullets', () {
      final lines = parseDelta(jsonEncode([
        {'insert': 'x'},
        {'insert': '\n', 'attributes': {'list': 'checked'}},
        {'insert': 'y'},
        {'insert': '\n', 'attributes': {'list': 'unchecked'}},
        {'insert': 'z'},
        {'insert': '\n', 'attributes': {'list': 'bullet', 'indent': 1}},
      ]));
      expect(lines.map((l) => l.kind), ['done', 'todo', 'bullet']);
      expect(lines[2].indent, 1);
    });

    test('embeds are skipped and bad JSON falls back to plain text', () {
      final a = parseDelta(jsonEncode([
        {'insert': {'image': 'x.png'}},
        {'insert': 'ok\n'},
      ]));
      expect(a.single.text, 'ok');
      final b = parseDelta('not json', fallback: 'one\ntwo');
      expect(b.map((l) => l.text), ['one', 'two']);
    });

    test('empty body uses the fallback and trailing blanks are dropped', () {
      expect(parseDelta('', fallback: 'hi').single.text, 'hi');
      final l = parseDelta(jsonEncode([
        {'insert': 'a\n\n\n'},
      ]));
      expect(l.length, 1);
    });
  });

  test('pdfFileName is safe', () {
    expect(pdfFileName([note(title: 'a/b:c*')]), 'a_b_c_.pdf');
    expect(pdfFileName([note(title: '')]), 'note.pdf');
    expect(pdfFileName([note(), note()]), 'inkwell-export.pdf');
    expect(pdfFileName([note(), note()], label: 'inkwell-tasks'), 'inkwell-tasks.pdf');
  });

  test('prepareImage shrinks large images and flattens transparency', () {
    final big = img.Image(width: 3200, height: 1600, numChannels: 4);
    img.fill(big, color: img.ColorRgba8(10, 20, 30, 128));
    final out = prepareImage(Uint8List.fromList(img.encodePng(big)));
    expect(out, isNotNull);
    expect(out!.width, 1600);
    expect(out.height, 800);
    expect(prepareImage(Uint8List.fromList([1, 2, 3])), isNull);
  });

  group('PdfExporter', () {
    test('builds a PDF for a note, a task and a missing attachment', () async {
      final dir = await Directory.systemTemp.createTemp('pdf');
      final png = File('${dir.path}/pic.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 40, height: 30)));
      const pic = AttachmentRef(hash: 'h1', name: 'pic.png', mime: 'image/png', size: 10);
      const doc = AttachmentRef(hash: 'h2', name: 'a.pdf', mime: 'application/pdf', size: 2048);
      const gone = AttachmentRef(hash: 'h3', name: 'x.zip', mime: 'application/zip', size: 5);

      final ex = PdfExporter(
        fonts: diskFont,
        fetch: (r) async => r.hash == 'h1' ? png : (r.hash == 'h2' ? png : null),
      );
      final bytes = await ex.build([
        note(
          title: 'Plan',
          body: jsonEncode([
            {'insert': 'Line one\n'},
          ]),
          attachments: [pic, doc, gone],
        ),
        note(title: 'Do it', task: true, plain: 'task text'),
      ], const PdfExportOptions(pageBreakPerNote: true));

      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, greaterThan(1000));
      await dir.delete(recursive: true);
    });

    test('attachments off still works', () async {
      final ex = PdfExporter(fonts: diskFont, fetch: (_) async => null);
      final bytes = await ex.build(
        [note(plain: 'hello')],
        const PdfExportOptions(includeAttachments: false),
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });
  });
}
