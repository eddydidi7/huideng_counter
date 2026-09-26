import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Runs in a worker isolate. Reject huge decoded dimensions before allocating
/// pixels; phone/desktop UI remains responsive while encoding a JPEG.
Uint8List compressChatImage(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width * info.height > 40000000) {
    throw StateError('IMAGE_UNSUPPORTED_OR_TOO_LARGE');
  }
  final decoded = decoder!.decodeFrame(0);
  if (decoded == null) throw StateError('IMAGE_UNSUPPORTED');
  final oriented = img.bakeOrientation(decoded);
  final scaled = oriented.width > 1600 || oriented.height > 1600
      ? img.copyResize(
          oriented,
          width: oriented.width >= oriented.height ? 1600 : null,
          height: oriented.height > oriented.width ? 1600 : null,
        )
      : oriented;
  return img.encodeJpg(scaled, quality: 82);
}

/// Shared profile image, encoded once at upload; card views reuse the same file.
Uint8List compressChatAvatar(Uint8List bytes) {
  final optimized = compressChatImage(bytes);
  final source = img.decodeImage(optimized)!;
  final scaled = source.width > 256 || source.height > 256
      ? img.copyResize(
          source,
          width: source.width >= source.height ? 256 : null,
          height: source.height > source.width ? 256 : null,
        )
      : source;
  return img.encodeJpg(scaled, quality: 85);
}
