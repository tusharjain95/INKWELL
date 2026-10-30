import 'package:flutter/services.dart';

final RegExp _itemRx = RegExp(r'^(\s*)(\d{1,3})([.)])(\s+)(.*)$');
final RegExp _emptyItemRx = RegExp(r'^\s*\d{1,3}[.)]\s*$');

/// For plain text fields: after a line such as "1. milk", pressing Enter starts
/// the next line with "2. ". Pressing Enter on an empty item ("2. ") removes
/// the marker and ends the list.
class NumberedListFormatter extends TextInputFormatter {
  const NumberedListFormatter();

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    // Only react to exactly one newline typed at the caret.
    if (newValue.text.length != oldValue.text.length + 1) return newValue;
    final sel = newValue.selection;
    if (!sel.isValid || !sel.isCollapsed) return newValue;
    final i = sel.baseOffset;
    final text = newValue.text;
    if (i < 1 || i > text.length || text[i - 1] != '\n') return newValue;

    final lineStart = i - 2 < 0 ? 0 : text.lastIndexOf('\n', i - 2) + 1;
    final line = text.substring(lineStart, i - 1);

    if (_emptyItemRx.hasMatch(line)) {
      // Enter on an empty item: drop the marker and the new line, end the list.
      return TextEditingValue(
        text: text.substring(0, lineStart) + text.substring(i),
        selection: TextSelection.collapsed(offset: lineStart),
      );
    }
    final m = _itemRx.firstMatch(line);
    if (m == null) return newValue;
    final next = (int.parse(m.group(2)!) + 1);
    final marker = '${m.group(1)}$next${m.group(3)}${m.group(4)}';
    return TextEditingValue(
      text: text.substring(0, i) + marker + text.substring(i),
      selection: TextSelection.collapsed(offset: i + marker.length),
    );
  }
}

/// Matches a line that is just a number marker typed at the start of a line,
/// e.g. "1." or "12)" followed by a space. Used by the rich-text editor.
final RegExp kNumberMarkerLine = RegExp(r'^\d{1,3}[.)] $');
