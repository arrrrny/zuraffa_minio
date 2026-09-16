import 'dart:typed_data';

// Hide zuraffa's own MinioClient (its wrapper over the abandoned
// minio package) so this package's client is unambiguous during the
// transition; the hide can go once zuraffa drops minio.
import 'package:zuraffa/zuraffa.dart' hide MinioClient;

import '../../data/minio_client.dart';
import '../entities/minio_types.dart';
import '../failures/minio_failure.dart';

/// Parameters for [UploadObjectUseCase].
class UploadObjectParams {
  final String bucket;
  final String key;
  final Uint8List bytes;
  final String contentType;
  final Map<String, String>? metadata;

  const UploadObjectParams({
    required this.bucket,
    required this.key,
    required this.bytes,
    this.contentType = 'application/octet-stream',
    this.metadata,
  });
}

/// Uploads bytes to [UploadObjectParams.bucket]/[key].
class UploadObjectUseCase extends UseCase<void, UploadObjectParams> {
  final MinioClient client;

  UploadObjectUseCase({required this.client});

  @override
  Future<void> execute(UploadObjectParams params, CancelToken? cancelToken) async {
    try {
      final ok = await client.putObjectBytes(
        bucket: params.bucket,
        key: params.key,
        bytes: params.bytes,
        contentType: params.contentType,
        metadata: params.metadata,
      );
      if (!ok) {
        throw MinioException(
            'upload_failed', 'PUT ${params.bucket}/${params.key} returned false');
      }
    } on MinioException catch (e) {
      throw minioFailure(e);
    }
  }
}

/// Parameters for [DownloadObjectUseCase].
class DownloadObjectParams {
  final String bucket;
  final String key;

  const DownloadObjectParams({required this.bucket, required this.key});
}

/// Downloads an object's bytes (null when the object does not exist).
class DownloadObjectUseCase
    extends UseCase<Uint8List?, DownloadObjectParams> {
  final MinioClient client;

  DownloadObjectUseCase({required this.client});

  @override
  Future<Uint8List?> execute(
      DownloadObjectParams params, CancelToken? cancelToken) async {
    try {
      return await client.getObjectBytes(params.bucket, params.key);
    } on MinioException catch (e) {
      throw minioFailure(e);
    }
  }
}

/// Parameters for [DeleteObjectUseCase].
class DeleteObjectParams {
  final String bucket;
  final String key;

  const DeleteObjectParams({required this.bucket, required this.key});
}

/// Deletes a single object.
class DeleteObjectUseCase extends UseCase<void, DeleteObjectParams> {
  final MinioClient client;

  DeleteObjectUseCase({required this.client});

  @override
  Future<void> execute(DeleteObjectParams params, CancelToken? cancelToken) async {
    try {
      await client.deleteObject(params.bucket, params.key);
    } on MinioException catch (e) {
      throw minioFailure(e);
    }
  }
}

/// Parameters for [EnsureBucketUseCase].
class EnsureBucketParams {
  final String bucket;

  const EnsureBucketParams({required this.bucket});
}

/// Ensures the bucket exists (creates it when missing).
class EnsureBucketUseCase extends UseCase<void, EnsureBucketParams> {
  final MinioClient client;

  EnsureBucketUseCase({required this.client});

  @override
  Future<void> execute(EnsureBucketParams params, CancelToken? cancelToken) async {
    try {
      await client.ensureBucket(params.bucket);
    } on MinioException catch (e) {
      throw minioFailure(e);
    }
  }
}
