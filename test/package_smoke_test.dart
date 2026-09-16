// Package smoke test — the scaffold's registrable-module contract, updated
// for this package's surface (see test/minio_module_test.dart for the full
// module suite).
import 'package:test/test.dart';
import 'package:zuraffa/zuraffa.dart' hide MinioClient;
import 'package:zuraffa_minio/zuraffa_minio.dart';

void main() {
  test('package exposes a registrable module', () {
    final module = ZuraffaMinioModule();
    expect(module.pluginId, 'zuraffa_minio');
    expect(module.routes, isEmpty);
  });

  test('package registrar runs cleanly on a fresh container', () async {
    await GetIt.I.reset();
    await registerZuraffaMinio(
      ZuraffaDIContainer(),
      endpoint: 'http://localhost:9000',
      accessKey: 'a',
      secretKey: 'b',
    );
    await GetIt.I.reset();
  });
}
