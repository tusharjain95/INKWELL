import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/reminders.dart';
import '../core/share_intake.dart';
import '../core/store.dart';
import '../sync/sync_service.dart';
import '../sync/update_service.dart';
import 'editor_page.dart';
import 'format.dart';
import 'quick_add.dart';
import 'task_bar.dart';
import 'settings_page.dart';
import 'update_dialog.dart';

/// Width at which the layout switches to list + editor side by side.
const double _kWide = 920;

class NotesPage extends StatefulWidget {
  const NotesPage({super.key});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  final TextEditingController _searchCtl = TextEditingController();
  String _search = '';
  String? _tag;
  bool _trash = false;
  NoteView _view = NoteView.all;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkUpdate());
    final reminders = context.read<ReminderService>();
    reminders.openNote.addListener(_openFromNotification);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openFromNotification());
    final intake = context.read<ShareIntake>();
    intake.openNote.addListener(_openShared);
    intake.warning.addListener(_showShareWarning);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openShared());
  }

  bool _dragging = false;

  void _openShared() {
    if (!mounted) return;
    final intake = context.read<ShareIntake>();
    final id = intake.openNote.value;
    if (id == null) return;
    intake.openNote.value = null;
    if (context.read<NoteStore>().byId(id) == null) return;
    if (_trash) setState(() => _trash = false);
    _open(id, MediaQuery.sizeOf(context).width >= _kWide);
  }

  void _showShareWarning() {
    if (!mounted) return;
    final intake = context.read<ShareIntake>();
    final msg = intake.warning.value;
    if (msg == null) return;
    intake.warning.value = null;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _dropped(List<String> paths) async {
    final files = [for (final p in paths) File(p)]
        .where((f) => FileSystemEntity.typeSync(f.path) == FileSystemEntityType.file)
        .toList();
    if (files.isEmpty) return;
    await context.read<ShareIntake>().createNoteFrom(files: files);
  }

  void _openFromNotification() {
    if (!mounted) return;
    final reminders = context.read<ReminderService>();
    final id = reminders.openNote.value;
    if (id == null) return;
    reminders.openNote.value = null;
    if (context.read<NoteStore>().byId(id) == null) return;
    _open(id, MediaQuery.sizeOf(context).width >= _kWide);
  }

  @override
  void dispose() {
    context.read<ReminderService>().openNote.removeListener(_openFromNotification);
    final intake = context.read<ShareIntake>();
    intake.openNote.removeListener(_openShared);
    intake.warning.removeListener(_showShareWarning);
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _checkUpdate() async {
    final svc = context.read<UpdateService>();
    if (!svc.supported) return;
    try {
      final info = await svc.check();
      if (info == null || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Inkwell ${info.version} is available'),
        duration: const Duration(seconds: 12),
        action: SnackBarAction(
          label: 'Update',
          onPressed: () => showUpdateDialog(context, info),
        ),
      ));
    } catch (_) {
      // Offline or rate limited: try again next launch.
    }
  }

  void _open(String id, bool wide) {
    if (wide) {
      setState(() => _selectedId = id);
    } else {
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => EditorScreen(noteId: id),
      ));
    }
  }

  Future<void> _newNote() async {
    final wide = MediaQuery.sizeOf(context).width >= _kWide;
    // Started from the Tasks / Today view: make a task (due today in Today).
    final today = DateTime.now();
    final n = await context.read<NoteStore>().create(
          task: _view != NoteView.all,
          due: _view == NoteView.today
              ? DateTime(today.year, today.month, today.day)
              : null,
        );
    if (!mounted) return;
    if (_trash) setState(() => _trash = false);
    _open(n.id, wide);
  }

  Future<void> _quickAdd({bool listen = false}) async {
    final wide = MediaQuery.sizeOf(context).width >= _kWide;
    final n = await showQuickAdd(context, startListening: listen);
    if (n == null || !mounted) return;
    if (wide) setState(() => _selectedId = n.id);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(n.isTask ? 'Task added' : 'Note added'),
      action: SnackBarAction(label: 'Open', onPressed: () => _open(n.id, wide)),
    ));
  }

  Future<void> _syncPressed() async {
    final sync = context.read<SyncService>();
    final messenger = ScaffoldMessenger.of(context);
    if (!sync.configured) {
      await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
      return;
    }
    await sync.syncNow();
    messenger.showSnackBar(SnackBar(
      content: Text(sync.lastError ?? sync.lastMessage ?? 'Synced'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NoteStore>();
    final wide = MediaQuery.sizeOf(context).width >= _kWide;
    final cs = Theme.of(context).colorScheme;

    final selected = _selectedId != null && store.byId(_selectedId!) != null
        ? _selectedId
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(_trash ? 'Trash' : 'Inkwell',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          Consumer<SyncService>(
            builder: (context, sync, _) {
              final Widget icon;
              if (sync.running) {
                icon = const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                );
              } else if (!sync.configured) {
                icon = const Icon(Icons.cloud_off_outlined);
              } else if (sync.lastError != null) {
                icon = Icon(Icons.sync_problem_outlined, color: cs.error);
              } else {
                icon = const Icon(Icons.cloud_done_outlined);
              }
              return IconButton(
                tooltip: sync.running
                    ? 'Syncing…'
                    : !sync.configured
                        ? 'Set up sync'
                        : (sync.lastError ?? 'Sync now'),
                icon: icon,
                onPressed: sync.running ? null : _syncPressed,
              );
            },
          ),
          IconButton(
            tooltip: _trash ? 'Back to notes' : 'Trash',
            icon: Icon(_trash ? Icons.notes : Icons.delete_outline),
            onPressed: () => setState(() {
              _trash = !_trash;
              _selectedId = null;
            }),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsPage())),
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: _trash
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton.small(
                  heroTag: 'quick-add',
                  tooltip: 'Quick add (type or speak)',
                  onPressed: () => _quickAdd(listen: true),
                  child: const Icon(Icons.mic),
                ),
                const SizedBox(height: 12),
                FloatingActionButton.extended(
                  heroTag: 'new-note',
                  onPressed: _newNote,
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(_view == NoteView.all ? 'New note' : 'New task'),
                ),
              ],
            ),
      body: _withDrop(wide
          ? Row(
              children: [
                SizedBox(width: 380, child: _buildList(context, store, wide)),
                const VerticalDivider(width: 1),
                Expanded(
                  child: selected != null
                      ? EditorPane(
                          key: ValueKey(selected),
                          noteId: selected,
                          onClose: () => setState(() => _selectedId = null),
                        )
                      : const _EmptyDetail(),
                ),
              ],
            )
          : _buildList(context, store, wide)),
    );
  }

  /// Windows: drop files onto the window to make a note with them attached.
  Widget _withDrop(Widget child) {
    if (!Platform.isWindows) return child;
    final cs = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (d) {
        setState(() => _dragging = false);
        _dropped([for (final f in d.files) f.path]);
      },
      child: Stack(
        children: [
          Positioned.fill(child: child),
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: cs.primary.withValues(alpha: 0.12),
                  alignment: Alignment.center,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Drop to create a note with these files',
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, NoteStore store, bool wide) {
    final cs = Theme.of(context).colorScheme;
    final tags = store.allTags.toList()..sort();
    if (_tag != null && !tags.contains(_tag)) _tag = null;
    final notes = store.query(search: _search, tag: _tag, trash: _trash, view: _view);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: TextField(
            controller: _searchCtl,
            onChanged: (v) => setState(() => _search = v),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: cs.surfaceContainerHigh,
              hintText: _trash ? 'Search trash' : 'Search notes',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _search.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        _searchCtl.clear();
                        _search = '';
                      }),
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (!_trash)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final (v, label) in [
                  (NoteView.all, 'All'),
                  (NoteView.tasks, 'Tasks (${store.openTaskCount})'),
                  (NoteView.today, 'Today (${store.dueTodayCount})'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: _view == v,
                      onSelected: (_) => setState(() => _view = v),
                    ),
                  ),
              ],
            ),
          ),
        if (!_trash && tags.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final t in tags)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text('#$t'),
                      selected: _tag == t,
                      onSelected: (s) => setState(() => _tag = s ? t : null),
                    ),
                  ),
              ],
            ),
          ),
        if (_trash && notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text('Deleted notes stay here until you empty the trash.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant)),
                ),
                TextButton(
                  onPressed: () => store.emptyTrash(),
                  child: const Text('Empty trash'),
                ),
              ],
            ),
          ),
        Expanded(
          child: notes.isEmpty
              ? _EmptyList(trash: _trash, searching: _search.isNotEmpty || _tag != null)
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 96, top: 4),
                  itemCount: notes.length,
                  itemBuilder: (context, i) {
                    final n = notes[i];
                    return NoteCard(
                      note: n,
                      selected: wide && n.id == _selectedId,
                      onTap: () => _open(n.id, wide),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class NoteCard extends StatelessWidget {
  const NoteCard({
    super.key,
    required this.note,
    required this.selected,
    required this.onTap,
  });

  final Note note;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final store = context.read<NoteStore>();

    AttachmentRef? thumb;
    for (final a in note.attachments) {
      if (a.isImage && store.hasBlob(a.hash)) {
        thumb = a;
        break;
      }
    }

    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: selected ? cs.secondaryContainer : cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (note.isTask)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: Checkbox(
                                value: note.done,
                                onChanged: (_) => store.toggleDone(note.id),
                              ),
                            ),
                          ),
                        Expanded(
                          child: Text(
                            note.title.trim().isEmpty ? 'Untitled' : note.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              decoration:
                                  note.done ? TextDecoration.lineThrough : null,
                              color: note.done ? cs.onSurfaceVariant : null,
                            ),
                          ),
                        ),
                        if (note.pinned)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Icon(Icons.push_pin, size: 16, color: cs.primary),
                          ),
                      ],
                    ),
                    if (note.plain.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          note.plain,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ),
                    if (note.isTask &&
                        (note.due != null || note.priority > 0))
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(
                          spacing: 10,
                          runSpacing: 2,
                          children: [
                            if (note.due != null)
                              _MiniInfo(
                                Icons.event_outlined,
                                fmtDue(note.due!, hasTime: note.dueHasTime),
                                note.isOverdue ? cs.error : cs.onSurfaceVariant,
                              ),
                            if (note.repeat != null)
                              _MiniInfo(Icons.repeat, note.repeat!.label,
                                  cs.onSurfaceVariant),
                            if (note.priority > 0)
                              _MiniInfo(Icons.flag, priorityLabel(note.priority),
                                  priorityColor(cs, note.priority)),
                          ],
                        ),
                      ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Text(fmtWhen(note.updatedAt),
                            style: text.labelSmall
                                ?.copyWith(color: cs.onSurfaceVariant)),
                        if (note.attachments.isNotEmpty) ...[
                          const SizedBox(width: 10),
                          Icon(Icons.attach_file, size: 14, color: cs.onSurfaceVariant),
                          Text('${note.attachments.length}',
                              style: text.labelSmall
                                  ?.copyWith(color: cs.onSurfaceVariant)),
                        ],
                        if (note.tags.isNotEmpty) ...[
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              note.tags.take(3).map((t) => '#$t').join('  '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.labelSmall?.copyWith(color: cs.primary),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (thumb != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(
                      File(store.blobFile(thumb.hash).path),
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      cacheWidth: 192,
                      errorBuilder: (_, __, ___) => const SizedBox(width: 64, height: 64),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniInfo extends StatelessWidget {
  const _MiniInfo(this.icon, this.label, this.color);

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 3),
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: color)),
        ],
      );
}

class _EmptyList extends StatelessWidget {
  const _EmptyList({required this.trash, required this.searching});

  final bool trash;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final icon = trash
        ? Icons.delete_outline
        : searching
            ? Icons.search_off
            : Icons.edit_note;
    final title = trash
        ? 'Trash is empty'
        : searching
            ? 'No matching notes'
            : 'No notes yet';
    final sub = trash || searching
        ? null
        : 'Tap New note to write, or the mic to say “remind me to call Rahul '
            'friday 3pm”.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: cs.outline),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (sub != null) ...[
              const SizedBox(height: 4),
              Text(sub,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: cs.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_stories_outlined, size: 64, color: cs.outlineVariant),
          const SizedBox(height: 12),
          Text('Select a note or create a new one',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}
