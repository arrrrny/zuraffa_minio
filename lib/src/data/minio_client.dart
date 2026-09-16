import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../domain/entities/minio_types.dart';
import '../domain/ports/minio_transport.dart';
import '../s3/s3_sigv4.dart';
import 'io_minio_transport.dart';

/// A zuraffa-native MinIO / S3-compatible client.
///
/// Constructor- and method-compatible with the client the zuraffa ecosystem
/// used to get from the (abandoned) `minio` pub package — but implemented
/// directly on SigV4 signing + a plain HTTP transport, with no legacy
/// dependency and no xml 6 pin.
///
/// ```dart
/// final client = MinioClient(
///   endpoint: 'http://localhost:9000',
///   accessKey: 'minioadmin',
///   secretKey: 'minioadmin',
/// );
/// await client.ensureBucket('photos');
/// await client.putObjectBytes(
///   bucket: 'photos', key: 'a.jpg', bytes: bytes, contentType: 'image/jpeg',
/// );
/// ```
class MinioClient {
  /// Base endpoint URL (e.g. `http://localhost:9000`).
  final String endpoint;

  /// S3 access key (MinIO username).
  final String accessKey;

  /// S3 secret key (MinIO password).
  final String secretKey;

  /// AWS region string. MinIO defaults to `us-east-1`.
  final String region;

  /// Whether to use path-style addressing (`host/bucket/key`).
  final bool pathStyle;

  final MinioTransport _transport;
  final S3SigV4 _signer;

  MinioClient({
    required this.endpoint,
    required this.accessKey,
    required this.secretKey,
    this.region = 'us-east-1',
    this.pathStyle = true,
    MinioTransport? transport,
  })  : _transport = transport ?? IoMinioTransport(),
        _signer = S3SigV4(
          accessKey: accessKey,
          secretKey: secretKey,
          region: region,
        );

