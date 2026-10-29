import 'dart:math';

/// Random 80-bit id, hex encoded. Safe to use as a file name.
String newId() {
  final r = Random.secure();
  final bytes = List<int>.generate(10, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Hard cap per attachment after compression. GitHub rejects files over
/// 100 MB, and a repo full of large binaries gets slow long before that.
const int kMaxAttachmentBytes = 25 * 1024 * 1024;

/// Photos are allowed to be bigger *before* compression, since compressing
/// usually shrinks them far below [kMaxAttachmentBytes].
const int kMaxImageSourceBytes = 60 * 1024 * 1024;

/// Adds [n] months, clamping the day (31 Jan + 1 month = 28/29 Feb).
DateTime addMonths(DateTime d, int n) {
  final idx = d.month - 1 + n;
  final y = d.year + (idx / 12).floor();
  final m = idx % 12 + 1;
  final last = DateTime(y, m + 1, 0).day;
  return DateTime(y, m, d.day > last ? last : d.day, d.hour, d.minute);
}

/// How a recurring task repeats: every [interval] days / weeks / months / years.
class Repeat {
  const Repeat(this.unit, [this.interval = 1]);

  /// "day", "week", "month" or "year".
  final String unit;
  final int interval;

  Map<String, dynamic> toJson() => {'u': unit, 'n': interval};

  factory Repeat.fromJson(Map<String, dynamic> j) => Repeat(
        (j['u'] as String?) ?? 'week',
        ((j['n'] as num?)?.toInt() ?? 1).clamp(1, 1000),
      );

  /// The occurrence after [from], keeping its time of day.
  DateTime next(DateTime from) {
    switch (unit) {
      case 'day':
        return DateTime(from.year, from.month, from.day + interval, from.hour, from.minute);
      case 'month':
        return addMonths(from, interval);
      case 'year':
        return addMonths(from, 12 * interval);
      default:
        return DateTime(from.year, from.month, from.day + 7 * interval, from.hour, from.minute);
    }
  }

  String get label {
    return interval == 1 ? 'Every $unit' : 'Every $interval ${unit}s';
  }

  @override
  bool operator ==(Object other) =>
      other is Repeat && other.unit == unit && other.interval == interval;

  @override
  int get hashCode => Object.hash(unit, interval);
}

class AttachmentRef {
  const AttachmentRef({
    required this.hash,
    required this.name,
    required this.mime,
    required this.size,
  });

  /// SHA-256 (hex) of the file content. Doubles as the local file name, so the
  /// same file attached twice is stored once.
  final String hash;
  final String name;
  final String mime;
  final int size;

  bool get isImage => mime.startsWith('image/') && mime != 'image/svg+xml';
  bool get isPdf => mime == 'application/pdf';

  Map<String, dynamic> toJson() => {
        'hash': hash,
        'name': name,
        'mime': mime,
        'size': size,
      };

  factory AttachmentRef.fromJson(Map<String, dynamic> j) => AttachmentRef(
        hash: j['hash'] as String,
        name: (j['name'] as String?) ?? 'file',
        mime: (j['mime'] as String?) ?? 'application/octet-stream',
        size: (j['size'] as num?)?.toInt() ?? 0,
      );
}

const Object _keep = Object();

class Note {
  const Note({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.title = '',
    this.body = '',
    this.plain = '',
    this.tags = const [],
    this.attachments = const [],
    this.pinned = false,
    this.deleted = false,
    this.isTask = false,
    this.done = false,
    this.due,
    this.dueHasTime = false,
    this.priority = 0,
    this.repeat,
  });

  final String id;
  final String title;

  /// Quill delta as a JSON string (rich text).
  final String body;

  /// Plain-text rendering of [body], used for search and card previews.
  final String plain;
  final List<String> tags;
  final List<AttachmentRef> attachments;
  final bool pinned;

  /// Tombstone flag. Deleted notes stay in the sync repo so deletions
  /// propagate to other devices.
  final bool deleted;
  final DateTime createdAt;
  final DateTime updatedAt;

  // ---- task fields ---------------------------------------------------------
  // A task is just a note with a checkbox, a due date and a priority.

  final bool isTask;
  final bool done;

  /// Floating local time: "5 pm" means 5 pm wherever the device is. Only the
  /// date part is meaningful when [dueHasTime] is false.
  final DateTime? due;
  final bool dueHasTime;

  /// 0 none, 1 high, 2 medium, 3 low.
  final int priority;
  final Repeat? repeat;

  bool get isBlank =>
      title.trim().isEmpty && plain.trim().isEmpty && attachments.isEmpty;

  bool get isOverdue {
    final d = due;
    if (!isTask || done || d == null) return false;
    final now = DateTime.now();
    return dueHasTime
        ? d.isBefore(now)
        : d.isBefore(DateTime(now.year, now.month, now.day));
  }

  /// [due] and [repeat] accept null to clear them; omit to keep the current value.
  Note copyWith({
    String? id,
    String? title,
    String? body,
    String? plain,
    List<String>? tags,
    List<AttachmentRef>? attachments,
    bool? pinned,
    bool? deleted,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isTask,
    bool? done,
    Object? due = _keep,
    bool? dueHasTime,
    int? priority,
    Object? repeat = _keep,
  }) =>
      Note(
        id: id ?? this.id,
        title: title ?? this.title,
        body: body ?? this.body,
        plain: plain ?? this.plain,
        tags: tags ?? this.tags,
        attachments: attachments ?? this.attachments,
        pinned: pinned ?? this.pinned,
        deleted: deleted ?? this.deleted,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        isTask: isTask ?? this.isTask,
        done: done ?? this.done,
        due: identical(due, _keep) ? this.due : due as DateTime?,
        dueHasTime: dueHasTime ?? this.dueHasTime,
        priority: priority ?? this.priority,
        repeat: identical(repeat, _keep) ? this.repeat : repeat as Repeat?,
      );

  Map<String, dynamic> toJson() => {
        'v': 1,
        'id': id,
        'title': title,
        'body': body,
        'plain': plain,
        'tags': tags,
        'attachments': attachments.map((a) => a.toJson()).toList(),
        'pinned': pinned,
        'deleted': deleted,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        // Task fields are omitted for plain notes, so older apps and older
        // files stay compatible in both directions.
        if (isTask) 'task': true,
        if (done) 'done': true,
        if (due != null) 'due': due!.toIso8601String(),
        if (dueHasTime) 'dueTime': true,
        if (priority != 0) 'prio': priority,
        if (repeat != null) 'repeat': repeat!.toJson(),
      };

  factory Note.fromJson(Map<String, dynamic> j) => Note(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? '',
        body: (j['body'] as String?) ?? '',
        plain: (j['plain'] as String?) ?? '',
        tags: ((j['tags'] as List?) ?? const []).cast<String>(),
        attachments: ((j['attachments'] as List?) ?? const [])
            .map((e) => AttachmentRef.fromJson(e as Map<String, dynamic>))
            .toList(),
        pinned: (j['pinned'] as bool?) ?? false,
        deleted: (j['deleted'] as bool?) ?? false,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num).toInt(),
            isUtc: true),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['updatedAt'] as num).toInt(),
            isUtc: true),
        isTask: (j['task'] as bool?) ?? false,
        done: (j['done'] as bool?) ?? false,
        due: j['due'] is String ? DateTime.tryParse(j['due'] as String) : null,
        dueHasTime: (j['dueTime'] as bool?) ?? false,
        priority: ((j['prio'] as num?)?.toInt() ?? 0).clamp(0, 3),
        repeat: j['repeat'] is Map
            ? Repeat.fromJson((j['repeat'] as Map).cast<String, dynamic>())
            : null,
      );
}
