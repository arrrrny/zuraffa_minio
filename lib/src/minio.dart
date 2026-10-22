// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;
import 'package:xml/xml.dart' show XmlElement;
import 'package:zuraffa_minio/src/minio_cancellation.dart';
import 'package:zuraffa_minio/src/minio_client.dart';
import 'package:zuraffa_minio/src/minio_errors.dart';
import 'package:zuraffa_minio/src/minio_helpers.dart';
import 'package:zuraffa_minio/src/minio_models.dart';
import 'package:zuraffa_minio/src/minio_models_generated.dart';
import 'package:zuraffa_minio/src/minio_parallel.dart';
import 'package:zuraffa_minio/src/minio_poller.dart';
import 'package:zuraffa_minio/src/minio_sign.dart';
import 'package:zuraffa_minio/src/minio_stream.dart';
import 'package:zuraffa_minio/src/minio_uploader.dart';
import 'package:zuraffa_minio/src/utils.dart';

/// A set of credentials used to sign the requests of a [Minio] client.
///
/// This answers upstream issue #94 ("Support temporary credentials / session
/// token renewal") of the `minio` package: short-lived credentials of a
/// security token service can be handed to the client through a
/// `credentialsProvider` instead of being fixed at construction time.
class MinioCredentials {
  /// Creates a credential set.
  MinioCredentials({
    required this.accessKey,
    required this.secretKey,
    this.sessionToken,
  });

  /// The access key identifying the account.
  final String accessKey;

  /// The secret key of the account.
  final String secretKey;

  /// The session token accompanying the credentials, if any.
  final String? sessionToken;
}

/// Resolves the credentials a [Minio] client signs with.
///
/// Called by the client whenever it needs credentials that may have expired;
/// see [MinioCredentials] and upstream issue #94.
typedef MinioCredentialsProvider = Future<MinioCredentials> Function();

class Minio {
  /// Initializes a new client object.
  ///
  /// The keys are required on purpose. A client whose keys were forgotten
  /// signs every request with an empty key and is anonymous without saying
  /// so; a compile error is the better answer. A client that resolves its
  /// own credentials uses [Minio.withCredentialsProvider] instead.
  Minio({
    required String endPoint,
    required String accessKey,
    required String secretKey,
    int? port,
    bool useSSL = true,
    String? sessionToken,
    String? region,
    bool? pathStyle,
    bool enableTrace = false,
    http.Client? httpClient,
    MinioCredentialsProvider? credentialsProvider,
    Duration credentialsTtl = const Duration(minutes: 5),
    MinioCancellationToken? cancellationToken,
  }) : this._(
         endPoint: endPoint,
         accessKey: accessKey,
         secretKey: secretKey,
         port: port,
         useSSL: useSSL,
         sessionToken: sessionToken,
         region: region,
         pathStyle: pathStyle,
         enableTrace: enableTrace,
         httpClient: httpClient,
         credentialsProvider: credentialsProvider,
         credentialsTtl: credentialsTtl,
         cancellationToken: cancellationToken,
       );

  /// Initializes a client that resolves its credentials itself.
  ///
  /// The provider is called before every signature that needs fresh
  /// credentials, and its result is cached for [credentialsTtl]
  /// (upstream issue #94).
  Minio.withCredentialsProvider({
    required String endPoint,
    required MinioCredentialsProvider credentialsProvider,
    int? port,
    bool useSSL = true,
    String? region,
    bool? pathStyle,
    bool enableTrace = false,
    http.Client? httpClient,
    Duration credentialsTtl = const Duration(minutes: 5),
    MinioCancellationToken? cancellationToken,
  }) : this._(
         endPoint: endPoint,
         accessKey: '',
         secretKey: '',
         port: port,
         useSSL: useSSL,
         sessionToken: null,
         region: region,
         pathStyle: pathStyle,
         enableTrace: enableTrace,
         httpClient: httpClient,
         credentialsProvider: credentialsProvider,
         credentialsTtl: credentialsTtl,
         cancellationToken: cancellationToken,
       );

  Minio._({
    required this.endPoint,
    required String accessKey,
    required String secretKey,
    int? port,
    this.useSSL = true,
    String? sessionToken,
    this.region,
    this.pathStyle,
    this.enableTrace = false,
    http.Client? httpClient,
    this.credentialsProvider,
    this.credentialsTtl = const Duration(minutes: 5),
    this.cancellationToken,
  }) : port = port ?? implyPort(useSSL),
       _httpClient = httpClient,
       _staticCredentials = MinioCredentials(
         accessKey: accessKey,
         secretKey: secretKey,
         sessionToken: sessionToken,
       ) {
    if (!isValidEndpoint(endPoint)) {
      throw MinioInvalidEndpointError(
        'End point $endPoint is not a valid domain or ip address',
      );
    }

    if (!isValidPort(this.port)) {
      throw MinioInvalidPortError('Invalid port number ${this.port}');
    }

    _client = MinioClient(this);

    // When the token is cancelled the HTTP client is closed, which aborts
    // every request that is in flight (upstream issues #85, #45, #93).
    unawaited(cancellationToken?.whenCancelled.then((_) => close()));
  }

  /// default part size for multipart uploads.
  final partSize = 64 * 1024 * 1024;

  /// maximum part size for multipart uploads.
  final maximumPartSize = 5 * 1024 * 1024 * 1024;

  /// maximum object size (5TB)
  final maxObjectSize = 5 * 1024 * 1024 * 1024 * 1024;

  /// endPoint is a host name or an IP address.
  ///
  /// For example:
  /// - play.min.io
  /// - 1.2.3.4
  final String endPoint;

  /// TCP/IP port number. This input is optional. Default value set to 80 for HTTP and 443 for HTTPs.
  final int port;

  /// If set to true, https is used instead of http. Default is true.
  final bool useSSL;

  /// accessKey is like user-id that uniquely identifies your account.
  ///
  /// When a [credentialsProvider] is configured (upstream issue #94), this
  /// is the access key of the credentials the provider last resolved;
  /// otherwise it is the value passed to the constructor.
  String get accessKey {
    final resolved = _resolvedCredentials;
    if (credentialsProvider != null && resolved != null) {
      return resolved.accessKey;
    }
    return _staticCredentials.accessKey;
  }

