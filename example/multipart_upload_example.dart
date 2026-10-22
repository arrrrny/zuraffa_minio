// A multipart upload, part by part.
//
// This is the example upstream issue #102 asked for ("MultipartUpload
// example"). It shows how to drive a multipart upload by hand:
//
//   1. ask the server for an upload id,
//   2. upload the parts one by one (they may be uploaded in parallel, see
//      the `maxParallelUploads` argument of `putObject`),
//   3. tell the server that the upload is complete.
//
// Run a MinIO server on 127.0.0.1:9000 first, then:
//
//   dart run example/multipart_upload_example.dart
import 'dart:typed_data';

import 'package:zuraffa_minio/minio.dart';
import 'package:zuraffa_minio/models.dart';

const endPoint = '127.0.0.1';
const port = 9000;
const accessKey = 'minioadmin';
const secretKey = 'minioadmin';
const bucketName = 'zuraffa-minio-example';

Future<void> main() async {
  final minio = Minio(
    endPoint: endPoint,
    port: port,
    accessKey: accessKey,
    secretKey: secretKey,
    useSSL: false,
  );

  if (!await minio.bucketExists(bucketName)) {
    await minio.makeBucket(bucketName);
  }

  // The object is uploaded in two parts of 5 MiB, which is the smallest part
  // size S3 accepts.
  const partSize = 5 * 1024 * 1024;
  final part1 = _filler(partSize, 1);
  final part2 = _filler(partSize, 2);

  final uploadId = await minio.initiateNewMultipartUpload(
    bucketName,
    'multipart.bin',
    null,
  );

  try {
    final etag1 = await minio.uploadPart(
      bucketName,
      'multipart.bin',
      uploadId,
      1,
      part1,
    );
    final etag2 = await minio.uploadPart(
      bucketName,
      'multipart.bin',
      uploadId,
      2,
      part2,
    );

    final etag = await minio.completeMultipartUpload(
      bucketName,
      'multipart.bin',
      uploadId,
      [CompletedPart(etag1, 1), CompletedPart(etag2, 2)],
    );

    print('uploaded, etag: $etag');

    final stat = await minio.statObject(bucketName, 'multipart.bin');
    print('size: ${stat.size}');
  } catch (e) {
    // Do not leave a half finished upload behind.
    await minio.removeIncompleteUpload(bucketName, 'multipart.bin');
    rethrow;
  }

  await minio.removeObject(bucketName, 'multipart.bin');
}

/// A part of `size` bytes whose content is `seed`.
Uint8List _filler(int size, int seed) {
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = (i + seed) % 256;
  }
  return bytes;
}
