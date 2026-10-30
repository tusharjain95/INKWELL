import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/settings.dart';
import '../core/speech.dart';
import '../core/store.dart';
import 'attachment_widgets.dart';
import 'format.dart';
import 'numbered_input.dart';
import 'task_bar.dart';

/// Full-screen editor used on narrow (phone) layouts.
class EditorScreen extends StatelessWidget {
  const EditorScreen({super.key, required this.noteId});

  final String noteId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: EditorPane(
          key: ValueKey(noteId),
          noteId: noteId,
          showBack: true,
          onClose: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }
}

/// The note editor: title, rich-text body, tags and attachments. Used as a
/// full screen on phones and as the right-hand pane on desktop.
///
/// Edits are saved automatically (debounced) and flushed when the pane closes.
class EditorPane extends StatefulWidget {
  const EditorPane({
    super.key,
    required this.noteId,
    this.showBack = false,
    this.onClose,
  });

  final String noteId;
  final bool showBack;
  final VoidCallback? onClose;

  @override
  State<EditorPane> createState() => _EditorPaneState();
}

class _EditorPaneState extends State<EditorPane> with WidgetsBindingObserver {
  late final NoteStore _store;
  late QuillController _quill;
  final TextEditingController _title = TextEditingController();
  StreamSubscription<dynamic>? _sub;
  Timer? _debounce;
  bool _pending = false;
  late DateTime _known;
  VoiceInput? _voice;
  final FocusNode _titleFocus = FocusNode();
  final FocusNode _bodyFocus = FocusNode();
  Note? _last; // shown while the store briefly has no copy (e.g. a reload)
  int _dictAt = 0;
  int _dictLen = 0;

  @override
  void initState() {
    super.initState();
    _store = context.read<NoteStore>();
    final n = _store.byId(widget.noteId)!;
    _known = n.updatedAt;
    _title.text = n.title;
    _quill = _buildController(n.body);
    _bind();
    _store.addListener(_onStore);
    WidgetsBinding.instance.addObserver(this);
  }