  /// secretKey is the password to your account.
  ///
  /// When a [credentialsProvider] is configured (upstream issue #94), this
  /// is the secret key of the credentials the provider last resolved;
  /// otherwise it is the value passed to the constructor.
  String get secretKey {
    final resolved = _resolvedCredentials;
    if (credentialsProvider != null && resolved != null) {
      return resolved.secretKey;
    }
    return _staticCredentials.secretKey;
  }

  /// Set this value to provide x-amz-security-token (AWS S3 specific). (Optional)
  ///
  /// When a [credentialsProvider] is configured (upstream issue #94), this
  /// is the session token of the credentials the provider last resolved;
  /// otherwise it is the value passed to the constructor.
  String? get sessionToken {
    final resolved = _resolvedCredentials;
    if (credentialsProvider != null && resolved != null) {
      return resolved.sessionToken;
    }
    return _staticCredentials.sessionToken;
  }

  /// Resolves short-lived credentials before every signature, instead of
  /// using the constructor's static keys. (Optional)
  ///
  /// This answers upstream issue #94 ("Support temporary credentials /
  /// session token renewal") of the `minio` package.
  final MinioCredentialsProvider? credentialsProvider;

  /// How long credentials from [credentialsProvider] stay fresh.
  ///
  /// Older credentials are resolved again before the next request is
  /// signed. Defaults to five minutes. (upstream issue #94)
  final Duration credentialsTtl;

  /// Cancels every in-flight and future request of this client. (Optional)
  ///
  /// This answers upstream issues #85, #45 and #93 ("How to cancel a
  /// request?") of the `minio` package.
  final MinioCancellationToken? cancellationToken;

  final MinioCredentials _staticCredentials;
  MinioCredentials? _resolvedCredentials;
  DateTime? _resolvedAt;

  /// The credentials the next request will be signed with.
  ///
  /// When a [credentialsProvider] is configured and its last result is
  /// older than [credentialsTtl], the provider is consulted again. The
  /// resolution is awaited before every signature is computed, so the
  /// credentials that end up in the signature and in the
  /// `x-amz-security-token` header are always the resolved ones.
  /// (upstream issue #94)
  Future<MinioCredentials> resolveCredentials() async {
    final provider = credentialsProvider;
    if (provider == null) return _staticCredentials;

    final resolved = _resolvedCredentials;
    final resolvedAt = _resolvedAt;
    if (resolved != null &&
        resolvedAt != null &&
        DateTime.now().difference(resolvedAt) < credentialsTtl) {
      return resolved;
    }

    final credentials = await provider();
    _resolvedCredentials = credentials;
    _resolvedAt = DateTime.now();
    return credentials;
  }

  /// Forces the [credentialsProvider] to be consulted again, discarding the
  /// cached credentials. (upstream issue #94)
  Future<void> refreshCredentials() async {
    if (credentialsProvider == null) return;
    _resolvedCredentials = null;
    _resolvedAt = null;
    await resolveCredentials();
  }

  /// Throws [MinioRequestCancelledError] when the [cancellationToken] has
  /// been cancelled. Every request path checks this before it is sent.
  /// (upstream issues #85, #45, #93)
  void throwIfCancelled() {
    if (cancellationToken?.isCancelled ?? false) {
      throw MinioRequestCancelledError(
        'The request was cancelled via the MinioCancellationToken',
      );
    }
  }

  /// Set this value to override region cache. (Optional)
  final String? region;

  /// Set this value to override default access behavior (path) for non AWS endpoints. Default is true. (Optional)
  final bool? pathStyle;

  /// Set this value to enable tracing. (Optional)
  final bool enableTrace;

  late MinioClient _client;
  final _regionMap = <String?, String>{};

  http.Client? _httpClient;

  /// Whether the client of this instance was created here.
  ///
  /// A client that was passed to the constructor belongs to the caller and is
  /// never closed by [close].
  bool _ownsHttpClient = false;

  /// The HTTP client every request is sent through.
  ///
  /// A client can be supplied to the constructor to take control of
  /// connection pooling, proxies, TLS configuration or cancellation
  /// (upstream issues #85, #45, #80, #93). When none is supplied a default
  /// one is created lazily and owned by this instance.
  http.Client get httpClient {
    if (_httpClient == null) {
      _httpClient = http.Client();
      _ownsHttpClient = true;
    }
    return _httpClient!;
  }

  /// Releases the resources held by the underlying HTTP client.
  ///
  /// Only a client created by this instance is closed; a client passed to the
  /// constructor stays the caller's responsibility.
  void close() {
    if (_ownsHttpClient) {
      _httpClient?.close();
      _httpClient = null;
      _ownsHttpClient = false;
    }
  }

  /// Remembers the region a bucket really lives in.
  ///
  /// Used to recover from a server that rejects a request signed for the
  /// wrong region (upstream issue #38).
  void cacheRegion(String bucket, String region) {
    _regionMap[bucket] = region;
  }

  /// Checks if a bucket exists.
  ///
  /// Returns `true` only if the [bucket] exists and you have the permission
  /// to access it. Returns `false` if the [bucket] does not exist or you
  /// don't have the permission to access it.
  Future<bool> bucketExists(String bucket) async {
    MinioInvalidBucketNameError.check(bucket);
    try {
      final response = await _client.request(method: 'HEAD', bucket: bucket);
      validate(response);
      return response.statusCode == 200;
    } on MinioS3Error catch (e) {
      final code = e.error?.code;
      if (code == 'NoSuchBucket' || code == 'NotFound' || code == 'Not Found') {
        return false;
      }
      rethrow;
    } on StateError catch (e) {
      // Insight from testing: in most cases, AWS S3 returns the HTTP status code
      // 404 when a bucket does not exist. Whereas in other cases, when the bucket
      // does not exist, S3 returns the HTTP status code 301 Redirect instead of
      // status code 404 as officially documented. Then, this redirect response
      // lacks the HTTP header `location` which causes this exception in Dart's
      // HTTP library (`http_impl.dart`).
      if (e.message == 'Response has no Location header for redirect') {
        return false;
      }
      rethrow;
    }
  }

