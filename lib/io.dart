import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' show dirname;
import 'package:zuraffa_minio/src/minio.dart';
import 'package:zuraffa_minio/src/minio_errors.dart';
import 'package:zuraffa_minio/src/minio_helpers.dart';

/// Creates an [http.Client] for a server that uses TLS.
///
/// [securityContext] is the context the TLS handshake is made with. When
/// [allowInvalidCertificates] is true the certificate of the server is not
/// verified, which is what upstream issue #80 asked for: a self signed
/// certificate, or one issued for another host, is accepted.
///
/// Skipping the verification is dangerous — the connection is not protected
/// against a man in the middle. Use it only against a server you trust, and
/// prefer a certificate that is valid.
///
/// The client is meant to be handed to the [Minio] constructor:
///
/// ```dart
/// final minio = Minio(
///   endPoint: 'minio.example.com',
///   accessKey: '...',
///   secretKey: '...',
///   httpClient: createTlsHttpClient(allowInvalidCertificates: true),
/// );
/// ```
http.Client createTlsHttpClient({
  SecurityContext? securityContext,
  bool allowInvalidCertificates = false,
}) {
  final context = securityContext ?? SecurityContext(withTrustedRoots: true);
  final inner = HttpClient(context: context);

  if (allowInvalidCertificates) {
    inner.badCertificateCallback = (cert, host, port) => true;
  }

  return IOClient(inner);
}

extension MinioX on Minio {
  // Uploads the object using contents from a file
  Future<String> fPutObject(
    String bucket,
    String object,
    String filePath, {
    Map<String, String>? metadata,
    void Function(int)? onProgress,
  }) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    metadata ??= {};
    metadata = insertContentType(metadata, filePath);
    metadata = prependXAMZMeta(metadata);

    final file = File(filePath);
    final stat = await file.stat();
    if (stat.size > maxObjectSize) {
      throw MinioError('$filePath size : ${stat.size}, max allowed size : 5TB');
    }

    return putObject(
      bucket,
      object,
      file.openRead().cast<Uint8List>(),
      size: stat.size,
      metadata: metadata,
      onProgress: onProgress,
    );
  }

  /// Downloads and saves the object as a file in the local filesystem.
  Future<void> fGetObject(String bucket, String object, String filePath) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    final stat = await statObject(bucket, object);
    final dir = dirname(filePath);
    await Directory(dir).create(recursive: true);

    final partFileName = '$filePath.${stat.etag}.part.minio';
    final partFile = File(partFileName);
    IOSink partFileStream;
    var offset = 0;

    Future<void> rename() async {
      await partFile.rename(filePath);
    }

    if (await partFile.exists()) {
      final localStat = await partFile.stat();
      if (stat.size == localStat.size) return await rename();
      offset = localStat.size;
      partFileStream = partFile.openWrite(mode: FileMode.append);
    } else {
      partFileStream = partFile.openWrite(mode: FileMode.write);
    }

    final dataStream = await getPartialObject(bucket, object, offset);
    await dataStream.pipe(partFileStream);

    final localStat = await partFile.stat();
    if (localStat.size != stat.size) {
      throw MinioError('Size mismatch between downloaded file and the object');
    }

    return rename();
  }
}