  // Save before the OS suspends us so a background sync sees the latest text.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _flush();
    }
  }

  QuillController _buildController(String body) {
    Document doc;
    try {
      doc = body.isEmpty
          ? Document()
          : Document.fromJson(jsonDecode(body) as List<dynamic>);
    } catch (_) {
      doc = Document()..insert(0, body);
    }
    return QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
    );
  }

  void _bind() {
    _sub = _quill.document.changes.listen((event) {
      _schedule();
      if (event.source == ChangeSource.local &&
          event.change.operations.any((o) => o.isInsert && o.data == ' ')) {
        // Edit the document after this change has been fully applied.
        scheduleMicrotask(_autoNumber);
      }
    });
  }

  bool _autoNumbering = false;

  /// Typing "1." (or "1)") and a space at the start of a line turns the line
  /// into a numbered list item. Enter then continues the list and Enter on an
  /// empty item ends it, which the editor already does for lists.
  void _autoNumber() {
    if (_autoNumbering || !mounted) return;
    final sel = _quill.selection;
    if (!sel.isValid || !sel.isCollapsed) return;
    final cursor = sel.baseOffset;
    if (cursor < 3) return;
    final text = _quill.document.toPlainText();
    if (cursor > text.length) return;
    final lineStart = cursor - 2 < 0 ? 0 : text.lastIndexOf('\n', cursor - 2) + 1;
    final line = text.substring(lineStart, cursor);
    if (!kNumberMarkerLine.hasMatch(line)) return;
    // Already in a list or other block (list, quote, code)? Leave it alone.
    final style = _quill.document.collectStyle(lineStart, 0);
    if (style.containsKey(Attribute.list.key) ||
        style.containsKey(Attribute.blockQuote.key) ||
        style.containsKey(Attribute.codeBlock.key)) {
      return;
    }
    _autoNumbering = true;
    try {
      _quill.replaceText(lineStart, line.length, '',
          TextSelection.collapsed(offset: lineStart));
      _quill.formatSelection(Attribute.ol);
    } finally {
      _autoNumbering = false;
    }
  }

  /// A sync pulled a newer version of this note while it was open and the
  /// user has nothing unsaved: show the new content.
  void _onStore() {
    if (_pending || !mounted) return;
    final n = _store.byId(widget.noteId);
    if (n == null || !n.updatedAt.isAfter(_known)) return;
    _known = n.updatedAt;

    // The note changed underneath us (a sync brought a newer version). Swap
    // the content in, but keep the cursor and keyboard where they were, or
    // typing would suddenly continue in another field.
    final bodyHadFocus = _bodyFocus.hasFocus;
    final titleHadFocus = _titleFocus.hasFocus;
    final oldSel = _quill.selection;
    final titleSel = _title.selection;

    _sub?.cancel();
    final old = _quill;
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    _title.value = TextEditingValue(
      text: n.title,
      selection: titleSel.isValid
          ? TextSelection.collapsed(
              offset: titleSel.baseOffset.clamp(0, n.title.length))
          : TextSelection.collapsed(offset: n.title.length),
    );
    _quill = _buildController(n.body);
    final max = _quill.document.length - 1;
    final off = oldSel.isValid ? oldSel.baseOffset.clamp(0, max) : max;
    _quill.updateSelection(
        TextSelection.collapsed(offset: off), ChangeSource.local);
    _bind();
    setState(() {});
    if (bodyHadFocus || titleHadFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        (titleHadFocus ? _titleFocus : _bodyFocus).requestFocus();
      });
    }
  }

  void _schedule() {
    _pending = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), _flush);
  }

  Note? _snapshot() {
    final cur = _store.byId(widget.noteId);
    if (cur == null) return null;
    return cur.copyWith(
      title: _title.text,
      body: jsonEncode(_quill.document.toDelta().toJson()),
      plain: _quill.document.toPlainText().trim(),
      updatedAt: DateTime.now().toUtc(),
    );
  }

  Future<void> _commit(Note n) async {
    _known = n.updatedAt; // so our own save is not mistaken for a remote one
    await _store.save(n);
  }

  Future<void> _flush() async {
    _debounce?.cancel();
    if (!_pending) return;
    final n = _snapshot();
    _pending = false;
    if (n != null) await _commit(n);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _voice?.stop();
    _debounce?.cancel();
    _sub?.cancel();
    _store.removeListener(_onStore);
    final store = _store;
    final id = widget.noteId;
    final n = _pending ? _snapshot() : null;
    unawaited(() async {
      if (n != null) await store.save(n);
      await store.discardIfBlank(id); // never leave empty notes behind
    }());
    _quill.dispose();
    _title.dispose();
    _titleFocus.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  // ----------------------------------------------------------------- actions

  Future<void> _togglePin() async {
    await _flush();
    final cur = _store.byId(widget.noteId);
    if (cur == null) return;
    await _commit(cur.copyWith(pinned: !cur.pinned, updatedAt: DateTime.now().toUtc()));
  }

  Future<void> _editTags() async {
    await _flush();
    final cur = _store.byId(widget.noteId);
    if (cur == null || !mounted) return;
    final ctl = TextEditingController(text: cur.tags.join(', '));
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tags'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'work, ideas, travel',
            helperText: 'Separate tags with commas',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text),
              child: const Text('Save')),
        ],
      ),
    );
    ctl.dispose();
    if (result == null) return;
    final tags = <String>{
      for (final t in result.split(','))
        if (t.trim().replaceAll('#', '').isNotEmpty) t.trim().replaceAll('#', ''),
    }.toList();
    final latest = _store.byId(widget.noteId);
    if (latest == null) return;
    await _commit(latest.copyWith(tags: tags, updatedAt: DateTime.now().toUtc()));
  }

  Future<void> _addFiles() async {
    final messenger = ScaffoldMessenger.of(context);
    final level = context.read<AppSettings>().imageCompression;
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res == null) return;
    await _flush();
    final added = <AttachmentRef>[];
    for (final f in res.files) {
      final path = f.path;
      if (path == null) continue;
      try {
        final r = await _store.importAttachment(File(path), f.name,
            level: level);
        added.add(r.ref);
        if (r.wasCompressed) {
          messenger.showSnackBar(SnackBar(
            content: Text('Compressed ${f.name}: ${fmtBytes(r.originalSize)} '
                '→ ${fmtBytes(r.ref.size)}'),
          ));
        }
      } on AttachmentTooLarge catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('${f.name}: $e')));
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Could not attach ${f.name}: $e')));
      }
    }
    final cur = _store.byId(widget.noteId);
    if (added.isEmpty || cur == null) return;
    final have = cur.attachments.map((a) => a.hash).toSet();
    await _commit(cur.copyWith(
      attachments: [...cur.attachments, ...added.where((a) => !have.contains(a.hash))],
      updatedAt: DateTime.now().toUtc(),
    ));
  }

  /// Dictate into the body at the cursor. Words appear live and are replaced
  /// by the engine's refined result as it firms up.
  Future<void> _dictate() async {
    final voice = _voice ??= context.read<VoiceInput>();
    if (voice.listening) {
      await voice.stop();
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final sel = _quill.selection;
    _dictAt = sel.isValid ? sel.start : _quill.document.length - 1;
    _dictLen = 0;
    if (sel.isValid && !sel.isCollapsed) {
      _quill.replaceText(sel.start, sel.end - sel.start, '',
          TextSelection.collapsed(offset: sel.start));
    }
    await voice.start(
      onText: (text, isFinal) {
        if (!mounted || text.isEmpty) return;
        final max = _quill.document.length - 1;
        final at = _dictAt.clamp(0, max);
        final len = _dictLen.clamp(0, max - at);
        final out = isFinal ? '$text ' : text;
        _quill.replaceText(at, len, out,
            TextSelection.collapsed(offset: at + out.length));
        _dictLen = out.length;
        if (isFinal) {
          _dictAt = at + out.length;
          _dictLen = 0;
        }
      },
      onDone: () {
        if (mounted) setState(() {});
        final err = voice.error;
        if (err != null) messenger.showSnackBar(SnackBar(content: Text(err)));
      },
    );
    if (mounted) setState(() {});
  }

  Future<void> _toggleTask() async {
    await _flush();
    final cur = _store.byId(widget.noteId);
    if (cur == null) return;
    await _commit(cur.copyWith(
      isTask: !cur.isTask,
      updatedAt: DateTime.now().toUtc(),
    ));
  }

  Future<void> _removeAttachment(AttachmentRef ref) async {
    await _flush();
    final cur = _store.byId(widget.noteId);
    if (cur == null) return;
    await _commit(cur.copyWith(
      attachments: cur.attachments.where((a) => a.hash != ref.hash).toList(),
      updatedAt: DateTime.now().toUtc(),
    ));
  }

  Future<void> _delete() async {
    final messenger = ScaffoldMessenger.of(context);
    final id = widget.noteId;
    await _flush();
    await _store.softDelete(id);
    messenger.showSnackBar(SnackBar(
      content: const Text('Moved to trash'),
      action: SnackBarAction(label: 'Undo', onPressed: () => _store.restore(id)),
    ));
    widget.onClose?.call();
  }

  Future<void> _restore() async {
    await _flush();
    await _store.restore(widget.noteId);
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final fresh = context.watch<NoteStore>().byId(widget.noteId);
    if (fresh != null) _last = fresh;
    final note = fresh ?? _last;
    if (note == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              if (widget.showBack)
                IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              const Spacer(),
              IconButton(
                tooltip: note.pinned ? 'Unpin' : 'Pin',
                icon: Icon(note.pinned ? Icons.push_pin : Icons.push_pin_outlined),
                onPressed: _togglePin,
              ),
              IconButton(
                tooltip: 'Tags',
                icon: const Icon(Icons.sell_outlined),
                onPressed: _editTags,
              ),
              IconButton(
                tooltip: 'Attach files',
                icon: const Icon(Icons.attach_file),
                onPressed: _addFiles,
              ),
              IconButton(
                tooltip: (_voice?.listening ?? false) ? 'Stop dictation' : 'Dictate',
                icon: Icon((_voice?.listening ?? false) ? Icons.stop_circle : Icons.mic_none),
                color: (_voice?.listening ?? false) ? cs.error : null,
                onPressed: _dictate,
              ),
              IconButton(
                tooltip: note.isTask ? 'Turn into a note' : 'Turn into a task',
                icon: Icon(note.isTask ? Icons.task_alt : Icons.check_circle_outline),
                onPressed: _toggleTask,
              ),
              if (note.deleted)
                IconButton(
                  tooltip: 'Restore',
                  icon: const Icon(Icons.restore_from_trash_outlined),
                  onPressed: _restore,
                )
              else
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _delete,
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TextField(
            controller: _title,
            focusNode: _titleFocus,
            onChanged: (_) => _schedule(),
            textInputAction: TextInputAction.next,
            style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            decoration: const InputDecoration(
              hintText: 'Title',
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
          ),
        ),
        if (note.isTask)
          TaskBar(
            note: note,
            onChanged: (n) async {
              await _flush();
              final cur = _store.byId(widget.noteId);
              if (cur == null) return;
              // Take only the task fields; the text may have just been saved.
              await _commit(cur.copyWith(
                done: n.done,
                due: n.due,
                dueHasTime: n.dueHasTime,
                priority: n.priority,
                repeat: n.repeat,
                updatedAt: n.updatedAt,
              ));
            },
          ),
        if (note.tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final t in note.tags)
                    ActionChip(
                      label: Text('#$t'),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: cs.secondaryContainer,
                      side: BorderSide.none,
                      onPressed: _editTags,
                    ),
                ],
              ),
            ),
          ),
        QuillSimpleToolbar(
          key: ObjectKey(_quill),
          controller: _quill,
          config: QuillSimpleToolbarConfig(
            multiRowsDisplay: false,
            showFontFamily: false,
            showFontSize: false,
            showSubscript: false,
            showSuperscript: false,
            showSearchButton: false,
            showColorButton: false,
            showBackgroundColorButton: false,
            // ignore: experimental_member_use
            showClipboardCut: false,
            // ignore: experimental_member_use
            showClipboardCopy: false,
            // ignore: experimental_member_use
            showClipboardPaste: false,
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: QuillEditor.basic(
              key: ObjectKey(_quill),
              controller: _quill,
              focusNode: _bodyFocus,
              config: QuillEditorConfig(
                placeholder: 'Start writing…',
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              ),
            ),
          ),
        ),
        if (note.attachments.isNotEmpty)
          AttachmentStrip(
            attachments: note.attachments,
            onRemove: _removeAttachment,
          ),
      ],
    );
  }
}
