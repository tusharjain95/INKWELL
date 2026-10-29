import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:inkwell/core/image_compress.dart';

Uint8List _noisyJpeg(int w, int h) {
  final im = img.Image(width: w, height: h);
  var seed = 7;
  for (final p in im) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    p
      ..r = seed & 255
      ..g = (seed >> 8) & 255
      ..b = (seed >> 16) & 255;
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: 98));
}

void main() {
  test('large photos are resized to the cap and get smaller', () {
    final src = _noisyJpeg(3000, 2000);
    final out = compressImageSync(src, maxEdge: 1280, quality: 70);
    expect(out, isNotNull);
    expect(out!.bytes.length, lessThan(src.length));
    final dec = img.decodeImage(out.bytes)!;
    expect(dec.width, 1280);
    expect(dec.height, closeTo(853, 1));
  });

  test('portrait photos are capped on the long edge', () {
    final out = compressImageSync(_noisyJpeg(1500, 3000), maxEdge: 1000, quality: 80)!;
    final dec = img.decodeImage(out.bytes)!;
    expect(dec.height, 1000);
    expect(dec.width, 500);
  });

  test('PNG with real transparency stays PNG', () {
    final im = img.Image(width: 2400, height: 2400, numChannels: 4);
    img.fill(im, color: img.ColorRgba8(10, 200, 30, 0));
    final src = Uint8List.fromList(img.encodePng(im));
    final out = compressImageSync(src, maxEdge: 1024, quality: 80);
    if (out != null) expect(out.mime, 'image/png');
  });

  test('opaque RGBA PNG becomes JPEG', () {
    final im = img.Image(width: 1800, height: 1800, numChannels: 4);
    var s = 3;
    for (final p in im) {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      p
        ..r = s & 255
        ..g = (s >> 8) & 255
        ..b = (s >> 16) & 255
        ..a = 255;
    }
    final src = Uint8List.fromList(img.encodePng(im));
    final out = compressImageSync(src, maxEdge: 1024, quality: 80);
    expect(out, isNotNull);
    expect(out!.mime, 'image/jpeg');
  });

  test('garbage and unsupported data return null', () {
    expect(compressImageSync(Uint8List.fromList([1, 2, 3, 4]), maxEdge: 1024, quality: 80), isNull);
  });

  test('levels expose sensible limits', () {
    expect(ImageCompression.balanced.maxEdge, 2048);
    expect(ImageCompression.small.maxEdge, 1280);
  });
}
