import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/services/resumable_transfer.dart';

/// In-memory ordered link; [corrupt] may damage a piece once in flight.
class Pipe implements TransferLink {
  Pipe(this.deliver);
  final Future<void> Function(Object) deliver;
  bool Function(Uint8List)? corrupt;
  Future<void> _tail = Future.value();
  int sentBytes = 0;
  bool open = true;
  @override
  Future<int> buffered() async => 0;
  @override
  Future<void> sendText(Map<String, dynamic> value) async {
    if (!open) return;
    final copy = Map<String, dynamic>.from(value);
    _tail = _tail.then((_) => deliver(copy));
  }

  @override
  Future<void> sendBytes(Uint8List data) async {
    if (!open) return;
    var copy = Uint8List.fromList(data);
    sentBytes += copy.length;
    if (corrupt?.call(copy) == true) {
      copy[0] ^= 0xff;
      corrupt = null;
    }
    _tail = _tail.then((_) => deliver(copy));
  }

  Future<void> drain() => _tail;
}

class CountingSource extends FileLargeSource {
  CountingSource(super.reference);
  int readBytes = 0;
  @override
  Future<Uint8List> read(int offset, int length) async {
    readBytes += length;
    return super.read(offset, length);
  }
}

void main() {
  late Directory dir;
  late File source;
  const block = 64 * 1024, piece = 16 * 1024;
  const size = 20 * block + 777; // uneven tail block

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('assistant_transfer_');
    source = File('${dir.path}/source.bin');
    final r = Random(7);
    await source.writeAsBytes(List<int>.generate(size, (_) => r.nextInt(256)));
  });
  tearDown(() async {
    if (dir.path.contains('assistant_transfer_')) await dir.delete(recursive: true);
  });

  /// Wires sender and receiver; returns when done or when [stopAfterBlocks]
  /// verified blocks were reached (simulated network loss).
  Future<({BlockSender sender, BlockReceiver receiver, String? saved})> run({
    required BlockSender sender,
    required BlockReceiver receiver,
    int? stopAfterBlocks,
    bool Function(Uint8List)? corrupt,
  }) async {
    var alive = true;
    late Pipe toReceiver, toSender;
    late ReceiverProtocol protocol;
    toSender = Pipe((m) async => sender.onMessage(m as Map<String, dynamic>));
    toReceiver = Pipe((m) async {
      if (!alive) return;
      await protocol.handle(m);
      if (stopAfterBlocks != null && receiver.verified >= stopAfterBlocks) {
        alive = false;
        toReceiver.open = false;
        toSender.open = false;
      }
    })..corrupt = corrupt;
    protocol = ReceiverProtocol(
      receiver,
      toSender,
      onVerifying: () {},
      onComplete: () => receiver.finish('${dir.path}/received.bin'),
    );
    await receiver.open();
    sender.resumeAt(receiver.verified); // the 'resume' handshake
    await sender.run(toReceiver, () => alive).timeout(const Duration(seconds: 30));
    await toReceiver.drain();
    await toSender.drain();
    // Release handles (Windows cannot rename/delete open files).
    await sender.source.close();
    if (protocol.savedPath == null) await receiver.close();
    return (sender: sender, receiver: receiver, saved: protocol.savedPath);
  }

  test('64-bit sizes: 5 GB is not capped and block math stays exact', () {
    const five = 5 * 1024 * 1024 * 1024 + 1;
    expect(five, greaterThan(0x7fffffff));
    expect(assistantMaxFileBytes, greaterThanOrEqualTo(five));
    expect(blockCount(five, assistantBlockBytes), 1281);
    expect(1280 * assistantBlockBytes, lessThan(five));
    expect(assistantPieceBytes * assistantWindowBlocks, lessThan(assistantBlockBytes * 2));
  });

  test('transfers in verified blocks and the result is byte-identical', () async {
    final result = await run(
      sender: BlockSender(source: FileLargeSource(source.path), size: size, block: block, piece: piece),
      receiver: BlockReceiver(partPath: '${dir.path}/in.part', size: size, block: block),
    );
    expect(result.sender.finished, isTrue);
    expect(await File(result.saved!).readAsBytes(), await source.readAsBytes());
    expect(await File('${dir.path}/in.part.state.json').exists(), isFalse);
  });

  test('a corrupted block is detected and only that block is resent', () async {
    final pipe = CountingSource(source.path);
    var seen = 0;
    final result = await run(
      sender: BlockSender(source: pipe, size: size, block: block, piece: piece),
      receiver: BlockReceiver(partPath: '${dir.path}/in.part', size: size, block: block),
      corrupt: (_) => ++seen == 9, // one piece inside block 2
    );
    expect(await File(result.saved!).readAsBytes(), await source.readAsBytes());
    expect(pipe.readBytes, size + block); // exactly one extra block
  });

  test('resume after interruption continues from the verified position', () async {
    final part = '${dir.path}/in.part';
    await run(
      sender: BlockSender(source: FileLargeSource(source.path), size: size, block: block, piece: piece),
      receiver: BlockReceiver(partPath: part, size: size, block: block),
      stopAfterBlocks: 12,
    );
    // Network lost: new objects, as after reconnecting or restarting the app.
    final again = CountingSource(source.path);
    final receiver = BlockReceiver(partPath: part, size: size, block: block);
    final result = await run(
      sender: BlockSender(source: again, size: size, block: block, piece: piece),
      receiver: receiver,
    );
    expect(await File(result.saved!).readAsBytes(), await source.readAsBytes());
    // Not restarted from 0 %: at least the 12 verified blocks were skipped.
    expect(again.readBytes, lessThanOrEqualTo(size - 12 * block));
  });

  test('final check re-reads the file and repairs only damaged blocks', () async {
    final part = '${dir.path}/in.part';
    final receiver = BlockReceiver(partPath: part, size: size, block: block);
    await receiver.open();
    final input = FileLargeSource(source.path);
    final sender = BlockSender(source: input, size: size, block: block, piece: piece);
    // Deliver every block normally.
    for (var i = 0; i < receiver.blocks; i++) {
      final data = await input.read(i * block, min(block, size - i * block));
      await receiver.onHeader({
        'index': i,
        'offset': i * block,
        'length': data.length,
        'sha256': _sha(data),
      });
      await receiver.onBytes(data);
    }
    // Simulate on-disk damage after verification.
    final raf = await File(part).open(mode: FileMode.append);
    await raf.setPosition(5 * block + 10);
    await raf.writeFrom([1, 2, 3]);
    await raf.close();
    expect(await receiver.verifyFile(), [5]);
    receiver.requestRedo([5]);
    expect(receiver.redoPending, isTrue);
    final data = await input.read(5 * block, block);
    await receiver.onHeader({'index': 5, 'offset': 5 * block, 'length': block, 'sha256': _sha(data)});
    expect((await receiver.onBytes(data))!['ok'], isTrue);
    expect(receiver.redoPending, isFalse);
    expect(await receiver.verifyFile(), isEmpty);
    expect(sender.blocks, receiver.blocks);
    await receiver.close();
    await input.close();
  });
}

String _sha(List<int> data) => sha256.convert(data).toString();
