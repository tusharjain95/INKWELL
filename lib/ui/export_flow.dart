import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/pdf_export.dart';
import '../sync/sync_service.dart';

/// Asks what to include, builds the PDF and lets the user choose where to
/// save it. [label] names the batch ("tasks", "notes") in the dialog.
Future<void> exportNotesPdf(
  BuildContext context,
  List<Note> notes, {
  String label = 'notes',
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final sync = context.read<SyncService>();
  final live = notes.where((n) => !n.deleted && !n.isBlank).toList();
  if (live.isEmpty) {
    messenger.showSnackBar(const SnackBar(content: Text('Nothing to export.')));
    return;
  }

  final withFiles = live.any((n) => n.attachments.isNotEmpty);
  final opts = await showDialog<PdfExportOptions>(
    context: context,
    builder: (_) => _OptionsDialog(
      count: live.length,
      label: label,
      hasAttachments: withFiles,
    ),
  );
  if (opts == null || !context.mounted) return;

  final progress = ValueNotifier<String>('Preparing…');
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.4)),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, v, __) => Text(v),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Uint8List? bytes;
  Object? failure;
  try {
    final exporter = PdfExporter(
      fetch: (ref) async {
        try {
          return await sync.ensureAttachment(ref);
        } catch (_) {
          return null;
        }
      },
    );
    bytes = await exporter.build(
      live,
      PdfExportOptions(
        includeAttachments: opts.includeAttachments,
        pageBreakPerNote: opts.pageBreakPerNote,
        title: live.length > 1 ? 'Inkwell $label' : null,
      ),
      onProgress: (d, t) => progress.value = 'Building PDF… $d of $t',
    );
  } catch (e) {
    failure = e;
  }
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  progress.dispose();

  if (failure != null || bytes == null) {
    messenger.showSnackBar(SnackBar(content: Text('Could not build the PDF: $failure')));
    return;
  }

  try {
    final name = pdfFileName(live, label: live.length > 1 ? 'inkwell-$label' : null);
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save PDF',
      fileName: name,
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      bytes: bytes,
    );
    if (path == null) return; // cancelled

    // On Android the picker writes the bytes itself. On desktop it only
    // returns a path, so write the file here.
    String? opened;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final target = path.toLowerCase().endsWith('.pdf') ? path : '$path.pdf';
      await File(target).writeAsBytes(bytes, flush: true);
      opened = target;
    }
    messenger.showSnackBar(SnackBar(
      content: Text('Saved ${live.length == 1 ? 'PDF' : '${live.length} items as one PDF'}.'),
      action: opened == null
          ? null
          : SnackBarAction(
              label: 'Open',
              onPressed: () => OpenFilex.open(opened!),
            ),
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not save the PDF: $e')));
  }
}

class _OptionsDialog extends StatefulWidget {
  const _OptionsDialog({
    required this.count,
    required this.label,
    required this.hasAttachments,
  });

  final int count;
  final String label;
  final bool hasAttachments;

  @override
  State<_OptionsDialog> createState() => _OptionsDialogState();
}

class _OptionsDialogState extends State<_OptionsDialog> {
  bool _files = true;
  bool _pages = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.count == 1
          ? 'Export as PDF'
          : 'Export ${widget.count} ${widget.label} as PDF'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.hasAttachments)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _files,
              onChanged: (v) => setState(() => _files = v ?? true),
              title: const Text('Include attachments'),
              subtitle: const Text(
                  'Images are drawn in the PDF. Other files are listed by name.'),
            ),
          if (widget.count > 1)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _pages,
              onChanged: (v) => setState(() => _pages = v ?? false),
              title: const Text('Start each item on a new page'),
            ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            PdfExportOptions(includeAttachments: _files, pageBreakPerNote: _pages),
          ),
          child: const Text('Export'),
        ),
      ],
    );
  }
}
