import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// 文件传输助手 transfer core, independent of WebRTC so it can be tested.
///
/// * Sizes are Dart `int` (64-bit on Android/Windows); nothing is capped
///   below 5 GB. The only ceiling is [assistantMaxFileBytes] (1 TiB).
/// * Files are never loaded whole: the sender reads one 4 MiB block at a
///   time and sends it as 64 KiB messages; at most [assistantWindowBlocks]
///   blocks are unacknowledged.
/// * Every block carries its SHA-256; the receiver verifies and persists the
///   contiguous verified prefix, so a reconnect resumes there, not at 0 %.
/// * At the end the receiver re-reads the file, checks every block and asks
///   only for the blocks that fail.
const assistantMaxFileBytes = 1099511627776; // 1 TiB
const assistantBlockBytes = 4 * 1024 * 1024;
const assistantPieceBytes = 64 * 1024;
const assistantWindowBlocks = 4;

String _hex(List<int> bytes) => sha256.convert(bytes).toString();
String transferRoot(List<String> hashes) => _hex(utf8.encode(hashes.join()));
int blockCount(int size, int block) => (size + block - 1) ~/ block;

/// An ordered, reliable message link (a WebRTC data channel in the app).
abstract class TransferLink {
  Future<void> sendText(Map<String, dynamic> value);
  Future<void> sendBytes(Uint8List data);

  /// Bytes queued but not yet on the wire (back-pressure).
  Future<int> buffered();
}

// ---------------------------------------------------------------- sources
abstract class LargeSource {
  String get reference;
  Future<int> length();
  Future<Uint8List> read(int offset, int length);
  Future<void> close();

  static LargeSource fromReference(String reference) =>
      reference.startsWith('content://')
      ? AndroidDocumentSource(reference)
      : FileLargeSource(reference);
}

class FileLargeSource implements LargeSource {
  FileLargeSource(this.reference);
  @override
  final String reference;
  RandomAccessFile? _file;
  @override
  Future<int> length() => File(reference).length();
  @override
  Future<Uint8List> read(int offset, int length) async {
    final file = _file ??= await File(reference).open();
    await file.setPosition(offset);
    return file.read(length);
  }

  @override
  Future<void> close() async {
    await _file?.close();
    _file = null;
  }
}

/// Android documents read in place (see LargeFileBridge.kt): no cache copy.
class AndroidDocumentSource implements LargeSource {
  AndroidDocumentSource(this.reference);
  static const channel = MethodChannel('org.huideng.counter/large_files');
  @override
  final String reference;
  @override
  Future<int> length() async =>
      (await channel.invokeMethod<num>('size', {'uri': reference}))?.toInt() ?? -1;
  @override
  Future<Uint8List> read(int offset, int length) async =>
      (await channel.invokeMethod<Uint8List>('read', {
        'uri': reference,
        'offset': offset,
        'length': length,
      }))!;
  @override
  Future<void> close() => channel.invokeMethod('close', {'uri': reference});

  /// ({reference, name, size}) or null when cancelled.
  static Future<Map<String, dynamic>?> pick() async {
    final value = await channel.invokeMapMethod<String, dynamic>('pick');
    if (value == null) return null;
    return {
      'reference': value['uri'],
      'name': value['name'],
      'size': (value['size'] as num).toInt(),
    };
  }
}

// ---------------------------------------------------------------- sender
class BlockSender {
  BlockSender({
    required this.source,
    required this.size,
    this.block = assistantBlockBytes,
    this.piece = assistantPieceBytes,
    this.window = assistantWindowBlocks,
  });
  final LargeSource source;
  final int size, block, piece, window;
  int get blocks => blockCount(size, block);

  /// Contiguous blocks the receiver has verified.
  int acked = 0;
  int _cursor = 0;
  final _inflight = <int>{};
  final _done = <int>{};
  final _redo = Queue<int>();
  final _hashes = <int, String>{};
  bool paused = false, finished = false, _ending = false;
  Completer<void>? _wake;

  int get ackedBytes => math.min(acked * block, size);

