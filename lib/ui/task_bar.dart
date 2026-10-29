import 'package:flutter/material.dart';

import '../core/models.dart';
import 'format.dart';

/// Colour for a priority level (1 = high, 3 = low).
Color priorityColor(ColorScheme cs, int p) => switch (p) {
      1 => cs.error,
      2 => cs.tertiary,
      _ => cs.outline,
    };

/// Task controls shown under the title in the editor: done toggle, due
/// date/time, priority and repeat. Calls [onChanged] with the edited note.
class TaskBar extends StatelessWidget {
  const TaskBar({super.key, required this.note, required this.onChanged});

  final Note note;
  final ValueChanged<Note> onChanged;

  Note _stamp(Note n) => n.copyWith(updatedAt: DateTime.now().toUtc());

  Future<void> _pickDate(BuildContext context) async {
    final now = DateTime.now();
    final cur = note.due ?? now;
    final d = await showDatePicker(
      context: context,
      initialDate: cur,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
    );
    if (d == null) return;
    final keep = note.due;
    onChanged(_stamp(note.copyWith(
      due: note.dueHasTime && keep != null
          ? DateTime(d.year, d.month, d.day, keep.hour, keep.minute)
          : DateTime(d.year, d.month, d.day),
    )));
  }

  Future<void> _pickTime(BuildContext context) async {
    final cur = note.due ?? DateTime.now();
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: cur.hour, minute: cur.minute),
    );
    if (t == null) return;
    final base = note.due ?? DateTime.now();
    onChanged(_stamp(note.copyWith(
      due: DateTime(base.year, base.month, base.day, t.hour, t.minute),
      dueHasTime: true,
    )));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final due = note.due;
    final overdue = note.isOverdue;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 20, 8),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 4,
        children: [
          Checkbox(
            value: note.done,
            onChanged: (_) => onChanged(_stamp(note.copyWith(done: !note.done))),
          ),
          ActionChip(
            avatar: Icon(Icons.event_outlined,
                size: 18, color: overdue ? cs.error : null),
            label: Text(
              due == null ? 'Due date' : fmtDue(due, hasTime: false),
              style: TextStyle(color: overdue ? cs.error : null),
            ),
            visualDensity: VisualDensity.compact,
            onPressed: () => _pickDate(context),
          ),
          if (due != null)
            ActionChip(
              avatar: const Icon(Icons.schedule, size: 18),
              label: Text(note.dueHasTime ? fmtTime(due) : 'Add time'),
              visualDensity: VisualDensity.compact,
              onPressed: () => _pickTime(context),
            ),
          if (due != null)
            IconButton(
              tooltip: 'Clear due date',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => onChanged(_stamp(
                  note.copyWith(due: null, dueHasTime: false, repeat: null))),
            ),
          PopupMenuButton<int>(
            tooltip: 'Priority',
            initialValue: note.priority,
            onSelected: (v) => onChanged(_stamp(note.copyWith(priority: v))),
            itemBuilder: (_) => [
              for (final p in [0, 1, 2, 3])
                PopupMenuItem(value: p, child: Text(priorityLabel(p))),
            ],
            child: Chip(
              avatar: Icon(Icons.flag_outlined,
                  size: 18,
                  color: note.priority == 0
                      ? null
                      : priorityColor(cs, note.priority)),
              label: Text(note.priority == 0
                  ? 'Priority'
                  : priorityLabel(note.priority)),
              visualDensity: VisualDensity.compact,
            ),
          ),
          if (due != null)
            PopupMenuButton<String>(
              tooltip: 'Repeat',
              onSelected: (v) {
                final Repeat? r = switch (v) {
                  'none' => null,
                  'day' => const Repeat('day'),
                  'week' => const Repeat('week'),
                  'month' => const Repeat('month'),
                  _ => const Repeat('year'),
                };
                onChanged(_stamp(note.copyWith(repeat: r)));
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'none', child: Text('Does not repeat')),
                PopupMenuItem(value: 'day', child: Text('Every day')),
                PopupMenuItem(value: 'week', child: Text('Every week')),
                PopupMenuItem(value: 'month', child: Text('Every month')),
                PopupMenuItem(value: 'year', child: Text('Every year')),
              ],
              child: Chip(
                avatar: const Icon(Icons.repeat, size: 18),
                label: Text(note.repeat?.label ?? 'Repeat'),
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
    );
  }
}
