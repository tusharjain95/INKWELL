import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/nlp.dart';
import '../core/settings.dart';
import '../core/speech.dart';
import '../core/store.dart';
import 'format.dart';
import 'task_bar.dart';

/// Opens the Quick Add sheet. Resolves to the created note, or null.
Future<Note?> showQuickAdd(BuildContext context, {bool startListening = false}) {
  return showModalBottomSheet<Note>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => QuickAddSheet(startListening: startListening),
  );
}

enum _Kind { auto, task, note }

/// Type or speak a sentence such as "remind me to call Rahul friday 3pm !1
/// #work". It is parsed on the device, previewed live and saved as a task or a
/// note.
class QuickAddSheet extends StatefulWidget {
  const QuickAddSheet({super.key, this.startListening = false});

  final bool startListening;

  @override
  State<QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends State<QuickAddSheet> {
  final TextEditingController _ctl = TextEditingController();
  _Kind _kind = _Kind.auto;
  late final VoiceInput _voice;

  @override
  void initState() {
    super.initState();
    _voice = context.read<VoiceInput>();
    _ctl.addListener(() => setState(() {}));
    if (widget.startListening) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _toggleMic());
    }
  }

  @override
  void dispose() {
    _voice.stop();
    _ctl.dispose();
    super.dispose();
  }

  ParsedEntry _parse() {
    final dayFirst = context.read<AppSettings>().dayFirstDates;
    final raw = _ctl.text.trim();
    final text = switch (_kind) {
      _Kind.auto => raw,
      _Kind.task => raw.isEmpty ? raw : 'task: $raw',
      _Kind.note => raw.isEmpty ? raw : 'note: $raw',
    };
    return parseEntry(text, dayFirst: dayFirst);
  }

  Future<void> _toggleMic() async {
    if (_voice.listening) {
      await _voice.stop();
      return;
    }
    final base = _ctl.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    await _voice.start(
      onText: (text, isFinal) {
        if (!mounted) return;
        final joined = base.isEmpty ? text : '$base $text';
        _ctl.value = TextEditingValue(
          text: joined,
          selection: TextSelection.collapsed(offset: joined.length),
        );
      },
      onDone: () {
        if (!mounted) return;
        setState(() {});
        final err = _voice.error;
        if (err != null) messenger.showSnackBar(SnackBar(content: Text(err)));
      },
    );
  }

  Future<void> _save() async {
    final e = _parse();
    if (e.isEmpty) return;
    final store = context.read<NoteStore>();
    await _voice.stop();
    final n = await store.createFromEntry(e);
    if (mounted) Navigator.pop(context, n);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final e = _parse();
    final listening = context.select<VoiceInput, bool>((v) => v.listening);
    final onDevice = context.select<AppSettings, bool>((s) => s.onDeviceSpeech);

    final chips = <Widget>[
      if (e.due != null)
        _PreviewChip(Icons.event_outlined, fmtDue(e.due!, hasTime: e.hasTime)),
      if (e.priority > 0)
        _PreviewChip(Icons.flag_outlined, priorityLabel(e.priority),
            color: priorityColor(cs, e.priority)),
      if (e.repeat != null) _PreviewChip(Icons.repeat, e.repeat!.label),
      for (final t in e.tags) _PreviewChip(Icons.tag, t),
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Quick add', style: text.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Try “remind me to call Rahul friday 3pm !1 #work” or “note: '
            'idea for the trip”.',
            style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctl,
            autofocus: !widget.startListening,
            minLines: 2,
            maxLines: 5,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: listening ? 'Listening…' : 'Type or tap the mic',
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              suffixIcon: IconButton(
                tooltip: listening ? 'Stop' : 'Speak',
                color: listening ? cs.error : cs.primary,
                icon: Icon(listening ? Icons.stop_circle : Icons.mic),
                onPressed: _toggleMic,
              ),
            ),
          ),
          if (listening)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                onDevice
                    ? 'Asking your device to recognise speech offline where it can.'
                    : 'Using your device’s speech service, which may be online.',
                style: text.labelSmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 12),
          SegmentedButton<_Kind>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _Kind.auto, label: Text('Auto')),
              ButtonSegment(value: _Kind.task, label: Text('Task')),
              ButtonSegment(value: _Kind.note, label: Text('Note')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 12),
          if (!e.isEmpty) ...[
            Row(
              children: [
                Icon(e.isTask ? Icons.task_alt : Icons.notes,
                    size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    e.title.isEmpty ? 'Untitled' : e.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall,
                  ),
                ),
              ],
            ),
            if (chips.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 4, children: chips),
            ],
          ],
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: e.isEmpty ? null : _save,
              icon: const Icon(Icons.check),
              label: Text(e.isTask ? 'Add task' : 'Add note'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewChip extends StatelessWidget {
  const _PreviewChip(this.icon, this.label, {this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) => Chip(
        avatar: Icon(icon, size: 16, color: color),
        label: Text(label),
        visualDensity: VisualDensity.compact,
      );
}
