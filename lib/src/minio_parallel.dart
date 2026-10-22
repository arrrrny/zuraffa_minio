import 'dart:async';
import 'dart:typed_data';

import 'package:zuraffa_minio/src/minio_stream.dart';

/// Fetches a byte range of an object.
///
/// [offset] is the first byte, [length] is the number of bytes. The
/// implementation must return exactly [length] bytes unless the object ends
/// earlier.
typedef RangedFetcher = Future<Uint8List> Function(int offset, int length);

/// Called as bytes arrive. [totalBytes] is the size of the whole object, and
/// is null when the size is not known in advance.
typedef ProgressCallback = void Function(int bytesRead, int? totalBytes);

/// A counting semaphore, used to keep at most [max] requests in flight.
class _Semaphore {
  _Semaphore(this.max);

  final int max;
  int _inFlight = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  Future<void> acquire() async {
    if (_inFlight < max) {
      _inFlight++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    // The slot is handed over by [release], so the count is already right
    // when this returns.
    await completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      // Hand the slot straight over to the next waiter.
      _waiters.removeAt(0).complete();
      return;
    }
    _inFlight--;
  }
}

/// The byte ranges of an object of [totalBytes] bytes, cut into chunks of at
/// most [chunkSize].
List<List<int>> planRanges(int totalBytes, int chunkSize) {
  final ranges = <List<int>>[];
  for (var offset = 0; offset < totalBytes; offset += chunkSize) {
    final end = (offset + chunkSize) < totalBytes
        ? (offset + chunkSize)
        : totalBytes;
    ranges.add(<int>[offset, end - offset]);
  }
  return ranges;
}

/// Downloads an object as concurrent byte ranges and streams the bytes back
/// in the original order.
///
/// The ranges are fetched with at most [parallelism] requests in flight, but
/// the bytes are emitted in order, so the result is identical to a sequential
/// download. [onProgress] is called with the number of bytes received so far.
Future<MinioByteStream> fetchInParallel({
  required RangedFetcher fetch,
  required int totalBytes,
  required int chunkSize,
  int parallelism = 4,
  ProgressCallback? onProgress,
}) async {
  final ranges = planRanges(totalBytes, chunkSize);

  if (ranges.isEmpty) {
    // The controller is closed before anyone listens to it, and the `close()`
    // of a single subscription controller only completes once the stream has
    // been listened to. An empty stream avoids the deadlock.
    // See https://github.com/arrrrny/zuraffa_minio/issues/2
    return MinioByteStream.fromStream(
      stream: const Stream<List<int>>.empty(),
      contentLength: 0,
    );
  }

  final controller = StreamController<Uint8List>();

  final semaphore = _Semaphore(parallelism < 1 ? 1 : parallelism);
  final received = <int, Uint8List>{};
  var nextIndex = 0;
  var bytesRead = 0;
  var failed = false;

  Future<void> emitReady() async {
    while (!failed && received.containsKey(nextIndex)) {
      final chunk = received.remove(nextIndex)!;
      nextIndex++;
      bytesRead += chunk.length;
      controller.add(chunk);
      onProgress?.call(bytesRead, totalBytes);
    }
  }

  Future<void> run() async {
    final futures = <Future<void>>[];
    for (var index = 0; index < ranges.length; index++) {
      final range = ranges[index];
      final future = () async {
        await semaphore.acquire();
        try {
          final bytes = await fetch(range[0], range[1]);
          received[index] = bytes;
          await emitReady();
        } finally {
          semaphore.release();
        }
      }();
      futures.add(future);
    }

    try {
      await Future.wait(futures);
    } catch (_) {
      failed = true;
    }

    if (failed) {
      await controller.close();
    } else {
      await emitReady();
      await controller.close();
    }
  }

  unawaited(run());

  return MinioByteStream.fromStream(
    stream: controller.stream,
    contentLength: totalBytes,
  );
}
