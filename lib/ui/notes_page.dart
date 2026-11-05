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
import 'export_flow.dart';
import 'format.dart';
import 'quick_add.dart';
import 'task_bar.dart';
import 'theme.dart';
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

  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();

  String get _heading {
    if (_trash) return 'Trash';
    if (_tag != null) return '#$_tag';
    switch (_view) {
      case NoteView.all:
        return 'Notes';
      case NoteView.tasks:
        return 'Tasks';
      case NoteView.today:
        return 'Today';
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<NoteStore>();
    final wide = MediaQuery.sizeOf(context).width >= _kWide;
    final cs = Theme.of(context).colorScheme;

    final selected = _selectedId != null && store.byId(_selectedId!) != null
        ? _selectedId
        : null;

    if (wide) {
      return Scaffold(
        key: _scaffold,
        body: _withDrop(Row(
          children: [
            SizedBox(width: 244, child: _sidebar(context, store, drawer: false)),
            SizedBox(width: 372, child: _buildList(context, store, wide)),
            VerticalDivider(width: 1, color: cs.outlineVariant),
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
        )),
      );
    }

    final tab = switch (_view) {
      NoteView.all => 0,
      NoteView.tasks => 1,
      NoteView.today => 2,
    };
    return Scaffold(
      key: _scaffold,
      drawer: Drawer(
        backgroundColor: kSidebarBg,
        child: _sidebar(context, store, drawer: true),
      ),
      body: _withDrop(SafeArea(bottom: false, child: _buildList(context, store, wide))),
      floatingActionButton: _trash
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton.small(
                  heroTag: 'quick-add',
                  tooltip: 'Quick add (type or speak)',
                  backgroundColor: cs.surface,
                  foregroundColor: cs.primary,
                  onPressed: () => _quickAdd(listen: true),
                  child: const Icon(Icons.mic),
                ),
                const SizedBox(height: 12),
                FloatingActionButton(
                  heroTag: 'new-note',
                  tooltip: _view == NoteView.all ? 'New note' : 'New task',
                  shape: const CircleBorder(),
                  onPressed: _newNote,
                  child: const Icon(Icons.add, size: 30),
                ),
              ],
            ),
      bottomNavigationBar: _trash
          ? null
          : NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (i) => setState(() {
                _view = const [NoteView.all, NoteView.tasks, NoteView.today][i];
                _tag = null;
              }),
              destinations: [
                const NavigationDestination(
                    icon: Icon(Icons.description_outlined),
                    selectedIcon: Icon(Icons.description),
                    label: 'Notes'),
                NavigationDestination(
                    icon: _badge(Icons.check_circle_outline, store.openTaskCount),
                    selectedIcon: _badge(Icons.check_circle, store.openTaskCount),
                    label: 'Tasks'),
                NavigationDestination(
                    icon: _badge(Icons.today_outlined, store.dueTodayCount),
                    selectedIcon: _badge(Icons.today, store.dueTodayCount),
                    label: 'Today'),
              ],
            ),
    );
  }

  Widget _badge(IconData icon, int n) =>
      n > 0 ? Badge(label: Text('$n'), child: Icon(icon)) : Icon(icon);

  // ----------------------------------------------------------------- sidebar

  /// The dark navigation panel: permanent on wide screens, a drawer on phones.
  Widget _sidebar(BuildContext context, NoteStore store, {required bool drawer}) {
    final tags = store.allTags.toList()..sort();

    void go(VoidCallback f) {
      setState(() {
        f();
        _selectedId = null;
      });
      if (drawer) Navigator.of(context).pop();
    }

    return Container(
      color: kSidebarBg,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: kGreen,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.edit_note, color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 10),
                  const Text('Inkwell',
                      style: TextStyle(
                          color: kOnSidebar,
                          fontSize: 19,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: kGreen,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(44),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                ),
                onPressed: () {
                  if (drawer) Navigator.of(context).pop();
                  _newNote();
                },
                icon: const Icon(Icons.add),
                label: Text(_view == NoteView.all ? 'New note' : 'New task'),
              ),
            ),
            _NavItem(
              icon: Icons.mic_none,
              label: 'Quick add',
              onTap: () {
                if (drawer) Navigator.of(context).pop();
                _quickAdd(listen: true);
              },
            ),
            const SizedBox(height: 6),
            _NavItem(
              icon: Icons.description_outlined,
              label: 'Notes',
              selected: !_trash && _tag == null && _view == NoteView.all,
              onTap: () => go(() {
                _trash = false;
                _tag = null;
                _view = NoteView.all;
              }),
            ),
            _NavItem(
              icon: Icons.check_circle_outline,
              label: 'Tasks',
              count: store.openTaskCount,
              selected: !_trash && _tag == null && _view == NoteView.tasks,
              onTap: () => go(() {
                _trash = false;
                _tag = null;
                _view = NoteView.tasks;
              }),
            ),
            _NavItem(
              icon: Icons.today_outlined,
              label: 'Today',
              count: store.dueTodayCount,
              selected: !_trash && _tag == null && _view == NoteView.today,
              onTap: () => go(() {
                _trash = false;
                _tag = null;
                _view = NoteView.today;
              }),
            ),
            _NavItem(
              icon: Icons.delete_outline,
              label: 'Trash',
              selected: _trash,
              onTap: () => go(() {
                _trash = true;
                _tag = null;
              }),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Text('TAGS',
                  style: TextStyle(
                      color: kMutedOnSidebar,
                      fontSize: 11,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: tags.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 20),
                      child: Text('Add #tags to notes to find them here.',
                          style: TextStyle(color: kMutedOnSidebar, fontSize: 12.5)),
                    )
                  : ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        for (final t in tags)
                          _NavItem(
                            icon: Icons.sell_outlined,
                            label: t,
                            selected: !_trash && _tag == t,
                            onTap: () => go(() {
                              _trash = false;
                              _view = NoteView.all;
                              _tag = t;
                            }),
                          ),
                      ],
                    ),
            ),
            const Divider(height: 1, color: Color(0x22FFFFFF)),
            Consumer<SyncService>(
              builder: (context, sync, _) {
                final (icon, label, err) = _syncInfo(sync, store);
                return _NavItem(
                  icon: icon,
                  label: label,
                  error: err,
                  onTap: sync.running ? () {} : _syncPressed,
                );
              },
            ),
            _NavItem(
              icon: Icons.settings_outlined,
              label: 'Settings',
              onTap: () {
                if (drawer) Navigator.of(context).pop();
                Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  (IconData, String, bool) _syncInfo(SyncService sync, NoteStore store) {
    if (sync.running) return (Icons.sync, 'Syncing…', false);
    if (!sync.configured) return (Icons.cloud_off_outlined, 'Set up sync', false);
    if (sync.lastError != null) {
      return (Icons.sync_problem_outlined, 'Sync problem — tap to retry', true);
    }
    final waiting = store.state.dirty.length;
    if (waiting > 0) {
      return (Icons.cloud_upload_outlined, '$waiting waiting · Sync now', false);
    }
    return (Icons.cloud_done_outlined, 'Synced · Sync now', false);
  }


  /// Exports whatever the list currently shows (view, tag and search apply).
  Future<void> _exportVisible() {
    final store = context.read<NoteStore>();
    final list =
        store.query(search: _search, tag: _tag, trash: false, view: _view);
    return exportNotesPdf(context, list,
        label: _view == NoteView.all ? 'notes' : 'tasks');
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
    final text = Theme.of(context).textTheme;
    final notes = store.query(search: _search, tag: _tag, trash: _trash, view: _view);
    final noun = _view == NoteView.all || _trash ? 'note' : 'task';

    return Container(
      color: cs.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(wide ? 20 : 4, wide ? 20 : 8, 8, 0),
            child: Row(
              children: [
                if (!wide)
                  IconButton(
                    tooltip: 'Menu',
                    icon: const Icon(Icons.menu),
                    onPressed: () => _scaffold.currentState?.openDrawer(),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_heading,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      Text('${notes.length} $noun${notes.length == 1 ? '' : 's'}',
                          style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                if (!wide)
                  Consumer<SyncService>(
                    builder: (context, sync, _) {
                      final (icon, label, err) = _syncInfo(sync, store);
                      return IconButton(
                        tooltip: label,
                        icon: Icon(icon, color: err ? cs.error : null),
                        onPressed: sync.running ? null : _syncPressed,
                      );
                    },
                  ),
                if (!_trash)
                  IconButton(
                    tooltip: _view == NoteView.all
                        ? 'Export notes as PDF'
                        : 'Export tasks as PDF',
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    onPressed: _exportVisible,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: TextField(
              controller: _searchCtl,
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: cs.surfaceContainerHigh,
                hintText: _trash ? 'Search trash' : 'Search',
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
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_trash && notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Deleted notes stay here until you empty the trash.',
                        style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ),
                  TextButton(
                    onPressed: () => store.emptyTrash(),
                    child: const Text('Empty trash'),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: notes.isEmpty
                ? _EmptyList(trash: _trash, searching: _search.isNotEmpty || _tag != null)
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 120),
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
      ),
    );
  }
}

/// One row of the dark sidebar.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.count = 0,
    this.selected = false,
    this.error = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final int count;
  final bool selected;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error
        ? const Color(0xFFFF8A80)
        : selected
            ? Colors.white
            : kOnSidebar;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? kSidebarSelected : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 20, color: selected ? kGreenOnDark : color),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: color,
                          fontSize: 14.5,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
                ),
                if (count > 0)
                  Text('$count',
                      style: const TextStyle(color: kMutedOnSidebar, fontSize: 12.5)),
              ],
            ),
          ),
        ),
      ),
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

    return Material(
      color: selected ? cs.primaryContainer.withValues(alpha: 0.55) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6)),
              left: BorderSide(
                  color: selected ? cs.primary : Colors.transparent, width: 3),
            ),
          ),
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
                    borderRadius: BorderRadius.circular(4),
                    child: Image.file(
                      File(store.blobFile(thumb.hash).path),
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                      cacheWidth: 192,
                      errorBuilder: (_, __, ___) => const SizedBox(width: 72, height: 72),
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
