import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/setup_code.dart';
import '../core/settings.dart';
import '../sync/sync_service.dart';

/// Move this device's setup to another device with one text code.
class SetupTransfer extends StatelessWidget {
  const SetupTransfer({super.key});

  Future<String?> _askPin(BuildContext context, String title, String hint) {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'PIN',
            helperText: hint,
            helperMaxLines: 3,
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _create(BuildContext context) async {
    final settings = context.read<AppSettings>();
    final messenger = ScaffoldMessenger.of(context);
    final pin = await _askPin(context, 'Choose a PIN',
        'At least ${SetupCode.minPin} characters. You type it on the other device.');
    if (pin == null || !context.mounted) return;
    try {
      final code = await SetupCode.create(settings, pin);
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Your setup code'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Send this to your other device (Telegram "Saved messages" works well), '
                  'then choose "Enter a setup code" there and type the PIN.'),
              const SizedBox(height: 12),
              SelectableText(code,
                  maxLines: 6, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code));
                messenger.showSnackBar(const SnackBar(content: Text('Copied')));
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy'),
            ),
          ],
        ),
      );
    } on SetupCodeException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _enter(BuildContext context) async {
    final settings = context.read<AppSettings>();
    final sync = context.read<SyncService>();
    final messenger = ScaffoldMessenger.of(context);
    final ctl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter a setup code'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(hintText: 'INKWELL1.…'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Next')),
        ],
      ),
    );
    ctl.dispose();
    if (code == null || code.trim().isEmpty || !context.mounted) return;
    final pin = await _askPin(context, 'Enter the PIN', 'The PIN you chose when making the code.');
    if (pin == null) return;
    try {
      final data = await SetupCode.decode(code, pin);
      final summary = await SetupCode.apply(settings, data);
      messenger.showSnackBar(SnackBar(content: Text(summary)));
      sync.maybeAutoSync();
    } on SetupCodeException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not apply the code: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Copy your sync sign-in, backup passphrase and Telegram bot to a new '
          'phone or PC in one step. The code is encrypted with a PIN you choose. '
          'It does not turn on the Telegram hub: keep that on one device only.',
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: () => _create(context),
              icon: const Icon(Icons.upload_outlined),
              label: const Text('Make a setup code'),
            ),
            OutlinedButton.icon(
              onPressed: () => _enter(context),
              icon: const Icon(Icons.download_outlined),
              label: const Text('Enter a setup code'),
            ),
          ],
        ),
      ],
    );
  }
}
