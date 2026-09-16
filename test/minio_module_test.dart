import 'package:test/test.dart';
import 'package:zuraffa/zuraffa.dart' hide MinioClient;
import 'package:zuraffa_minio/zuraffa_minio.dart';

import 'minio_client_test.dart' show FakeMinioTransport;

void main() {
  group('registerZuraffaMinio', () {
    late ZuraffaDIContainer di;

    setUp(() async {
      await GetIt.I.reset();
      di = ZuraffaDIContainer();
    });

    tearDown(() async {
      await GetIt.I.reset();
    });

    test('registers client + all usecases', () async {
      await registerZuraffaMinio(
        di,
        endpoint: 'http://localhost:9000',
        accessKey: 'a',
        secretKey: 'b',
      );

      expect(di.getIt.isRegistered<MinioClient>(), isTrue);
      expect(di.getIt.isRegistered<UploadObjectUseCase>(), isTrue);
      expect(di.getIt.isRegistered<DownloadObjectUseCase>(), isTrue);
      expect(di.getIt.isRegistered<DeleteObjectUseCase>(), isTrue);
      expect(di.getIt.isRegistered<EnsureBucketUseCase>(), isTrue);
      expect(di.getIt<UploadObjectUseCase>().client,
          same(di.getIt<MinioClient>()));
    });

    test('pre-registered client is never overridden', () async {
      final fake = MinioClient(
        endpoint: 'http://localhost:9000',
        accessKey: 'a',
        secretKey: 'b',
        transport: FakeMinioTransport(),
      );
      di.getIt.registerSingleton<MinioClient>(fake);

      await registerZuraffaMinio(di);

      expect(di.getIt<MinioClient>(), same(fake));
      expect(di.getIt<UploadObjectUseCase>().client, same(fake));
    });

    test('missing config without a pre-registered client fails typed',
        () async {
      await registerZuraffaMinio(di);
      expect(
        () => di.getIt<MinioClient>(),
        throwsA(isA<MinioException>()
            .having((e) => e.code, 'code', 'config_missing')),
      );
    });
  });

  group('ZuraffaMinioModule', () {
    test('module registration contributes the same surface', () async {
      await GetIt.I.reset();
      addTearDown(() async => GetIt.I.reset());

      final module = ZuraffaMinioModule(
        endpoint: 'http://localhost:9000',
        accessKey: 'a',
        secretKey: 'b',
      );
      expect(module.pluginId, 'zuraffa_minio');

      final di = ZuraffaDIContainer();
      await module.registerDependencies(di);

      expect(di.getIt.isRegistered<EnsureBucketUseCase>(), isTrue);
      expect(di.getIt<MinioClient>().endpoint, 'http://localhost:9000');
    });
  });
}