  Uri _url(String path, [Map<String, String>? query]) {
    final base = Uri.parse(endpoint);
    return base.replace(
      path: path,
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
  }

  Future<MinioResponse> _send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Uint8List? body,
  }) {
    final signed = _signer.sign(
      method: method,
      url: url,
      headers: {...headers, 'host': url.hasPort ? '${url.host}:${url.port}' : url.host},
      body: body,
    );
    final sendHeaders = Map<String, String>.from(signed.headers)
      ..['Authorization'] = signed.authorization
      ..remove('host');
    return _transport.send(MinioRequest(
      method: method,
      url: url,
      headers: sendHeaders,
      body: body,
    ));
  }

  // ── Bucket operations ────────────────────────────────────────────────

  /// Whether [bucket] exists and is accessible.
  Future<bool> bucketExists(String bucket) async {
    final resp = await _send('HEAD', _url('/$bucket'));
    if (resp.statusCode == 200) return true;
    if (resp.statusCode == 404) return false;
    throw MinioException(
        'bucket_head_${resp.statusCode}', 'HEAD /$bucket -> ${resp.statusCode}');
  }

  /// Creates [bucket] if it does not exist. Returns whether it now exists.
  Future<bool> ensureBucket(String bucket) async {
    if (await bucketExists(bucket)) return true;
    final resp = await _send('PUT', _url('/$bucket'));
    if (resp.statusCode == 200) return true;
    throw MinioException(
        'bucket_create_${resp.statusCode}', 'PUT /$bucket -> ${resp.statusCode}');
  }

  /// Removes [bucket]. Returns success.
  Future<bool> removeBucket(String bucket) async {
    final resp = await _send('DELETE', _url('/$bucket'));
    return resp.statusCode == 204 || resp.statusCode == 200;
  }

  // ── Object operations ────────────────────────────────────────────────

  /// Uploads [data] as UTF-8 with optional [metadata] (`x-amz-meta-*`).
  Future<bool> putObject({
    required String bucket,
    required String key,
    required String data,
    String contentType = 'application/octet-stream',
    Map<String, String>? metadata,
  }) =>
      putObjectBytes(
        bucket: bucket,
        key: key,
        bytes: Uint8List.fromList(utf8.encode(data)),
        contentType: contentType,
        metadata: metadata,
      );

  /// Uploads raw [bytes].
  Future<bool> putObjectBytes({
    required String bucket,
    required String key,
    required Uint8List bytes,
    String contentType = 'application/octet-stream',
    Map<String, String>? metadata,
  }) async {
    final resp = await _send(
      'PUT',
      _url('/$bucket/$key'),
      headers: {
        'content-type': contentType,
        for (final e in (metadata ?? const {}).entries)
          'x-amz-meta-${e.key}': e.value,
      },
      body: bytes,
    );
    if (resp.statusCode == 200) return true;
    throw MinioException('put_object_${resp.statusCode}',
        'PUT /$bucket/$key -> ${resp.statusCode}');
  }

  /// Retrieves an object as a UTF-8 string, or null when missing.
  Future<String?> getObject(String bucket, String key) async {
    final bytes = await getObjectBytes(bucket, key);
    return bytes == null ? null : utf8.decode(bytes);
  }

  /// Retrieves an object as bytes, or null when missing.
  Future<Uint8List?> getObjectBytes(String bucket, String key) async {
    final resp = await _send('GET', _url('/$bucket/$key'));
    if (resp.statusCode == 404) return null;
    if (resp.statusCode != 200) {
      throw MinioException('get_object_${resp.statusCode}',
          'GET /$bucket/$key -> ${resp.statusCode}');
    }
    return resp.body;
  }

  /// Deletes [key] from [bucket]. Returns success.
  Future<bool> deleteObject(String bucket, String key) async {
    final resp = await _send('DELETE', _url('/$bucket/$key'));
    return resp.statusCode == 204 || resp.statusCode == 200;
  }

  /// Deletes every key in [keys]. Returns true when all deletions succeed.
  Future<bool> deleteObjects(String bucket, List<String> keys) async {
    var ok = true;
    for (final key in keys) {
      ok = await deleteObject(bucket, key) && ok;
    }
    return ok;
  }

  /// Object metadata (HEAD Object), or null when missing.
  Future<ObjectStat?> statObject(String bucket, String key) async {
    final resp = await _send('HEAD', _url('/$bucket/$key'));
    if (resp.statusCode == 404) return null;
    if (resp.statusCode != 200) {
      throw MinioException('stat_object_${resp.statusCode}',
          'HEAD /$bucket/$key -> ${resp.statusCode}');
    }
    final size = int.tryParse(resp.headers['content-length'] ?? '') ?? 0;
    return ObjectStat(
      size: size,
      etag: resp.headers['etag']?.replaceAll('"', ''),
      contentType: resp.headers['content-type'],
      lastModified: _httpDate(resp.headers['last-modified']),
    );
  }

  /// Lists objects in [bucket] (ListObjectsV2). [recursive] lists the whole
  /// hierarchy; otherwise only the top level under [prefix].
  Future<List<ObjectInfo>> listObjects(
    String bucket, {
    String? prefix,
    bool recursive = false,
  }) async {
    final resp = await _send('GET', _url('/$bucket', {
      'list-type': '2',
      if (prefix != null) 'prefix': prefix,
      if (!recursive) 'delimiter': '/',
    }));
    if (resp.statusCode != 200) {
      throw MinioException('list_objects_${resp.statusCode}',
          'GET /$bucket?list-type=2 -> ${resp.statusCode}');
    }
    final doc = XmlDocument.parse(utf8.decode(resp.body));
    return doc.findAllElements('Contents').map((e) {
      String text(String name) =>
          e.getElement(name)?.innerText ?? '';
      return ObjectInfo(
        key: text('Key'),
        size: int.tryParse(text('Size')) ?? 0,
        etag: text('ETag').replaceAll('"', ''),
        lastModified: DateTime.tryParse(text('LastModified')),
      );
    }).toList();
  }

  // ── Presigned URLs ───────────────────────────────────────────────────

  /// A presigned GET URL for [bucket]/[key].
  String presignedGetObject(
    String bucket,
    String key, {
    Duration expires = const Duration(minutes: 15),
  }) =>
      _signer
          .presign(method: 'GET', url: _url('/$bucket/$key'), expires: expires)
          .toString();

  /// A presigned PUT URL for [bucket]/[key].
  String presignedPutObject(
    String bucket,
    String key, {
    Duration expires = const Duration(minutes: 15),
  }) =>
      _signer
          .presign(method: 'PUT', url: _url('/$bucket/$key'), expires: expires)
          .toString();

  void close() => _transport.close();

  static DateTime? _httpDate(String? value) =>
      value == null ? null : DateTime.tryParse(value);
}