  int _calculatePartSize(int size) {
    // An `assert` only fires in debug builds, so a negative size reached
    // release code and blew up later with an opaque error. Upstream issue #24
    // reported it as "the assert(size) issue".
    if (size < 0) {
      throw ArgumentError.value(size, 'size', 'must not be negative');
    }

    if (size > maxObjectSize) {
      throw ArgumentError('size should not be more than $maxObjectSize');
    }

    var partSize = this.partSize;
    while (true) {
      if ((partSize * 10000) > size) {
        return partSize;
      }
      partSize += 16 * 1024 * 1024;
    }
  }

  /// Complete the multipart upload. After all the parts are uploaded issuing
  /// this call will aggregate the parts on the server into a single object.
  Future<String> completeMultipartUpload(
    String bucket,
    String object,
    String uploadId,
    List<CompletedPart> parts,
  ) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    var queries = {'uploadId': uploadId};
    var payload = CompleteMultipartUpload(parts).toXml().toString();

    final resp = await _client.request(
      method: 'POST',
      bucket: bucket,
      object: object,
      queries: queries,
      payload: payload,
    );
    validate(resp, expect: 200);

    final node = xml.XmlDocument.parse(resp.body);
    final errorNode = node.findAllElements('Error');
    if (errorNode.isNotEmpty) {
      final error = Error.fromXml(errorNode.first);
      throw MinioS3Error(error.message, error, resp);
    }

