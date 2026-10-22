import 'package:test/test.dart';
import 'package:zuraffa_minio/minio.dart';

// The presigned-URL tests build a URL and sign it; they never touch the
// network, so they use package:test's own `test` rather than the
// server-aware wrapper in helpers.dart, and they run without a server.
import 'helpers.dart' hide setUpAll, tearDownAll, test;

void main() {
  test('Minio.presignedGetObject() works', () async {
    final minio = getMinioClient();
    await minio.presignedGetObject('bucket', 'object');
  });

  test('Minio.presignedGetObject() throws when [expires] < 0', () async {
    final minio = getMinioClient();
    expect(
      () => minio.presignedGetObject('bucket', 'object', expires: -1),
      throwsA(isA<MinioError>()),
    );
  });

  test('Minio.presignedPutObject() works', () async {
    final minio = getMinioClient();
    await minio.presignedPutObject('bucket', 'object');
  });

  test('Minio.presignedPutObject() throws when [expires] < 0', () async {
    final minio = getMinioClient();
    expect(
      () => minio.presignedPutObject('bucket', 'object', expires: -1),
      throwsA(isA<MinioError>()),
    );
  });
}
