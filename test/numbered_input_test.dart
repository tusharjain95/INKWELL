import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkwell/ui/numbered_input.dart';

TextEditingValue _v(String t, [int? at]) =>
    TextEditingValue(text: t, selection: TextSelection.collapsed(offset: at ?? t.length));

void main() {
  const f = NumberedListFormatter();

  test('Enter after a numbered line starts the next number', () {
    final out = f.formatEditUpdate(_v('1. milk'), _v('1. milk\n'));
    expect(out.text, '1. milk\n2. ');
    expect(out.selection.baseOffset, out.text.length);
  });

  test('continues from the current number and keeps the separator', () {
    expect(f.formatEditUpdate(_v('9) a'), _v('9) a\n')).text, '9) a\n10) ');
    expect(f.formatEditUpdate(_v('x\n3. c'), _v('x\n3. c\n')).text, 'x\n3. c\n4. ');
  });

  test('Enter on an empty item ends the list', () {
    final out = f.formatEditUpdate(_v('1. a\n2. '), _v('1. a\n2. \n'));
    expect(out.text, '1. a\n');
    expect(out.selection.baseOffset, 5);
  });

  test('plain text and pastes are left alone', () {
    expect(f.formatEditUpdate(_v('hello'), _v('hello\n')).text, 'hello\n');
    expect(f.formatEditUpdate(_v('1. a'), _v('1. a\nb\nc')).text, '1. a\nb\nc');
  });

  test('number marker pattern', () {
    expect(kNumberMarkerLine.hasMatch('1. '), isTrue);
    expect(kNumberMarkerLine.hasMatch('12) '), isTrue);
    expect(kNumberMarkerLine.hasMatch('1.5 '), isFalse);
    expect(kNumberMarkerLine.hasMatch('a1. '), isFalse);
  });
}
