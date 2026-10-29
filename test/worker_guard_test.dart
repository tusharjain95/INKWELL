import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkwell/sync/worker_guard.dart';

void main() {
  late Directory dir;
  late WorkerGuard g;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('inkwell_guard_');
    g = WorkerGuard(dir);
  });
  tearDown(() => dir.delete(recursive: true));

  test('only one holder of the lock at a time', () async {
    expect(await g.tryAcquire(), isTrue);
    expect(await WorkerGuard(dir).tryAcquire(), isFalse);
    await g.release();
    expect(await WorkerGuard(dir).tryAcquire(), isTrue);
  });

  test('app heartbeat is seen and can be cleared', () async {
    expect(await g.isAppActive(), isFalse);
    await g.markActive();
    expect(await WorkerGuard(dir).isAppActive(), isTrue);
    await g.markInactive();
    expect(await g.isAppActive(), isFalse);
  });

  test('a stale lock is ignored', () async {
    File('${dir.path}/bg.lock').writeAsStringSync(
        DateTime.now().subtract(const Duration(minutes: 30)).millisecondsSinceEpoch.toString());
    expect(await g.isLocked(), isFalse);
    expect(await g.tryAcquire(), isTrue);
  });
}