    final etag = node.findAllElements('ETag').first.text;
    return etag;
  }

  /// Copy the object.
  Future<CopyObjectResult> copyObject(
    String bucket,
    String object,
    String srcObject, [
    CopyConditions? conditions,
  ]) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);
    MinioInvalidObjectNameError.check(srcObject);

    final headers = <String, String>{};
    headers['x-amz-copy-source'] = srcObject;

    if (conditions != null) {
      if (conditions.modified != null) {
        headers['x-amz-copy-source-if-modified-since'] = conditions.modified!;
      }
      if (conditions.unmodified != null) {
        headers['x-amz-copy-source-if-unmodified-since'] =
            conditions.unmodified!;
      }
      if (conditions.matchETag != null) {
        headers['x-amz-copy-source-if-match'] = conditions.matchETag!;
      }
      if (conditions.matchETagExcept != null) {
        headers['x-amz-copy-source-if-none-match'] =
            conditions.matchETagExcept!;
      }
    }

    final resp = await _client.request(
      method: 'PUT',
      bucket: bucket,
      object: object,
      headers: headers,
    );

    validate(resp);

    final node = xml.XmlDocument.parse(resp.body);
    final result = CopyObjectResult.fromXml(node.rootElement);
    result.eTag = trimDoubleQuote(result.eTag!);
    return result;
  }

  /// Find uploadId of an incomplete upload.
  Future<String?> findUploadId(String bucket, String object) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    MultipartUpload? latestUpload;
    String? keyMarker;
    String? uploadIdMarker;
    bool? isTruncated = false;

    do {
      final result = await listIncompleteUploadsQuery(
        bucket,
        object,
        keyMarker,
        uploadIdMarker,
        '',
      );
      for (var upload in result.uploads) {
        if (upload.key != object) continue;
        if (latestUpload == null ||
            upload.initiated!.isAfter(latestUpload.initiated!)) {
          latestUpload = upload;
        }
      }
      keyMarker = result.nextKeyMarker;
      uploadIdMarker = result.nextUploadIdMarker;
      isTruncated = result.isTruncated;
    } while (isTruncated!);

    return latestUpload?.uploadId;
  }

  /// Return the list of notification configurations stored
  /// in the S3 provider
  Future<NotificationConfiguration> getBucketNotification(String bucket) async {
    MinioInvalidBucketNameError.check(bucket);

    final resp = await _client.request(
      method: 'GET',
      bucket: bucket,
      resource: 'notification',
    );

    validate(resp, expect: 200);

    final node = xml.XmlDocument.parse(resp.body);
    return NotificationConfiguration.fromXml(node.rootElement);
  }

  /// Get the bucket policy associated with the specified bucket. If `objectPrefix`
  /// is not empty, the bucket policy will be filtered based on object permissions
  /// as well.
  Future<Map<String, dynamic>?> getBucketPolicy(bucket) async {
    MinioInvalidBucketNameError.check(bucket);

    final resp = await _client.request(
      method: 'GET',
      bucket: bucket,
      resource: 'policy',
    );

    validate(resp, expect: 200);

    return json.decode(resp.body);
  }

  /// Gets the region of [bucket]. The region is cached for subsequent calls.
  Future<String> getBucketRegion(String bucket) async {
    MinioInvalidBucketNameError.check(bucket);

    // A region the server itself confirmed wins over the configured one:
    // it is the only one known to be correct for this bucket.
    if (_regionMap.containsKey(bucket)) {
      return _regionMap[bucket]!;
    }

    if (region != null) {
      return region!;
    }

    final resp = await _client.request(
      method: 'GET',
      bucket: bucket,
      region: 'us-east-1',
      queries: <String, dynamic>{'location': null},
    );

    validate(resp);

    final node = xml.XmlDocument.parse(resp.body);

    var location = node.findAllElements('LocationConstraint').first.text;
    // if (location == null || location.isEmpty) {
    if (location.isEmpty) {
      location = 'us-east-1';
    }

    _regionMap[bucket] = location;
    return location;
  }

  /// get a readable stream of the object content.
  ///
  /// [onProgress] is invoked as the stream is consumed with the number of
  /// bytes received so far and the total size of the object when the server
  /// announced it (upstream issues #4 and #20).
  ///
  /// When [parallelism] is greater than one the object is fetched as
  /// concurrent byte ranges and streamed back in the original order
  /// (upstream issue #112). [chunkSize] is the size of a range; it defaults
  /// to a value that splits the object into [parallelism] pieces of at least
  /// 8 MiB.
  Future<MinioByteStream> getObject(
    String bucket,
    String object, {
    void Function(int bytesRead, int? totalBytes)? onProgress,
    int parallelism = 1,
    int? chunkSize,
  }) {
    // The chunk size is checked here and not only in the planner of the
    // ranges: a chunk size of zero would otherwise be rejected only after
    // the size of the object had been fetched over the network.
    if (chunkSize != null && chunkSize <= 0) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
    }

    if (parallelism > 1) {
      return _getObjectInParallel(
        bucket,
        object,
        parallelism: parallelism,
        chunkSize: chunkSize,
        onProgress: onProgress,
      );
    }

    return getPartialObject(bucket, object, null, null, onProgress);
  }

  /// Fetches an object as concurrent byte ranges.
  ///
  /// The ranges are requested in parallel and the bytes are streamed back in
  /// the order of the object, so the result is the same as a sequential
  /// download (upstream issue #112).
  Future<MinioByteStream> _getObjectInParallel(
    String bucket,
    String object, {
    required int parallelism,
    int? chunkSize,
    void Function(int bytesRead, int? totalBytes)? onProgress,
  }) async {
    final stat = await statObject(bucket, object, retrieveAcls: false);
    final totalBytes = stat.size;

    if (totalBytes == null || totalBytes == 0) {
      // Without a size there is nothing to split the object into.
      return getPartialObject(bucket, object, null, null, onProgress);
    }

    return fetchInParallel(
      fetch: (offset, length) async {
        final stream = await getPartialObject(bucket, object, offset, length);
        final bytes = <int>[];
        await for (final chunk in stream) {
          bytes.addAll(chunk);
        }
        return Uint8List.fromList(bytes);
      },
      totalBytes: totalBytes,
      chunkSize: chunkSize ?? _defaultChunkSize(totalBytes, parallelism),
      parallelism: parallelism,
      onProgress: onProgress,
    );
  }

  /// The size of a range of a parallel download.
  int _defaultChunkSize(int totalBytes, int parallelism) {
    const minimum = 8 * 1024 * 1024;
    final perWorker = (totalBytes / parallelism).ceil();
    return perWorker < minimum ? minimum : perWorker;
  }

  /// Reports the progress of a download as its bytes arrive.
  Stream<List<int>> _withDownloadProgress(
    Stream<List<int>> source,
    int? totalBytes,
    void Function(int bytesRead, int? totalBytes)? onProgress,
  ) {
    if (onProgress == null) return source;

    var received = 0;
    return source.map((chunk) {
      received += chunk.length;
      onProgress(received, totalBytes);
      return chunk;
    });
  }

  /// get a readable stream of the partial object content.
  ///
  /// [onProgress] is invoked as the stream is consumed with the number of
  /// bytes received so far and the total size of the requested range when
  /// the server announced it (upstream issues #4 and #20). It is optional
  /// positional because the method already has optional positional
  /// parameters.
  Future<MinioByteStream> getPartialObject(
    String bucket,
    String object, [
    int? offset,
    int? length,
    void Function(int bytesRead, int? totalBytes)? onProgress,
  ]) async {
    assert(offset == null || offset >= 0);
    assert(length == null || length > 0);

    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    String? range;
    if (offset != null || length != null) {
      if (offset != null) {
        range = 'bytes=$offset-';
      } else {
        range = 'bytes=0-';
        offset = 0;
      }
      if (length != null) {
        range += '${(length + offset) - 1}';
      }
    }

    final headers = range != null ? {'range': range} : null;
    final expectedStatus = range != null ? 206 : 200;

    final resp = await _client.requestStream(
      method: 'GET',
      bucket: bucket,
      object: object,
      headers: headers,
    );

    await validateStreamed(resp, expect: expectedStatus);

    final contentLength = resp.contentLength;
    return MinioByteStream.fromStream(
      stream: _withDownloadProgress(resp.stream, contentLength, onProgress),
      contentLength: contentLength,
    );
  }

  /// Initiate a new multipart upload.
  Future<String> initiateNewMultipartUpload(
    String bucket,
    String object,
    Map<String, String>? metaData,
  ) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    final resp = await _client.request(
      method: 'POST',
      bucket: bucket,
      object: object,
      headers: metaData,
      resource: 'uploads',
    );

    validate(resp, expect: 200);

    final node = xml.XmlDocument.parse(resp.body);
    return node.findAllElements('UploadId').first.text;
  }

  /// Returns a stream that emits objects that are partially uploaded.
  Stream<IncompleteUpload> listIncompleteUploads(
    String bucket,
    String prefix, [
    bool recursive = false,
  ]) async* {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidPrefixError.check(prefix);

    final delimiter = recursive ? '' : '/';

    String? keyMarker;
    String? uploadIdMarker;
    var isTruncated = false;

    do {
      final result = await listIncompleteUploadsQuery(
        bucket,
        prefix,
        keyMarker,
        uploadIdMarker,
        delimiter,
      );
      for (var upload in result.uploads) {
        int? size;
        try {
          final parts = listParts(bucket, upload.key!, upload.uploadId!);
          size = await parts.fold<int>(
            0,
            (acc, item) => acc + (item.size ?? 0),
          );
        } on MinioS3Error {
          // The upload cannot be inspected any more - it expired, it was
          // completed elsewhere, or the server still lists an upload whose
          // bucket it has already deleted. One unreadable upload must not
          // fail the whole listing, so it is reported without a size.
          size = null;
        }
        yield IncompleteUpload(upload: upload, size: size);
      }
      keyMarker = result.nextKeyMarker;
      uploadIdMarker = result.nextUploadIdMarker;
      isTruncated = result.isTruncated!;
    } while (isTruncated);
  }

  /// Called by listIncompleteUploads to fetch a batch of incomplete uploads.
  Future<ListMultipartUploadsOutput> listIncompleteUploadsQuery(
    String bucket,
    String prefix,
    String? keyMarker,
    String? uploadIdMarker,
    String delimiter,
  ) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidPrefixError.check(prefix);

    // The `uploads` sub-resource is already added by the `resource` argument
    // below. Listing it here as well sent the parameter twice
    // (`?uploads&uploads&...`), and the signature - which is computed from
    // the parsed query, where a repeated key collapses to one - no longer
    // matched what the server signed, so every call failed with
    // "The request signature we calculated does not match the signature you
    // provided".
    var queries = <String, dynamic>{'prefix': prefix, 'delimiter': delimiter};

    if (keyMarker != null) {
      queries['key-marker'] = keyMarker;
    }
    if (uploadIdMarker != null) {
      queries['upload-id-marker'] = uploadIdMarker;
    }

    final resp = await _client.request(
      method: 'GET',
      bucket: bucket,
      resource: 'uploads',
      queries: queries,
    );

    validate(resp);

    final node = xml.XmlDocument.parse(resp.body);
    return ListMultipartUploadsOutput.fromXml(node.rootElement);
  }

  /// Listen for notifications on a bucket. Additionally one can provider
  /// filters for prefix, suffix and events. There is no prior set bucket notification
  /// needed to use this API. **This is an MinIO extension API** where unique identifiers
  /// are regitered and unregistered by the server automatically based on incoming requests.
  NotificationPoller listenBucketNotification(
    String bucket, {
    String? prefix,
    String? suffix,
    List<String>? events,
  }) {
    MinioInvalidBucketNameError.check(bucket);

    final poller = NotificationPoller(_client, bucket, prefix, suffix, events);

    poller.start();

    return poller;
  }

  /// List of buckets created.
  Future<List<Bucket>> listBuckets() async {
    final resp = await _client.request(
      method: 'GET',
      region: region ?? 'us-east-1',
    );
    validate(resp);
    final bucketsNode = xml.XmlDocument.parse(
      resp.body,
    ).findAllElements('Buckets').first;
    // The children of <Buckets> are not guaranteed to be elements: a server
    // that indents its XML puts whitespace text nodes between them, and
    // casting those to XmlElement threw (upstream issue #49).
    return bucketsNode.children
        .whereType<XmlElement>()
        .map(Bucket.fromXml)
        .toList();
  }

  /// Returns all [Object]s in a bucket.
  /// To list objects in a bucket with prefix, set [prefix] to the desired prefix.
  Stream<ListObjectsResult> listObjects(
    String bucket, {
    String prefix = '',
    bool recursive = false,
  }) async* {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidPrefixError.check(prefix);
    final delimiter = recursive ? '' : '/';

    String? marker;
    var isTruncated = false;

    do {
      final resp = await listObjectsQuery(
        bucket,
        prefix,
        marker,
        delimiter,
        1000,
      );
      isTruncated = resp.isTruncated!;
      marker = resp.nextMarker;
      yield ListObjectsResult(
        objects: resp.contents!,
        prefixes: resp.commonPrefixes.map((e) => e.prefix!).toList(),
      );
    } while (isTruncated);
  }

  /// Returns all [Object]s in a bucket. This is a shortcut for [listObjects].
  /// Use [listObjects] to list buckets with a large number of objects.
  Future<ListObjectsResult> listAllObjects(
    String bucket, {
    String prefix = '',
    bool recursive = false,
  }) async {
    final chunks = listObjects(bucket, prefix: prefix, recursive: recursive);
    final objects = <Object>[];
    final prefixes = <String>[];
    await for (final chunk in chunks) {
      objects.addAll(chunk.objects);
      prefixes.addAll(chunk.prefixes);
    }
    return ListObjectsResult(objects: objects, prefixes: prefixes);
  }

  /// list a batch of objects
  Future<ListObjectsOutput> listObjectsQuery(
    String bucket,
    String prefix,
    String? marker,
    String delimiter,
    int? maxKeys,
  ) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidPrefixError.check(prefix);

    final queries = <String, dynamic>{};
    queries['prefix'] = prefix;
    queries['delimiter'] = delimiter;

    if (marker != null) {
      queries['marker'] = marker;
    }

    if (maxKeys != null) {
      maxKeys = maxKeys >= 1000 ? 1000 : maxKeys;
      queries['max-keys'] = maxKeys.toString();
    }

    final resp = await _client.request(
      method: 'GET',
      bucket: bucket,
      queries: queries,
    );

    validate(resp);

    final node = xml.XmlDocument.parse(resp.body);
    final isTruncated = getNodeProp(node.rootElement, 'IsTruncated')!.text;
    final nextMarker = getNodeProp(node.rootElement, 'NextMarker')?.text;
    final objs = node.findAllElements('Contents').map((c) => Object.fromXml(c));
    final prefixes = node
        .findAllElements('CommonPrefixes')
        .map((c) => CommonPrefix.fromXml(c));

    return ListObjectsOutput()
      ..contents = objs.toList()
      ..commonPrefixes = prefixes.toList()
      ..isTruncated = isTruncated.toLowerCase() == 'true'
      ..nextMarker = nextMarker;
  }

  /// Returns all [Object]s in a bucket.
  /// To list objects in a bucket with prefix, set [prefix] to the desired prefix.
  /// This uses ListObjectsV2 in the S3 API. For backward compatibility, use
  /// [listObjects] instead.
  Stream<ListObjectsResult> listObjectsV2(
    String bucket, {
    String prefix = '',
    bool recursive = false,
    String? startAfter,
  }) async* {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidPrefixError.check(prefix);
    final delimiter = recursive ? '' : '/';

    bool? isTruncated = false;
    String? continuationToken;

    do {
      final resp = await listObjectsV2Query(
        bucket,
        prefix,
        continuationToken,
        delimiter,
        1000,
        startAfter,
      );
      isTruncated = resp.isTruncated;
      continuationToken = resp.nextContinuationToken;
      yield ListObjectsResult(
        objects: resp.contents!,
        prefixes: resp.commonPrefixes.map((e) => e.prefix!).toList(),
      );
    } while (isTruncated!);
  }

  /// Returns all [Object]s in a bucket. This is a shortcut for [listObjectsV2].
  /// Use [listObjects] to list buckets with a large number of objects.
  /// This uses ListObjectsV2 in the S3 API. For backward compatibility, use
  /// [listAllObjects] instead.
  Future<ListObjectsResult> listAllObjectsV2(
    String bucket, {
    String prefix = '',
    bool recursive = false,
  }) async {
    final chunks = listObjects(bucket, prefix: prefix, recursive: recursive);
    final objects = <Object>[];
    final prefixes = <String>[];
    await for (final chunk in chunks) {
      objects.addAll(chunk.objects);
      prefixes.addAll(chunk.prefixes);
    }
    return ListObjectsResult(objects: objects, prefixes: prefixes);
  }

  /// listObjectsV2Query - (List Objects V2) - List some or all (up to 1000) of the objects in a bucket.
  Future<ListObjectsV2Output> listObjectsV2Query(
    String bucket,
    String prefix,
    String? continuationToken,
    String delimiter,
    int? maxKeys,
    String? startAfter,
  ) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidPrefixError.check(prefix);

    final queries = <String, dynamic>{};
    queries['prefix'] = prefix;
    queries['delimiter'] = delimiter;
    queries['list-type'] = '2';

    if (continuationToken != null) {
      queries['continuation-token'] = continuationToken;
    }

    if (startAfter != null) {
      queries['start-after'] = startAfter;
    }

    if (maxKeys != null) {
      maxKeys = maxKeys >= 1000 ? 1000 : maxKeys;
      queries['max-keys'] = maxKeys.toString();
    }

    final resp = await _client.request(
      method: 'GET',
      bucket: bucket,
      queries: queries,
    );

    validate(resp);

    final node = xml.XmlDocument.parse(resp.body);
    final isTruncated = getNodeProp(node.rootElement, 'IsTruncated')!.text;
    final nextContinuationToken = getNodeProp(
      node.rootElement,
      'NextContinuationToken',
    )?.text;
    final objs = node.findAllElements('Contents').map((c) => Object.fromXml(c));
    final prefixes = node
        .findAllElements('CommonPrefixes')
        .map((c) => CommonPrefix.fromXml(c));

    return ListObjectsV2Output()
      ..contents = objs.toList()
      ..commonPrefixes = prefixes.toList()
      ..isTruncated = isTruncated.toLowerCase() == 'true'
      ..nextContinuationToken = nextContinuationToken;
  }

  /// Get part-info of all parts of an incomplete upload specified by uploadId.
  Stream<Part> listParts(String bucket, String object, String uploadId) async* {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    var marker = 0;
    var isTruncated = false;
    do {
      final result = await listPartsQuery(bucket, object, uploadId, marker);
      marker = result.nextPartNumberMarker;
      isTruncated = result.isTruncated;
      yield* Stream.fromIterable(result.parts);
    } while (isTruncated);
  }

  /// Called by listParts to fetch a batch of part-info
  Future<ListPartsOutput> listPartsQuery(
    String? bucket,
    String? object,
    String? uploadId,
    int? marker,
  ) async {
    var queries = <String, dynamic>{'uploadId': uploadId};

    if (marker != null && marker != 0) {
      queries['part-number-marker'] = marker.toString();
    }

    final resp = await _client.request(
      method: 'GET',
      bucket: bucket,
      object: object,
      queries: queries,
    );

    validate(resp);

    final node = xml.XmlDocument.parse(resp.body);
    return ListPartsOutput.fromXml(node.rootElement);
  }

  /// Creates the bucket [bucket].
  Future<void> makeBucket(String bucket, [String? region]) async {
    MinioInvalidBucketNameError.check(bucket);
    if (this.region != null && region != null && this.region != region) {
      throw MinioInvalidArgumentError(
        'Configured region ${this.region}, requested $region',
      );
    }

    region ??= this.region ?? 'us-east-1';
    final payload = region == 'us-east-1'
        ? ''
        : CreateBucketConfiguration(region).toXml().toString();

    final resp = await _client.request(
      method: 'PUT',
      bucket: bucket,
      region: region,
      payload: payload,
    );

    validate(resp);
    // return resp.body;
  }

  /// Generate a presigned URL for GET
  ///
  /// - [bucketName]: name of the bucket
  /// - [objectName]: name of the object
  /// - [expires]: expiry in seconds (optional, default 7 days)
  /// - [respHeaders]: response headers to override (optional)
  /// - [requestDate]: A date object, the url will be issued at (optional)
  /// - [host], [port], [useSSL]: the public address of the server, when it
  ///   differs from the one the client talks to (optional)
  Future<String> presignedGetObject(
    String bucket,
    String object, {
    int? expires,
    Map<String, String>? respHeaders,
    DateTime? requestDate,
    String? host,
    int? port,
    bool? useSSL,
  }) {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    return presignedUrl(
      'GET',
      bucket,
      object,
      expires: expires,
      reqParams: respHeaders,
      requestDate: requestDate,
      host: host,
      port: port,
      useSSL: useSSL,
    );
  }

  /// presignedPostPolicy can be used in situations where we want more control on the upload than what
  /// presignedPutObject() provides. i.e Using presignedPostPolicy we will be able to put policy restrictions
  /// on the object's `name` `bucket` `expiry` `Content-Type`
  ///
  /// - [host], [port], [useSSL]: the public address of the server, when it
  ///   differs from the one the client talks to (optional). The override is
  ///   used both in the url and in the signature (upstream issue #101).
  Future<PostPolicyResult> presignedPostPolicy(
    PostPolicy postPolicy, {
    String? host,
    int? port,
    bool? useSSL,
  }) async {
    if (_client.anonymous) {
      throw MinioAnonymousRequestError(
        'Presigned POST policy cannot be generated for anonymous requests',
      );
    }

    // The policy is signed with the credentials the client signs with, so
    // they have to be resolved before it is built (upstream issue #94).
    await resolveCredentials();

    final region = await getBucketRegion(postPolicy.formData['bucket']!);
    var date = DateTime.now().toUtc();
    var dateStr = makeDateLong(date);
    if (postPolicy.policy['expiration'] == null) {
      // 'expiration' is mandatory field for S3.
      // Set default expiration date of 7 days.
      var expires = DateTime.now().toUtc();
      expires.add(const Duration(days: 7));
      postPolicy.setExpires(expires);
    }

    postPolicy.policy['conditions'].add(['eq', r'$x-amz-date', dateStr]);
    postPolicy.formData['x-amz-date'] = dateStr;

    postPolicy.policy['conditions'].add([
      'eq',
      r'$x-amz-algorithm',
      'AWS4-HMAC-SHA256',
    ]);
    postPolicy.formData['x-amz-algorithm'] = 'AWS4-HMAC-SHA256';

    postPolicy.policy['conditions'].add([
      'eq',
      r'$x-amz-credential',
      '$accessKey/${getScope(region, date)}',
    ]);

    postPolicy.formData['x-amz-credential'] =
        '$accessKey/${getScope(region, date)}';

    if (sessionToken != null) {
      postPolicy.policy['conditions'].add([
        'eq',
        r'$x-amz-security-token',
        sessionToken,
      ]);
    }

    final policyBase64 = jsonBase64(postPolicy.policy);
    postPolicy.formData['policy'] = policyBase64;

    final signature = postPresignSignatureV4(
      region,
      date,
      secretKey,
      policyBase64,
    );

    postPolicy.formData['x-amz-signature'] = signature;
    final url = _client
        .getBaseRequest(
          'POST',
          postPolicy.formData['bucket'],
          null,
          region,
          null,
          null,
          null,
          null,
          host: host,
          port: port,
          useSSL: useSSL,
        )
        .url;
    final effectivePort = port ?? this.port;
    var portStr = (effectivePort == 80 || effectivePort == 443)
        ? ''
        : ':$effectivePort';
    var urlStr = '${url.scheme}://${url.host}$portStr${url.path}';
    return PostPolicyResult(postURL: urlStr, formData: postPolicy.formData);
  }

  /// Generate a presigned URL for PUT.
  /// Using this URL, the browser can upload to S3 only with the specified object name.
  ///
  /// - [bucketName]: name of the bucket
  /// - [objectName]: name of the object
  /// - [expires]: expiry in seconds (optional, default 7 days)
  /// - [host], [port], [useSSL]: the public address of the server, when it
  ///   differs from the one the client talks to (optional)
  Future<String> presignedPutObject(
    String bucket,
    String object, {
    int? expires,
    String? host,
    int? port,
    bool? useSSL,
  }) {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);
    return presignedUrl(
      'PUT',
      bucket,
      object,
      expires: expires,
      host: host,
      port: port,
      useSSL: useSSL,
    );
  }

  /// The URL of an object.
  ///
  /// The URL is not signed: it points at the object and can be used by
  /// everyone who may read the bucket. Use [presignedGetObject] for a URL
  /// that carries a signature (upstream issue #12).
  Future<String> objectUrl(String bucket, String object) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    final region = await getBucketRegion(bucket);
    final url = _client.getRequestUrl(
      bucket,
      object,
      null,
      null,
      region: region,
    );
    return url.toString();
  }

  /// Generate a generic presigned URL which can be
  /// used for HTTP methods GET, PUT, HEAD and DELETE
  ///
  /// - [method]: name of the HTTP method
  /// - [bucketName]: name of the bucket
  /// - [objectName]: name of the object
  /// - [expires]: expiry in seconds (optional, default 7 days)
  /// - [reqParams]: request parameters (optional)
  /// - [requestDate]: A date object, the url will be issued at (optional)
  /// - [host], [port], [useSSL]: the public address of the server, when it
  ///   differs from the one the client talks to (optional). The override is
  ///   used both in the url and in the signature, so the two can never
  ///   disagree (upstream issue #101).
  Future<String> presignedUrl(
    String method,
    String bucket,
    String object, {
    int? expires,
    String? resource,
    Map<String, String>? reqParams,
    DateTime? requestDate,
    String? host,
    int? port,
    bool? useSSL,
  }) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    if (expires != null && expires < 0) {
      throw MinioInvalidArgumentError('invalid expire time value: $expires');
    }

    expires ??= expires = 24 * 60 * 60 * 7; // 7 days in seconds
    reqParams ??= {};
    requestDate ??= DateTime.now().toUtc();

    // The signature is built from the credentials the client signs with, so
    // they have to be resolved before it is computed (upstream issue #94).
    await resolveCredentials();

    final region = await getBucketRegion(bucket);
    final request = _client.getBaseRequest(
      method,
      bucket,
      object,
      region,
      resource,
      reqParams,
      {},
      null,
      host: host,
      port: port,
      useSSL: useSSL,
    );
    return presignSignatureV4(this, request, region, requestDate, expires);
  }

  /// Uploads the object. Returns the ETag of the uploaded object.
  ///
  /// [maxParallelUploads] is how many parts of a multipart upload may be in
  /// flight at the same time. The default of 1 uploads the parts one after
  /// the other, like the upstream client does; a higher value is faster on a
  /// high latency link (upstream issue #98).
  Future<String> putObject(
    String bucket,
    String object,
    Stream<Uint8List> data, {
    int? size,
    int? chunkSize,
    Map<String, String>? metadata,
    void Function(int)? onProgress,
    int maxParallelUploads = 1,
  }) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    if (size != null && size < 0) {
      throw MinioInvalidArgumentError('invalid size value: $size');
    }

    if (chunkSize != null && chunkSize < 5 * 1024 * 1024) {
      throw MinioInvalidArgumentError('Minimum chunk size is 5MB');
    }

    if (maxParallelUploads < 1) {
      throw MinioInvalidArgumentError(
        'invalid maxParallelUploads value: $maxParallelUploads',
      );
    }

    metadata = prependXAMZMeta(metadata ?? <String, String>{});

    final partSize = chunkSize ?? _calculatePartSize(size ?? maxObjectSize);

    final uploader = MinioUploader(
      this,
      _client,
      bucket,
      object,
      partSize,
      metadata,
      onProgress,
      maxParallelUploads: maxParallelUploads,
    );
    final chunker = MinChunkSize(partSize);
    final etag = await data.transform(chunker).pipe(uploader);
    return etag.toString();
  }

  /// Uploads a single part of a multipart upload.
  ///
  /// The upload must have been started with [initiateNewMultipartUpload]; the
  /// parts are finished with [completeMultipartUpload]. This is the API an
  /// application needs when it drives the multipart upload itself, for
  /// example to upload the parts in parallel (upstream issue #102).
  ///
  /// Returns the ETag of the part.
  Future<String> uploadPart(
    String bucket,
    String object,
    String uploadId,
    int partNumber,
    List<int> data,
  ) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    if (partNumber < 1 || partNumber > 10000) {
      throw MinioInvalidArgumentError('invalid partNumber value: $partNumber');
    }

    final headers = <String, String>{'Content-Length': '${data.length}'};
    if (!_client.enableSHA256) {
      headers['Content-MD5'] = base64.encode(md5.convert(data).bytes);
    }

    final resp = await _client.request(
      method: 'PUT',
      bucket: bucket,
      object: object,
      headers: headers,
      queries: {'partNumber': '$partNumber', 'uploadId': uploadId},
      // The request only carries a `Uint8List`, so a plain list of bytes is
      // copied into one instead of being rejected.
      payload: Uint8List.fromList(data),
    );

    validate(resp);

    final etag = resp.headers['etag'];
    return etag == null ? '' : trimDoubleQuote(etag);
  }

  /// Remove all bucket notification
  Future<void> removeAllBucketNotification(String bucket) async {
    await setBucketNotification(
      bucket,
      NotificationConfiguration(null, null, null),
    );
  }

  /// Remove a bucket.
  Future<void> removeBucket(String bucket) async {
    MinioInvalidBucketNameError.check(bucket);

    final resp = await _client.request(method: 'DELETE', bucket: bucket);

    validate(resp, expect: 204);
    _regionMap.remove(bucket);
  }

  /// Remove the partially uploaded object.
  Future<void> removeIncompleteUpload(String bucket, String object) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    final uploadId = await findUploadId(bucket, object);
    if (uploadId == null) return;

    final resp = await _client.request(
      method: 'DELETE',
      bucket: bucket,
      object: object,
      queries: {'uploadId': uploadId},
    );

    validate(resp, expect: 204);
  }

  /// Remove the specified object.
  Future<void> removeObject(String bucket, String object) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    final resp = await _client.request(
      method: 'DELETE',
      bucket: bucket,
      object: object,
    );

    validate(resp, expect: 204);
  }

  /// Remove all the objects residing in the objectsList.
  Future<void> removeObjects(String bucket, List<String> objects) async {
    MinioInvalidBucketNameError.check(bucket);

    final bunches = groupList(objects, 1000);

    for (var bunch in bunches) {
      final payload = Delete(
        bunch.map((key) => ObjectIdentifier(key, null)).toList(),
        true,
      ).toXml().toString();

      final headers = {'Content-MD5': md5Base64(payload)};

      await _client.request(
        method: 'POST',
        bucket: bucket,
        resource: 'delete',
        headers: headers,
        payload: payload,
      );
    }
  }

  /// Removes every object whose name starts with [prefix].
  ///
  /// This is how a "folder" is deleted on a server that has no folders: the
  /// objects under the prefix are removed (upstream issue #99).
  Future<void> removeObjectsByPrefix(String bucket, String prefix) async {
    MinioInvalidBucketNameError.check(bucket);

    final objects = <String>[];
    await for (final chunk in listObjects(
      bucket,
      prefix: prefix,
      recursive: true,
    )) {
      for (final object in chunk.objects) {
        final key = object.key;
        if (key != null) objects.add(key);
      }
    }

    if (objects.isEmpty) return;

    await removeObjects(bucket, objects);
  }

  // Remove all the notification configurations in the S3 provider
  Future<void> setBucketNotification(
    String bucket,
    NotificationConfiguration config,
  ) async {
    MinioInvalidBucketNameError.check(bucket);

    final resp = await _client.request(
      method: 'PUT',
      bucket: bucket,
      resource: 'notification',
      payload: config.toXml().toString(),
    );

    validate(resp, expect: 200);
  }

  /// Set the bucket policy on the specified bucket.
  ///
  /// [policy] is detailed [here](https://docs.aws.amazon.com/AmazonS3/latest/dev/example-bucket-policies.html).
  Future<void> setBucketPolicy(
    String bucket, [
    Map<String, dynamic>? policy,
  ]) async {
    MinioInvalidBucketNameError.check(bucket);

    final method = policy != null ? 'PUT' : 'DELETE';
    final payload = policy != null ? json.encode(policy) : '';

    final resp = await _client.request(
      method: method,
      bucket: bucket,
      resource: 'policy',
      payload: payload,
    );

    validate(resp, expect: 204);
  }

  Future<void> setObjectACL(String bucket, String object, String policy) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    await _client.request(
      method: 'PUT',
      bucket: bucket,
      object: object,
      queries: {'acl': policy},
    );
  }

  Future<AccessControlPolicy> getObjectACL(String bucket, String object) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    final resp = await _client.request(
      method: 'GET',
      bucket: bucket,
      object: object,
      queries: {'acl': ''},
    );

    validate(resp, expect: 200);

    return AccessControlPolicy.fromXml(
      xml.XmlDocument.parse(
        resp.body,
      ).findElements('AccessControlPolicy').first,
    );
  }

  /// Stat information of the object.
  Future<StatObjectResult> statObject(
    String bucket,
    String object, {
    bool retrieveAcls = true,
  }) async {
    MinioInvalidBucketNameError.check(bucket);
    MinioInvalidObjectNameError.check(object);

    final resp = await _client.request(
      method: 'HEAD',
      bucket: bucket,
      object: object,
    );

    validate(resp, expect: 200);

    var etag = resp.headers['etag'];
    if (etag != null) {
      etag = trimDoubleQuote(etag);
    }

    // A HEAD response does not have to carry every header: some S3
    // implementations answer without a content-length, and a missing
    // last-modified is equally possible. Reading them with a bang operator
    // turned both into a "Null check operator used on a null value" crash
    // (upstream issue #108) - the fields are nullable, so the answer is too.
    final contentLength = resp.headers['content-length'];
    final lastModified = resp.headers['last-modified'];

    return StatObjectResult(
      etag: etag,
      size: contentLength == null ? null : int.tryParse(contentLength),
      metaData: extractMetadata(resp.headers),
      lastModified: lastModified == null
          ? null
          : parseRfc7231Time(lastModified),
      acl: retrieveAcls ? await getObjectACL(bucket, object) : null,
    );
  }
}