  void _notify() {
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _wait() async {
    final w = _wake ??= Completer<void>();
    await w.future.timeout(const Duration(milliseconds: 250), onTimeout: () {});
  }

  /// A (re)connection: the receiver reports how far it has verified.
  void resumeAt(int verified) {
    acked = verified.clamp(0, blocks);
    _cursor = acked;
    _inflight.clear();
    _redo.clear();
    _done
      ..clear()
      ..addAll(List.generate(acked, (i) => i));
    _ending = false;
    _notify();
  }

  void pause(bool value) {
    paused = value;
    _notify();
  }

  /// Handles control messages; returns true when the transfer is complete.
  bool onMessage(Map<String, dynamic> m) {
    switch (m['type']) {
      case 'ack':
        final i = (m['index'] as num).toInt();
        _inflight.remove(i);
        if (m['ok'] == true) {
          _done.add(i);
          while (_done.contains(acked)) {
            acked++;
          }
        } else {
          _redo.add(i);
        }
      case 'redo':
        for (final i in (m['blocks'] as List).map((e) => (e as num).toInt())) {
          _done.remove(i);
          _redo.add(i);
        }
        acked = 0;
        while (_done.contains(acked)) {
          acked++;
        }
        _ending = false;
      case 'done':
        finished = true;
    }
    _notify();
    return finished;
  }

  /// Sends until everything is acknowledged or [alive] turns false.
  Future<void> run(TransferLink link, bool Function() alive) async {
    while (alive() && !finished) {
      if (paused) {
        await _wait();
        continue;
      }
      if (_redo.isEmpty && _cursor >= blocks) {
        if (_inflight.isEmpty && acked >= blocks && !_ending) {
          _ending = true;
          final complete = _hashes.length == blocks;
          await link.sendText({
            'type': 'end',
            'blocks': blocks,
            if (complete)
              'root': transferRoot([for (var i = 0; i < blocks; i++) _hashes[i]!]),
          });
        }
        await _wait();
        continue;
      }
      if (_inflight.length >= window || await link.buffered() > window * block) {
        await _wait();
        continue;
      }
      final index = _redo.isNotEmpty ? _redo.removeFirst() : _cursor++;
      _inflight.add(index);
      await _sendBlock(link, index, alive);
    }
  }

  Future<void> _sendBlock(TransferLink link, int index, bool Function() alive) async {
    final offset = index * block;
    final length = math.min(block, size - offset);
    final data = await source.read(offset, length);
    if (data.length != length) throw StateError('SOURCE_CHANGED');
    final hash = _hex(data);
    _hashes[index] = hash;
    await link.sendText({
      'type': 'block',
      'index': index,
      'offset': offset,
      'length': length,
      'sha256': hash,
    });
    for (var p = 0; p < length && alive(); p += piece) {
      while (alive() && await link.buffered() > window * block) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await link.sendBytes(Uint8List.sublistView(data, p, math.min(p + piece, length)));
    }
  }
}

// ---------------------------------------------------------------- receiver
/// Verified progress, persisted next to the partial file after each block.
class ReceiveState {
  ReceiveState(this.size, this.block, this.hashes);
  final int size, block;
  final List<String> hashes; // declared hash of each verified block, in order
  int get verified => hashes.length;

  Map<String, dynamic> toJson() => {'v': 2, 'size': size, 'block': block, 'hashes': hashes};
}

class BlockReceiver {
  BlockReceiver({
    required this.partPath,
    required this.size,
    this.block = assistantBlockBytes,
  });
  final String partPath;
  final int size, block;
  int get blocks => blockCount(size, block);
  String get statePath => '$partPath.state.json';

  late List<String> hashes;
  RandomAccessFile? _out;
  int? _index;
  int _length = 0, _got = 0;
  String? _expect;
  ByteConversionSink? _hash;
  _DigestSink? _digest;
  final _redo = <int>{};

  int get verified => hashes.length;
  int get verifiedBytes => math.max(
    0,
    math.min((verified + _ahead.length) * block, size) - _redo.length * block,
  );

  Future<void> open() async {
    hashes = [];
    final state = File(statePath);
    if (await state.exists() && await File(partPath).exists()) {
      try {
        final j = jsonDecode(await state.readAsString()) as Map;
        if (j['size'] == size && j['block'] == block) {
          hashes = [for (final h in j['hashes'] as List) '$h'];
        }
      } catch (_) {}
    }
    await File(partPath).parent.create(recursive: true);
    // Append mode keeps existing bytes; writes use explicit positions.
    _out = await File(partPath).open(mode: FileMode.append);
    // Drop any unverified tail from an interrupted block.
    await _out!.truncate(math.min(verified * block, size));
  }

  Future<void> _persist() async {
    final tmp = File('$statePath.tmp');
    await tmp.writeAsString(jsonEncode(ReceiveState(size, block, hashes).toJson()), flush: true);
    await tmp.rename(statePath);
  }

  /// Starts a block. Blocks may arrive ahead of a failed one (window of 4).
  Future<void> onHeader(Map<String, dynamic> m) async {
    final i = (m['index'] as num).toInt(), offset = (m['offset'] as num).toInt();
    final length = (m['length'] as num).toInt();
    if (i < 0 || i >= blocks || offset != i * block || length != math.min(block, size - offset) ||
        m['sha256'] is! String) {
      throw StateError('PROTOCOL_BLOCK');
    }
    _index = i;
    _length = length;
    _got = 0;
    _expect = m['sha256'] as String;
    _digest = _DigestSink();
    _hash = sha256.startChunkedConversion(_digest!);
    await _out!.setPosition(offset);
  }

