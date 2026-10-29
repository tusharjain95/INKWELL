import 'package:flutter/material.dart';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _hm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// "14:05", "Yesterday", "12 Oct" or "12 Oct 2025".
String fmtWhen(DateTime utc) {
  final d = utc.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return _hm(d);
  if (diff == 1) return 'Yesterday';
  if (d.year == now.year) return '${d.day} ${_months[d.month - 1]}';
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

String fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1048576).toStringAsFixed(1)} MB';
}

IconData iconForMime(String mime, String name) {
  final n = name.toLowerCase();
  if (mime.startsWith('image/')) return Icons.image_outlined;
  if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
  if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
  if (mime.startsWith('video/')) return Icons.movie_outlined;
  if (mime.startsWith('text/')) return Icons.description_outlined;
  if (n.endsWith('.xlsx') || n.endsWith('.xls') || n.endsWith('.csv')) {
    return Icons.table_chart_outlined;
  }
  if (n.endsWith('.docx') || n.endsWith('.doc')) return Icons.article_outlined;
  if (n.endsWith('.zip') || n.endsWith('.rar') || n.endsWith('.7z')) {
    return Icons.folder_zip_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String fmtTime(DateTime d) => _hm(d);

/// "Today 17:00", "Tomorrow", "Fri 30 Oct", "3 Nov 2027".
String fmtDue(DateTime d, {required bool hasTime}) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = day.difference(today).inDays;
  final String date;
  if (diff == 0) {
    date = 'Today';
  } else if (diff == 1) {
    date = 'Tomorrow';
  } else if (diff == -1) {
    date = 'Yesterday';
  } else if (diff > 1 && diff < 7) {
    date = _weekdays[d.weekday - 1];
  } else if (d.year == now.year) {
    date = '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
  } else {
    date = '${d.day} ${_months[d.month - 1]} ${d.year}';
  }
  return hasTime ? '$date ${_hm(d)}' : date;
}

String priorityLabel(int p) => switch (p) {
      1 => 'High',
      2 => 'Medium',
      3 => 'Low',
      _ => 'None',
    };
