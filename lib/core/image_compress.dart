import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// How much photos are shrunk when attached. Smaller files mean faster sync
/// and a sync repository that stays small.
enum ImageCompression {
  /// Keep the file exactly as picked.
  original,

  /// Longest side 2048 px, JPEG quality 82. Looks identical on screen; roughly
  /// 5-10x smaller than a phone photo.
  balanced,

  /// Longest side 1280 px, JPEG quality 70. For receipts, whiteboards, notes.
  small,
}

extension ImageCompressionInfo on ImageCompression {
  /// 0 means "do not resize".
  int get maxEdge => switch (this) {
        ImageCompression.original => 0,
        ImageCompression.balanced => 2048,
        ImageCompression.small => 1280,
      };

  int get quality => switch (this) {
        ImageCompression.original => 100,
        ImageCompression.balanced => 82,
        ImageCompression.small => 70,
      };

  String get label => switch (this) {
        ImageCompression.original => 'Original',
        ImageCompression.balanced => 'Balanced',
        ImageCompression.small => 'Small',
      };

  String get description => switch (this) {
        ImageCompression.original => 'Keep photos exactly as picked.',
        ImageCompression.balanced => 'Up to 2048 px, high quality. Recommended.',
        ImageCompression.small => 'Up to 1280 px. Smallest files.',
      };
}

const Set<String> kCompressibleMimes = {
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/bmp',
  'image/tiff',
};

class CompressedImage {
  const CompressedImage({
    required this.bytes,
    required this.mime,
    required this.extension,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final String mime;

  /// Without the dot: "jpg" or "png".
  final String extension;
  final int width;
  final int height;
}

/// True when any pixel is actually see-through. Many PNGs carry an unused
/// alpha channel (screenshots), and those should still become JPEG.
bool _usesTransparency(img.Image image) {
  if (!image.hasAlpha) return false;
  for (final p in image) {
    if (p.a < p.maxChannelValue) return true;
  }
  return false;
}

/// Decodes, applies the EXIF rotation, downsizes and re-encodes. Returns null
/// if the bytes cannot be decoded as an image.
///
/// Re-encoding also drops EXIF metadata, including GPS location.
/// Runs synchronously; call [compressImage] to keep it off the UI isolate.
CompressedImage? compressImageSync(
  Uint8List input, {
  required int maxEdge,
  required int quality,
}) {
  final decoded = img.decodeImage(input);
  if (decoded == null) return null;

  var image = img.bakeOrientation(decoded);
  if (maxEdge > 0 && max(image.width, image.height) > maxEdge) {
    image = image.width >= image.height
        ? img.copyResize(image,
            width: maxEdge, interpolation: img.Interpolation.average)
        : img.copyResize(image,
            height: maxEdge, interpolation: img.Interpolation.average);
  }

  if (_usesTransparency(image)) {
    return CompressedImage(
      bytes: img.encodePng(image, level: 6),
      mime: 'image/png',
      extension: 'png',
      width: image.width,
      height: image.height,
    );
  }
  return CompressedImage(
    bytes: img.encodeJpg(image, quality: quality),
    mime: 'image/jpeg',
    extension: 'jpg',
    width: image.width,
    height: image.height,
  );
}

/// Compresses in a background isolate. Returns null when compression is off,
/// or the image cannot be decoded (the caller then keeps the original).
Future<CompressedImage?> compressImage(
  Uint8List bytes, {
  required ImageCompression level,
}) async {
  if (level == ImageCompression.original) return null;
  final edge = level.maxEdge;
  final q = level.quality;
  try {
    return await Isolate.run(
      () => compressImageSync(bytes, maxEdge: edge, quality: q),
    );
  } catch (_) {
    return null;
  }
}
