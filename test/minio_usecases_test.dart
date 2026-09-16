import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zuraffa/zuraffa.dart' hide MinioClient;
import 'package:zuraffa_minio/zuraffa_minio.dart';

import 'minio_client_test.dart' show FakeMinioTransport;

MinioResponse ok([Uint8List? body, Map<String, String> headers = const {}]) =>
    MinioResponse(statusCode: 200, headers: headers, body: body);

MinioResponse status(int code) => MinioResponse(statusCode: code);

void main() {
  late FakeMinioTransport transport;
  late MinioClient client;

  MinioClient build([List<MinioResponse>? responses]) {
    transport = FakeMinioTransport(responses);
    return MinioClient(
      endpoint: 'http://localhost:9000',
      accessKey: 'minioadmin',
      secretKey: 'minioadmin',
      transport: transport,
    );
  }

  group('object usecases', () {
    test('UploadObjectUseCase folds success', () async {
      client = build([ok()]);
      final usecase = UploadObjectUseCase(client: client);

      final result = await usecase(UploadObjectParams(
        bucket: 'photos',
        key: 'a.jpg',
        bytes: Uint8List.fromList(utf8.encode('data')),
        contentType: 'image/jpeg',
      ));

      expect(result.isSuccess, isTrue);
    });

    test('Upload failure -> NetworkFailure with typed cause', () async {
      client = build([status(503)]);
      final usecase = UploadObjectUseCase(client: client);

      final result = await usecase(UploadObjectParams(
        bucket: 'photos',
        key: 'a.jpg',
        bytes: Uint8List.fromList([1]),
      ));

      result.fold(
        (_) => fail('expected failure'),
        (failure) {
          expect(failure, isA<NetworkFailure>());
          expect(failure.code, 'minio_put_object_503');
          expect(failure.cause, isA<MinioException>());
        },
      );
    });

    test('DownloadObjectUseCase passes null through for missing objects',
        () async {
      client = build([status(404)]);
      final usecase = DownloadObjectUseCase(client: client);

      final result = await usecase(
          const DownloadObjectParams(bucket: 'photos', key: 'missing.jpg'));

      result.fold(
        (value) => expect(value, isNull),
        (failure) => fail('expected success-with-null'),
      );
    });

    test('DeleteObjectUseCase and EnsureBucketUseCase delegate', () async {
      client = build([status(204), status(404), status(200)]);

      final deleteResult = await DeleteObjectUseCase(client: client)(
          const DeleteObjectParams(bucket: 'photos', key: 'a.jpg'));
      expect(deleteResult.isSuccess, isTrue);

      final ensureResult = await EnsureBucketUseCase(client: client)(
          const EnsureBucketParams(bucket: 'photos'));
      expect(ensureResult.isSuccess, isTrue);
      expect(transport.requests.map((r) => r.method), ['DELETE', 'HEAD', 'PUT']);
    });

    test('mapFailureToMinioException round-trips', () {
      const error = MinioException('put_object_500', 'boom');
      final mapped = mapFailureToMinioException(minioFailure(error));
      expect(mapped, same(error));
    });
  });
}
