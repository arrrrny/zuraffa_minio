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
///
/// The slot is handed over to the next waiter by [release], so the number of
/// holders never grows past [max] — not even when a new caller arrives in
/// the middle of the handover.
class CountingSemaphore {
  CountingSemaphore(this.max);

  final int max;
  int _inFlight = 0;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  /// How many callers hold a slot right now.
  ///
  /// It never grows past [max]. It is read by the tests that guard the
  /// handover of a slot.
  int get inFlight => _inFlight;

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
///
/// [chunkSize] must be positive. A chunk size of zero would never advance the
/// offset, so the planner would run forever.
List<List<int>> planRanges(int totalBytes, int chunkSize) {
  if (chunkSize <= 0) {
    throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
  }
  final ranges = <List<int>>[];
  for (var offset = 0; offset < totalBytes; offset += chunkSize) {
    final end = (offset + chunkSize) < totalBytes
        ? (offset + chunkSize)
        : totalBytes;
    ranges.add(<int>[offset, end - offset]);
  }
  return ranges;
}

/// A condition variable for the ranges of a parallel download.
///
/// The callers wait until their condition holds. A signal wakes every waiter
/// up; the ones whose condition still does not hold go back to waiting.
class _Window {
  _Window(this.limit);

  /// How many ranges may run ahead of the head of the object.
  final int limit;

  final List<Completer<void>> _waiters = <Completer<void>>[];

  /// Wakes every waiter up.
  void signal() {
    if (_waiters.isEmpty) return;
    final waiters = List<Completer<void>>.of(_waiters);
    _waiters.clear();
    for (final waiter in waiters) {
      waiter.complete();
    }
  }

  /// Waits until [isTrue] holds.
  Future<void> wait(bool Function() isTrue) async {
    while (!isTrue()) {
      final completer = Completer<void>();
      _waiters.add(completer);
      await completer.future;
    }
  }
}

/// Downloads an object as concurrent byte ranges and streams the bytes back
/// in the original order.
///
/// The ranges are fetched with at most [parallelism] requests in flight, but
/// the bytes are emitted in order, so the result is identical to a sequential
/// download. [onProgress] is called with the number of bytes received so far.
///
/// A range may not run further ahead of the head of the object than the
/// number of parallel requests. The bytes of a range that waits for its turn
/// are held in memory, so a slow range at the head must not make the
/// download hold the whole object.
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

  final limit = parallelism < 1 ? 1 : parallelism;
  final semaphore = CountingSemaphore(limit);
  final window = _Window(limit);
  final received = <int, Uint8List>{};
  var nextIndex = 0;
  var bytesRead = 0;
  var failed = false;
  Object? failure;

  void emitReady() {
    while (!failed && received.containsKey(nextIndex)) {
      final chunk = received.remove(nextIndex)!;
      nextIndex++;
      bytesRead += chunk.length;
      controller.add(chunk);
      onProgress?.call(bytesRead, totalBytes);
    }
    // The head of the object moved, so the ranges that were waiting for
    // their turn may run now.
    window.signal();
  }

  Future<void> run() async {
    final futures = <Future<void>>[];
    for (var index = 0; index < ranges.length; index++) {
      final range = ranges[index];
      final future = () async {
        // The range waits until it is close enough to the head of the
        // object: the bytes of the ranges ahead of it are held in memory.
        await window.wait(() => failed || index - nextIndex < limit);
        if (failed) throw failure!;
        await semaphore.acquire();
        try {
          final bytes = await fetch(range[0], range[1]);
          received[index] = bytes;
          emitReady();
        } finally {
          semaphore.release();
        }
      }();
      futures.add(future);
    }

    try {
      await Future.wait(futures);
    } catch (error, stack) {
      failed = true;
      failure = error;
      // The error goes to the consumer. A download that lost a range must not
      // look like a complete one: the stream would end normally and the
      // caller would have no way of telling the difference.
      controller.addError(error, stack);
      // The ranges that are still waiting for their turn will never run.
      window.signal();
    }

    if (failed) {
      await controller.close();
    } else {
      emitReady();
      await controller.close();
    }
  }

  unawaited(run());

  return MinioByteStream.fromStream(
    stream: controller.stream,
    contentLength: totalBytes,
  );
}