  /// Writes a piece; returns an ack message when the block is complete.
  Future<Map<String, dynamic>?> onBytes(Uint8List data) async {
    final i = _index;
    if (i == null || _got + data.length > _length) throw StateError('PROTOCOL_SIZE');
    await _out!.writeFrom(data);
    _hash!.add(data);
    _got += data.length;
    if (_got < _length) return null;
    _hash!.close();
    _index = null;
    final ok = _digest!.value.toString() == _expect;
    if (ok) {
      final before = verified;
      if (_redo.remove(i)) {
        hashes[i] = _expect!;
      } else if (i == verified) {
        hashes.add(_expect!);
      } else if (i > verified) {
        _ahead[i] = _expect!;
      }
      while (_ahead.containsKey(verified)) {
        hashes.add(_ahead.remove(verified)!);
      }
      // Only the contiguous verified prefix is the resume point.
      if (verified != before || i < before) {
        await _out!.flush();
        await _persist();
      }
    }
    // A failed block is simply overwritten when it is sent again.
    return {'type': 'ack', 'index': i, 'ok': ok};
  }

  final _ahead = <int, String>{};

  /// The sender only knows the root when it hashed every block this session
  /// (not after a resume); block-level checks and [verifyFile] always run.
  bool rootMatches(String? root) =>
      verified == blocks && (root == null || transferRoot(hashes) == root);

  /// Re-reads the whole file in a background isolate; returns bad blocks.
  Future<List<int>> verifyFile() async {
    await _out!.flush();
    final path = partPath, blockSize = block, expected = List<String>.of(hashes);
    return Isolate.run(() => _verifyBlocks(path, blockSize, expected));
  }

  void requestRedo(List<int> bad) => _redo.addAll(bad);
  bool get redoPending => _redo.isNotEmpty;

  /// Moves the verified file to [target] (a unique name) and cleans up.
  Future<String> finish(String target) async {
    await _out!.flush();
    await _out!.close();
    _out = null;
    final path = await uniquePath(target);
    await File(partPath).rename(path);
    final state = File(statePath);
    if (await state.exists()) await state.delete();
    return path;
  }

  Future<void> close({bool discard = false}) async {
    await _out?.close();
    _out = null;
    if (discard) {
      for (final f in [File(partPath), File(statePath)]) {
        if (await f.exists()) await f.delete();
      }
    }
  }
}

/// Receiver-side message handling, shared by the app session and tests.
class ReceiverProtocol {
  ReceiverProtocol(
    this.receiver,
    this.link, {
    required this.onVerifying,
    required this.onComplete,
  });
  final BlockReceiver receiver;
  final TransferLink link;
  final void Function() onVerifying;

  /// Moves the verified file into place and returns its path.
  final Future<String> Function() onComplete;
  String? savedPath;

  Future<void> handle(Object message) async {
    if (message is Uint8List) {
      final ack = await receiver.onBytes(message);
      if (ack != null) await link.sendText(ack);
      return;
    }
    final m = message as Map<String, dynamic>;
    switch (m['type']) {
      case 'block':
        await receiver.onHeader(m);
      case 'end':
        if (receiver.redoPending || !receiver.rootMatches(m['root'] as String?)) {
          throw StateError('CHECKSUM_FAILED');
        }
        onVerifying();
        final bad = await receiver.verifyFile();
        if (bad.isNotEmpty) {
          receiver.requestRedo(bad);
          for (var i = 0; i < bad.length; i += 500) {
            await link.sendText({'type': 'redo', 'blocks': bad.sublist(i, math.min(i + 500, bad.length))});
          }
          return;
        }
        savedPath = await onComplete();
        await link.sendText({'type': 'done'});
    }
  }
}

List<int> _verifyBlocks(String path, int block, List<String> expected) {
  final file = File(path).openSync();
  try {
    final bad = <int>[];
    for (var i = 0; i < expected.length; i++) {
      file.setPositionSync(i * block);
      if (_hex(file.readSync(block)) != expected[i]) bad.add(i);
    }
    return bad;
  } finally {
    file.closeSync();
  }
}

Future<String> uniquePath(String target) async {
  if (!await File(target).exists()) return target;
  final dot = target.lastIndexOf('.');
  final slash = target.lastIndexOf(RegExp(r'[\\/]'));
  final hasExt = dot > slash + 1;
  final base = hasExt ? target.substring(0, dot) : target;
  final ext = hasExt ? target.substring(dot) : '';
  for (var n = 1; ; n++) {
    final candidate = '$base ($n)$ext';
    if (!await File(candidate).exists()) return candidate;
  }
}

String safeFileName(String name) {
  final clean = name
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  return clean.isEmpty ? 'file' : clean;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
