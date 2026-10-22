import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zuraffa_minio/src/minio_parallel.dart';

/// A fetcher that serves a fixed byte array, recording the ranges it was
/// asked for and how many of them were in flight at the same time.
class _FakeServer {
  _FakeServer(this.data);

  final Uint8List data;
  final List<List<int>> requested = <List<int>>[];
  int inFlight = 0;
  int maxInFlight = 0;

  Future<Uint8List> fetch(int offset, int length) async {
    requested.add(<int>[offset, length]);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    // Give the other requests a chance to start, so the concurrency is
    // observable.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    inFlight--;
    final end = (offset + length) > data.length ? data.length : offset + length;
    return Uint8List.sublistView(data, offset, end);
  }
}

void main() {
  group('planRanges', () {
    test('cuts the object into chunks of at most chunkSize', () {
      final ranges = planRanges(10, 4);
      expect(ranges, <List<int>>[
        <int>[0, 4],
        <int>[4, 4],
        <int>[8, 2],
      ]);
    });

    test('an empty object has no range', () {
      expect(planRanges(0, 4), isEmpty);
    });
  });

  group('CountingSemaphore', () {
    test('never lets more callers hold a slot than its limit', () async {
      final semaphore = CountingSemaphore(1);
      await semaphore.acquire();
      expect(semaphore.inFlight, 1);

      // A second caller queues up behind the first one.
      final waiter = semaphore.acquire();
      await Future<void>.delayed(Duration.zero);
      expect(semaphore.inFlight, 1);

      // The slot is handed over, and a newcomer arrives in the middle of the
      // handover — the moment where a semaphore that gives the slot back
      // before it hands it over lets one caller too many through.
      semaphore.release();
      final newcomer = semaphore.acquire();

      await waiter;
      expect(semaphore.inFlight, 1);

      // The waiter hands the slot on to the newcomer.
      semaphore.release();
      await newcomer;
      expect(semaphore.inFlight, lessThanOrEqualTo(1));
    });

    test('a slot is handed over to a waiter', () async {
      final semaphore = CountingSemaphore(1);
      await semaphore.acquire();

      var second = false;
      final waiting = semaphore.acquire().then((_) => second = true);
      await Future<void>.delayed(Duration.zero);
      expect(second, isFalse);

      semaphore.release();
      await waiting;
      expect(second, isTrue);
    });
  });

  group('fetchInParallel', () {
    test('reassembles the bytes in the original order', () async {
      final data = Uint8List.fromList(List<int>.generate(1000, (i) => i % 256));
      final server = _FakeServer(data);

      final stream = await fetchInParallel(
        fetch: server.fetch,
        totalBytes: data.length,
        chunkSize: 100,
        parallelism: 4,
      );

      final out = <int>[];
      await for (final chunk in stream) {
        out.addAll(chunk);
      }

      expect(out, equals(data.toList()));
    });

    test('runs several requests at the same time', () async {
      final data = Uint8List.fromList(List<int>.filled(1000, 7));
      final server = _FakeServer(data);

      final stream = await fetchInParallel(
        fetch: server.fetch,
        totalBytes: data.length,
        chunkSize: 100,
        parallelism: 4,
      );
      await stream.drain<void>();

      expect(server.requested.length, 10);
      expect(server.maxInFlight, greaterThan(1));
      expect(server.maxInFlight, lessThanOrEqualTo(4));
    });

    test('a parallelism of one keeps the requests sequential', () async {
      final data = Uint8List.fromList(List<int>.filled(300, 3));
      final server = _FakeServer(data);

      final stream = await fetchInParallel(
        fetch: server.fetch,
        totalBytes: data.length,
        chunkSize: 100,
        parallelism: 1,
      );
      await stream.drain<void>();

      expect(server.maxInFlight, 1);
    });

    test('reports the progress up to the total size', () async {
      final data = Uint8List.fromList(List<int>.filled(500, 1));
      final server = _FakeServer(data);
      final progress = <int>[];

      final stream = await fetchInParallel(
        fetch: server.fetch,
        totalBytes: data.length,
        chunkSize: 100,
        parallelism: 3,
        onProgress: (bytesRead, totalBytes) {
          expect(totalBytes, equals(data.length));
          progress.add(bytesRead);
        },
      );
      await stream.drain<void>();

      expect(progress, isNotEmpty);
      expect(progress.last, equals(data.length));
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
    });

    test('never runs more requests than the limit under contention', () async {
      final data = Uint8List.fromList(List<int>.filled(500, 9));
      final server = _FakeServer(data);

      final stream = await fetchInParallel(
        fetch: server.fetch,
        totalBytes: data.length,
        chunkSize: 10,
        parallelism: 3,
      );
      await stream.drain<void>();

      // The semaphore hands the slot over to a waiter instead of giving it
      // back first, so the number of requests in flight never grows past the
      // limit — not even when the requests finish at the same time.
      expect(server.requested.length, 50);
      expect(server.maxInFlight, lessThanOrEqualTo(3));
    });

    test('an empty object yields an empty stream', () async {
      final server = _FakeServer(Uint8List(0));
      final stream = await fetchInParallel(
        fetch: server.fetch,
        totalBytes: 0,
        chunkSize: 100,
      );
      expect(await stream.toList(), isEmpty);
    });
  });
}
