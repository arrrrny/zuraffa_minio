// Hide zuraffa's own MinioClient (its wrapper over the abandoned
// minio package) so this package's client is unambiguous during the
// transition; the hide can go once zuraffa drops minio.
import 'package:zuraffa/zuraffa.dart' hide MinioClient;

import '../data/minio_client.dart';
import '../domain/entities/minio_types.dart';
import '../domain/usecases/minio_usecases.dart';

/// Registers the MinIO client and its usecases into [di].
///
/// Nothing already registered is overridden — pre-register a [MinioClient]
/// (or a fake transport) first and the registrar defers to it.
Future<void> registerZuraffaMinio(
  ZuraffaDIContainer di, {
  String? endpoint,
  String? accessKey,
  String? secretKey,
  String region = 'us-east-1',
}) async {
  if (!di.getIt.isRegistered<MinioClient>()) {
    await di.registerLazySingleton<MinioClient>(() {
      if (endpoint == null || accessKey == null || secretKey == null) {
        throw const MinioException(
          'config_missing',
          'MinIO endpoint/accessKey/secretKey were not provided to '
          'registerZuraffaMinio and no MinioClient was pre-registered.',
          recoverable: false,
        );
      }
      return MinioClient(
        endpoint: endpoint,
        accessKey: accessKey,
        secretKey: secretKey,
        region: region,
      );
    });
  }
  if (!di.getIt.isRegistered<UploadObjectUseCase>()) {
    await di.registerFactory<UploadObjectUseCase>(
        () => UploadObjectUseCase(client: di.getIt<MinioClient>()));
  }
  if (!di.getIt.isRegistered<DownloadObjectUseCase>()) {
    await di.registerFactory<DownloadObjectUseCase>(
        () => DownloadObjectUseCase(client: di.getIt<MinioClient>()));
  }
  if (!di.getIt.isRegistered<DeleteObjectUseCase>()) {
    await di.registerFactory<DeleteObjectUseCase>(
        () => DeleteObjectUseCase(client: di.getIt<MinioClient>()));
  }
  if (!di.getIt.isRegistered<EnsureBucketUseCase>()) {
    await di.registerFactory<EnsureBucketUseCase>(
        () => EnsureBucketUseCase(client: di.getIt<MinioClient>()));
  }
}
