import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../sync/update_service.dart';

Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(info: info),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info});

  final UpdateInfo info;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _busy = false;
  double? _progress;
  String? _error;

  Future<void> _go() async {
    final svc = context.read<UpdateService>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await svc.download(widget.info, (p) {
        if (mounted) setState(() => _progress = p);
      });
      await svc.install(file);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('Update to ${info.version}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (info.notes.trim().isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: SingleChildScrollView(child: Text(info.notes)),
              ),
            if (_busy) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: cs.error)),
            ],
            if (Platform.isAndroid && !_busy) ...[
              const SizedBox(height: 12),
              Text(
                'Android will ask you to confirm the install. Your notes are kept.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: _busy ? null : _go,
          child: Text(Platform.isAndroid ? 'Download & install' : 'Install & restart'),
        ),
      ],
    );
  }
}
