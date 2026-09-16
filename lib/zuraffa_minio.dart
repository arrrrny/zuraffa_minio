/// zuraffa_minio — Zuraffa-native MinIO / S3-compatible client.
///
/// Replaces the abandoned `minio` pub package for the zuraffa ecosystem:
/// pure Dart, SigV4-signed, no legacy dependency (and therefore no xml 6
/// pin). UseCases + PackageModule provide the zuraffa auto-DI surface.
library;

export 'src/data/io_minio_transport.dart' show IoMinioTransport;
export 'src/data/minio_client.dart' show MinioClient;
export 'src/domain/entities/minio_types.dart'
    show MinioException, ObjectInfo, ObjectStat;
export 'src/domain/failures/minio_failure.dart'
    show mapFailureToMinioException, minioFailure;
export 'src/domain/ports/minio_transport.dart'
    show MinioRequest, MinioResponse, MinioTransport;
export 'src/domain/usecases/minio_usecases.dart'
    show
        DeleteObjectParams,
        DeleteObjectUseCase,
        DownloadObjectParams,
        DownloadObjectUseCase,
        EnsureBucketParams,
        EnsureBucketUseCase,
        UploadObjectParams,
        UploadObjectUseCase;
export 'src/module/zuraffa_minio_package_module.dart' show ZuraffaMinioModule;
export 'src/di/zuraffa_minio_package_registrar.dart' show registerZuraffaMinio;
export 'src/s3/s3_sigv4.dart' show S3SigV4, SignedHeaders;
