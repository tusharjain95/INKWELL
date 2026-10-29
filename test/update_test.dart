import 'package:flutter_test/flutter_test.dart';
import 'package:inkwell/sync/update_service.dart';

void main() {
  test('newer versions are detected', () {
    expect(isNewerVersion('v1.2.0', '1.1.9'), isTrue);
    expect(isNewerVersion('2.0.0', '1.99.99'), isTrue);
    expect(isNewerVersion('1.0.1', '1.0.0'), isTrue);
  });

  test('same or older versions are not updates', () {
    expect(isNewerVersion('v1.0.0', '1.0.0'), isFalse);
    expect(isNewerVersion('1.0.0', '1.0.1'), isFalse);
    expect(isNewerVersion('0.9.0', '1.0.0'), isFalse);
  });

  test('pre-release and build suffixes are ignored', () {
    expect(isNewerVersion('v1.1.0-beta.1', '1.0.0'), isTrue);
    expect(isNewerVersion('1.0.0+5', '1.0.0'), isFalse);
  });
}
