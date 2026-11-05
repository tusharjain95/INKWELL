import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'store.dart';

/// Keys the Android widgets read. shared_preferences stores them in the
/// "FlutterSharedPreferences" file with a "flutter." prefix, which the
/// native code in MainActivity / the widget provider reads directly.
const String kWidgetTasksKey = 'inkwell.widget.tasks';
const String kWidgetNotesKey = 'inkwell.widget.notes';

const int kWidgetMaxItems = 30;

/// What a widget row shows. Pure and testable.
///
/// Tasks: open tasks, overdue first, then soonest due, then by priority;
/// tasks without a due date come last. Notes: pinned first, then newest.
Map<String, String> buildWidgetPayload(List<Note> all, DateTime now) {
  final live = all.where((n) => !n.deleted && !n.isBlank).toList();
  final today = DateTime(now.year, now.month, now.day);

  final tasks = live.where((t) => t.isTask && !t.done).toList()
    ..sort((a, b) {
      final ad = a.due, bd = b.due;
      if (ad != null && bd != null) {
        final c = ad.compareTo(bd);
        if (c != 0) return c;
      } else if (ad != null) {
        return -1;
      } else if (bd != null) {
        return 1;
      }
      final ap = a.priority == 0 ? 9 : a.priority;
      final bp = b.priority == 0 ? 9 : b.priority;
      final c = ap.compareTo(bp);
      return c != 0 ? c : b.updatedAt.compareTo(a.updatedAt);
    });

  final notes = live.where((n) => !n.isTask).toList()
    ..sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });

  String dueLabel(Note t) {
    final d = t.due;
    if (d == null) return '';
    final day = DateTime(d.year, d.month, d.day);
    final diff = day.difference(today).inDays;
    String when;
    if (diff == 0) {
      when = 'Today';
    } else if (diff == 1) {
      when = 'Tomorrow';
    } else if (diff == -1) {
      when = 'Yesterday';
    } else {
      const m = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      when = '${d.day} ${m[d.month - 1]}';
    }
    if (t.dueHasTime) {
      when = '$when ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return when;
  }

  Map<String, dynamic> taskRow(Note t) => {
        'id': t.id,
        'title': t.title.trim().isEmpty
            ? (t.plain.trim().isEmpty ? 'Untitled' : _firstLine(t.plain))
            : t.title.trim(),
        'sub': dueLabel(t),
        'overdue': t.isOverdue,
        'prio': t.priority,
      };

  Map<String, dynamic> noteRow(Note n) => {
        'id': n.id,
        'title': n.title.trim().isEmpty
            ? (n.plain.trim().isEmpty ? 'Untitled' : _firstLine(n.plain))
            : n.title.trim(),
        'sub': n.title.trim().isEmpty ? '' : _firstLine(n.plain),
        'pinned': n.pinned,
      };

  return {
    kWidgetTasksKey: jsonEncode({
      'count': tasks.length,
      'items': [for (final t in tasks.take(kWidgetMaxItems)) taskRow(t)],
    }),
    kWidgetNotesKey: jsonEncode({
      'count': notes.length,
      'items': [for (final n in notes.take(kWidgetMaxItems)) noteRow(n)],
    }),
  };
}

String _firstLine(String s) {
  for (final l in s.split('\n')) {
    final t = l.trim();
    if (t.isNotEmpty) return t.length > 120 ? t.substring(0, 120) : t;
  }
  return '';
}

/// Keeps the Android home-screen widgets in step with the notes.
///
/// Writes the payload to shared preferences (also works from the background
/// sync worker) and asks the native side to redraw (foreground only).
class WidgetSync {
  WidgetSync(this.store);

  final NoteStore store;
  static const MethodChannel _channel = MethodChannel('inkwell/share');
  Timer? _debounce;
  bool _started = false;

  static bool get supported => Platform.isAndroid;

  void start() {
    if (!supported || _started) return;
    _started = true;
    store.addListener(_schedule);
    _schedule();
  }

  void dispose() {
    _debounce?.cancel();
    if (_started) store.removeListener(_schedule);
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1500), () => push(store));
  }

  /// Writes the current lists and, when [refresh] is set, redraws the widgets.
  static Future<void> push(NoteStore store, {bool refresh = true}) async {
    if (!supported) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = buildWidgetPayload(store.all, DateTime.now());
      for (final e in payload.entries) {
        await prefs.setString(e.key, e.value);
      }
      if (refresh) await _channel.invokeMethod<void>('refreshWidgets');
    } catch (_) {
      // No widgets, or running without the activity: nothing to do.
    }
  }
}
