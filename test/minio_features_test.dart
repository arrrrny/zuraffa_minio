import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:test/test.dart' hide setUpAll, tearDownAll, test;
import 'package:zuraffa_minio/io.dart';
import 'package:zuraffa_minio/minio.dart';
import 'package:zuraffa_minio/models.dart';

import 'helpers.dart';

Future<void> main() async {
  await detectMinioServer();
  group(
    'issue #101 — the presigned calls accept a host, a port and a scheme',
    () {
      test('the url carries the override', () async {
        final minio = getMinioClient();

        final url = await minio.presignedGetObject(
          'bucket',
          'object',
          host: 'public.example.com',
          port: 8443,
          useSSL: true,
        );

        expect(
          url,
          startsWith('https://public.example.com:8443/bucket/object'),
        );
        expect(url, contains('X-Amz-Signature='));
      });

      test('without an override the url of the client is used', () async {
        final minio = getMinioClient();

        final url = await minio.presignedGetObject('bucket', 'object');

        expect(
          url,
          startsWith(
            'http://${MinioTestServer.endpoint}:${MinioTestServer.port}',
          ),
        );
      });

      test('the override reaches the signature', () async {
        final minio = getMinioClient();

        final plain = await minio.presignedGetObject('bucket', 'object');
        final overridden = await minio.presignedGetObject(
          'bucket',
          'object',
          host: 'public.example.com',
          port: 8443,
          useSSL: true,
        );

        // The signature covers the host, so it cannot be the same.
        String signatureOf(String url) =>
            url.split('X-Amz-Signature=').last.split('&').first;

        expect(signatureOf(plain), isNot(signatureOf(overridden)));
      });

      test('the post policy uses the override too', () async {
        final minio = getMinioClient();

        final policy = PostPolicy();
        policy.setBucket('bucket');
        policy.setKey('object');
        policy.setExpires(DateTime.now().toUtc().add(const Duration(days: 1)));

        final result = await minio.presignedPostPolicy(
          policy,
          host: 'public.example.com',
          port: 8443,
          useSSL: true,
        );

        expect(result.postURL, startsWith('https://public.example.com:8443/'));
      });
    },
  );

  group('issue #94 — the credentials come from a provider', () {
    test('the provider is consulted and the getters follow', () async {
      var calls = 0;
      final minio = Minio(
        endPoint: MinioTestServer.endpoint,
        port: MinioTestServer.port,
        useSSL: MinioTestServer.useSSL,
        accessKey: 'static',
        secretKey: 'static',
        region: MinioTestServer.region,
        credentialsProvider: () async {
          calls++;
          return MinioCredentials(
            accessKey: 'key$calls',
            secretKey: 'secret$calls',
            sessionToken: 'token$calls',
          );
        },
      );

      expect(minio.accessKey, 'static');

      await minio.refreshCredentials();

      expect(calls, 1);
      expect(minio.accessKey, 'key1');
      expect(minio.secretKey, 'secret1');
      expect(minio.sessionToken, 'token1');
    });

    test('the credentials are cached until they are too old', () async {
      var calls = 0;
      final minio = Minio(
        endPoint: MinioTestServer.endpoint,
        port: MinioTestServer.port,
        useSSL: MinioTestServer.useSSL,
        accessKey: 'static',
        secretKey: 'static',
        region: MinioTestServer.region,
        credentialsTtl: const Duration(hours: 1),
        credentialsProvider: () async {
          calls++;
          return MinioCredentials(accessKey: 'key$calls', secretKey: 'secret');
        },
      );

      await minio.resolveCredentials();
      await minio.resolveCredentials();

      expect(calls, 1);
    });

    test('the requests of a client with a provider are signed', () async {
      var calls = 0;
      final minio = Minio(
        endPoint: MinioTestServer.endpoint,
        port: MinioTestServer.port,
        useSSL: MinioTestServer.useSSL,
        region: MinioTestServer.region,
        credentialsProvider: () async {
          calls++;
          return MinioCredentials(
            accessKey: MinioTestServer.accessKey,
            secretKey: MinioTestServer.secretKey,
          );
        },
      );

      // The server checks the signature, so a request that comes back proves
      // the client signed it with the resolved credentials.
      final buckets = await minio.listBuckets();

      expect(buckets, isNotEmpty);
      expect(calls, greaterThanOrEqualTo(1));
    });
  });

  group('issue #12 — the url of an object', () {
    test('the url points at the object', () async {
      final minio = getMinioClient();

      final url = await minio.objectUrl('bucket', 'some/object.txt');

      expect(
        url,
        'http://${MinioTestServer.endpoint}:${MinioTestServer.port}'
        '/bucket/some/object.txt',
      );
    });
  });

  group('issue #85, #45 and #93 — the requests can be cancelled', () {
    test('a cancelled token stops the requests', () async {
      final token = MinioCancellationToken();
      final minio = Minio(
        endPoint: MinioTestServer.endpoint,
        port: MinioTestServer.port,
        useSSL: MinioTestServer.useSSL,
        accessKey: MinioTestServer.accessKey,
        secretKey: MinioTestServer.secretKey,
        region: MinioTestServer.region,
        cancellationToken: token,
      );

      expect(token.isCancelled, isFalse);

      token.cancel();

      expect(token.isCancelled, isTrue);
      await expectLater(
        minio.listBuckets(),
        throwsA(isA<MinioRequestCancelledError>()),
      );
    });
  });

  group('issue #80 — a client that accepts an invalid certificate', () {
    test('it returns a client', () {
      final client = createTlsHttpClient(allowInvalidCertificates: true);
      expect(client, isA<http.Client>());
      client.close();
    });
  });

  group('the parallel download and the parallel upload', () {
    test('a parallel download returns the same bytes', () async {
      final minio = getMinioClient();
      final bucket = uniqueName();
      final object = uniqueName();
      final data = Uint8List.fromList(
        List<int>.generate(3 * 1024 * 1024, (i) => (i * 7) % 256),
      );

      await minio.makeBucket(bucket);
      await minio.putObject(bucket, object, Stream.value(data));

      final stream = await minio.getObject(
        bucket,
        object,
        parallelism: 4,
        chunkSize: 1024 * 1024,
      );
      final downloaded = <int>[];
      await for (final chunk in stream) {
        downloaded.addAll(chunk);
      }

      expect(downloaded, equals(data.toList()));

      await minio.removeObject(bucket, object);
      await minio.removeBucket(bucket);
    });

    test('a parallel download reports its progress', () async {
      final minio = getMinioClient();
      final bucket = uniqueName();
      final object = uniqueName();
      final data = Uint8List.fromList(List<int>.filled(2 * 1024 * 1024, 3));

      await minio.makeBucket(bucket);
      await minio.putObject(bucket, object, Stream.value(data));

      var last = 0;
      final stream = await minio.getObject(
        bucket,
        object,
        parallelism: 3,
        chunkSize: 512 * 1024,
        onProgress: (bytesRead, totalBytes) {
          expect(totalBytes, equals(data.length));
          expect(bytesRead, greaterThanOrEqualTo(last));
          last = bytesRead;
        },
      );
      await stream.drain<void>();

      expect(last, equals(data.length));

      await minio.removeObject(bucket, object);
      await minio.removeBucket(bucket);
    });

    test('the parts of a parallel upload land in the right order', () async {
      final minio = getMinioClient();
      final bucket = uniqueName();
      final object = uniqueName();
      final partSize = 5 * 1024 * 1024;
      final data = Uint8List.fromList(
        List<int>.generate(12 * 1024 * 1024, (i) => (i * 13) % 256),
      );

      await minio.makeBucket(bucket);

      await minio.putObject(
        bucket,
        object,
        Stream.value(data),
        chunkSize: partSize,
        maxParallelUploads: 4,
      );

      final stat = await minio.statObject(bucket, object);
      expect(stat.size, equals(data.length));

      final stream = await minio.getObject(bucket, object);
      final downloaded = <int>[];
      await for (final chunk in stream) {
        downloaded.addAll(chunk);
      }
      expect(downloaded, equals(data.toList()));

      await minio.removeObject(bucket, object);
      await minio.removeBucket(bucket);
    });
  });

  group('issue #102 — a multipart upload driven by hand', () {
    test('the parts are uploaded and the object is complete', () async {
      final minio = getMinioClient();
      final bucket = uniqueName();
      final object = uniqueName();
      final partSize = 5 * 1024 * 1024;
      final part1 = Uint8List.fromList(List<int>.filled(partSize, 1));
      final part2 = Uint8List.fromList(List<int>.filled(partSize, 2));

      await minio.makeBucket(bucket);

      final uploadId = await minio.initiateNewMultipartUpload(
        bucket,
        object,
        null,
      );

      final etag1 = await minio.uploadPart(bucket, object, uploadId, 1, part1);
      final etag2 = await minio.uploadPart(bucket, object, uploadId, 2, part2);

      expect(etag1, isNotEmpty);
      expect(etag2, isNotEmpty);

      await minio.completeMultipartUpload(bucket, object, uploadId, [
        CompletedPart(etag1, 1),
        CompletedPart(etag2, 2),
      ]);

      final stat = await minio.statObject(bucket, object);
      expect(stat.size, equals(partSize * 2));

      await minio.removeObject(bucket, object);
      await minio.removeBucket(bucket);
    });
  });

  group('issue #99 — a folder and its data are removed', () {
    test('every object under the prefix is gone', () async {
      final minio = getMinioClient();
      final bucket = uniqueName();
      final prefix = 'folder-${uniqueName()}';

      await minio.makeBucket(bucket);
      await minio.putObject(
        bucket,
        '$prefix/one.txt',
        Stream.value(Uint8List.fromList([1])),
      );
      await minio.putObject(
        bucket,
        '$prefix/nested/two.txt',
        Stream.value(Uint8List.fromList([2])),
      );
      await minio.putObject(
        bucket,
        'keep.txt',
        Stream.value(Uint8List.fromList([3])),
      );

      await minio.removeObjectsByPrefix(bucket, '$prefix/');

      final left = await minio.listAllObjects(bucket);
      expect(
        left.objects.map((o) => o.key),
        isNot(contains('$prefix/one.txt')),
      );
      expect(
        left.objects.map((o) => o.key),
        isNot(contains('$prefix/nested/two.txt')),
      );
      expect(left.objects.map((o) => o.key), contains('keep.txt'));

      await minio.removeObject(bucket, 'keep.txt');
      await minio.removeBucket(bucket);
    });
  });

  group('issue #4 and #20 — the progress of a download', () {
    test('the callback receives the bytes and the total', () async {
      final minio = getMinioClient();
      final bucket = uniqueName();
      final object = uniqueName();
      final data = Uint8List.fromList(List<int>.filled(1024 * 1024, 9));

      await minio.makeBucket(bucket);
      await minio.putObject(bucket, object, Stream.value(data));

      final seen = <int>[];
      final stream = await minio.getObject(
        bucket,
        object,
        onProgress: (bytesRead, totalBytes) {
          expect(totalBytes, equals(data.length));
          seen.add(bytesRead);
        },
      );
      await stream.drain<void>();

      expect(seen, isNotEmpty);
      expect(seen.last, equals(data.length));

      await minio.removeObject(bucket, object);
      await minio.removeBucket(bucket);
    });
  });
}
