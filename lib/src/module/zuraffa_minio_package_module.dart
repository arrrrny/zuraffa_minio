// Hide zuraffa's own MinioClient (its wrapper over the abandoned
// minio package) so this package's client is unambiguous during the
// transition; the hide can go once zuraffa drops minio.
import 'package:zuraffa/zuraffa.dart' hide MinioClient;

import '../di/zuraffa_minio_package_registrar.dart';

/// Zuraffa runtime module for zuraffa_minio.
///
/// Contributes the MinIO client and object usecases to the consuming app's
/// container (auto-DI). The connection config is supplied at registration —
/// nothing is read from the environment implicitly:
///
/// ```dart
/// final engine = ZuraffaEngine()
///   ..registerPackage(ZuraffaMinioModule(
///     endpoint: 'http://localhost:9000',
///     accessKey: 'minioadmin',
///     secretKey: 'minioadmin',
///   ));
/// await engine.bootstrap();
/// ```
class ZuraffaMinioModule extends PackageModule {
  final String? endpoint;
  final String? accessKey;
  final String? secretKey;
  final String region;

  ZuraffaMinioModule({
    this.endpoint,
    this.accessKey,
    this.secretKey,
    this.region = 'us-east-1',
  });

  @override
  String get pluginId => 'zuraffa_minio';

  @override
  String get zuraffaSdkConstraint => '^6.3.0';

  @override
  Map<String, ZuraffaRouteHandler> get routes => const {};

  @override
  Future<void> registerDependencies(ZuraffaDIContainer di) =>
      registerZuraffaMinio(di,
          endpoint: endpoint,
          accessKey: accessKey,
          secretKey: secretKey,
          region: region);
}
