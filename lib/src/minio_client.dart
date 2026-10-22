import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart';
import 'package:zuraffa_minio/minio.dart';
import 'package:zuraffa_minio/src/minio_helpers.dart';
import 'package:zuraffa_minio/src/minio_s3.dart';
import 'package:zuraffa_minio/src/minio_sign.dart';
import 'package:zuraffa_minio/src/utils.dart';

class MinioRequest extends StreamedRequest {
  MinioRequest(super.method, super.url, {this.onProgress});

  dynamic body;

  final void Function(int)? onProgress;

  @override
  ByteStream finalize() {
    super.finalize();

    if (body == null) {
      return const ByteStream(Stream.empty());
    }

    late Stream<Uint8List> stream;

    if (body is Stream<Uint8List>) {
      stream = body;
    } else if (body is String) {
      final data = const Utf8Encoder().convert(body);
      headers['content-length'] = data.length.toString();
      stream = Stream<Uint8List>.value(data);
    } else if (body is Uint8List) {
      stream = Stream<Uint8List>.value(body);
      headers['content-length'] = body.length.toString();
    } else {
      throw UnsupportedError('Unsupported body type: ${body.runtimeType}');
    }

    if (onProgress == null) {
      return ByteStream(stream);
    }

    var bytesRead = 0;

    stream = stream.transform(MaxChunkSize(1 << 16));

    return ByteStream(
      stream.transform(
        StreamTransformer.fromHandlers(
          handleData: (data, sink) {
            sink.add(data);
            bytesRead += data.length;
            onProgress!(bytesRead);
          },
        ),
      ),
    );
  }

  MinioRequest replace({
    String? method,
    Uri? url,
    Map<String, String>? headers,
    body,
  }) {
    final result = MinioRequest(method ?? this.method, url ?? this.url);
    result.body = body ?? this.body;
    result.headers.addAll(headers ?? this.headers);
    return result;
  }
}

/// An HTTP response where the entire response body is known in advance.
class MinioResponse extends BaseResponse {
  /// Create a new HTTP response with a byte array body.
  MinioResponse.bytes(
    this.bodyBytes,
    super.statusCode, {
    super.request,
    super.headers,
    super.isRedirect,
    super.persistentConnection,
    super.reasonPhrase,
  }) : super(contentLength: bodyBytes.length);

  /// The bytes comprising the body of this response.
  final Uint8List bodyBytes;

  /// Body of s3 response is always encoded as UTF-8.
  String get body => utf8.decode(bodyBytes);

  static Future<MinioResponse> fromStream(StreamedResponse response) async {
    final body = await response.stream.toBytes();
    return MinioResponse.bytes(
      body,
      response.statusCode,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }
}

class MinioClient {
  MinioClient(this.minio) {
    // A client with a credentials provider signs with the credentials the
    // provider resolves, so it is never anonymous — even before the first
    // resolution (upstream issue #94).
    anonymous =
        minio.credentialsProvider == null &&
        minio.accessKey.isEmpty &&
        minio.secretKey.isEmpty;
    enableSHA256 = !anonymous && !minio.useSSL;
    port = minio.port;
  }

  final Minio minio;
  final String userAgent = 'MinIO (Unknown; Unknown) minio-dart/2.0.0';

  late bool enableSHA256;
  late bool anonymous;
  late final int port;

  Future<({StreamedResponse response, String region})> _request({
    required String method,
    String? bucket,
    String? object,
    String? region,
    String? resource,
    dynamic payload = '',
    Map<String, dynamic>? queries,
    Map<String, String>? headers,
    void Function(int)? onProgress,
  }) async {
    // A cancelled token stops the request before it is even signed: no
    // credentials are resolved and nothing leaves the process
    // (upstream issues #85, #45, #93).
    minio.throwIfCancelled();

    // Temporary credentials from a credentialsProvider must be fresh
    // before they are read for signing (upstream issue #94).
    await minio.resolveCredentials();

    if (bucket != null) {
      region ??= await minio.getBucketRegion(bucket);
    }

    // The configured region is the default signing region, so a request
    // without a bucket is signed for the same region the host is built from.
    region ??= minio.region ?? 'us-east-1';

    final request = getBaseRequest(
      method,
      bucket,
      object,
      region,
      resource,
      queries,
      headers,
      onProgress,
    );
    request.body = payload;

    final date = DateTime.now().toUtc();
    final sha256sum = enableSHA256 ? sha256Hex(payload) : 'UNSIGNED-PAYLOAD';
    request.headers.addAll({
      'user-agent': userAgent,
      'x-amz-date': makeDateLong(date),
      'x-amz-content-sha256': sha256sum,
    });

    if (minio.sessionToken != null) {
      request.headers['x-amz-security-token'] = minio.sessionToken!;
    }

    final authorization = signV4(minio, request, date, region);
    request.headers['authorization'] = authorization;
    logRequest(request);
    final response = await minio.httpClient.send(request);
    return (response: response, region: region);
  }

  Future<MinioResponse> request({
    required String method,
    String? bucket,
    String? object,
    String? region,
    String? resource,
    dynamic payload = '',
    Map<String, dynamic>? queries,
    Map<String, String>? headers,
    void Function(int)? onProgress,
  }) async {
    final first = await _request(
      method: method,
      bucket: bucket,
      object: object,
      region: region,
      payload: payload,
      resource: resource,
      queries: queries,
      headers: headers,
      onProgress: onProgress,
    );

    var response = await MinioResponse.fromStream(first.response);
    logResponse(response);

    // The server may tell us that the region we signed for is not the region
    // the bucket lives in:
    //
    //   The authorization header is malformed; the region is wrong;
    //   expecting 'us-east-1'.
    //
    // (upstream issue #38). Sign and address the request again with the
    // region the server named, once, and remember it for the bucket.
    final correctRegion = _regionFromError(response);
    if (correctRegion != null && correctRegion != first.region) {
      if (bucket != null) minio.cacheRegion(bucket, correctRegion);
      final retry = await _request(
        method: method,
        bucket: bucket,
        object: object,
        region: correctRegion,
        payload: payload,
        resource: resource,
        queries: queries,
        headers: headers,
        onProgress: onProgress,
      );
      response = await MinioResponse.fromStream(retry.response);
      logResponse(response);
    }

    return response;
  }

  /// The region an `AuthorizationHeaderMalformed` error asks for, if any.
  String? _regionFromError(MinioResponse response) {
    if (response.statusCode != 400) return null;
    final body = response.body;
    if (!body.contains('AuthorizationHeaderMalformed')) return null;
    final match = RegExp(r'<Region>([^<]+)</Region>').firstMatch(body);
    return match?.group(1)?.trim();
  }

  Future<StreamedResponse> requestStream({
    required String method,
    String? bucket,
    String? object,
    String? region,
    String? resource,
    dynamic payload = '',
    Map<String, dynamic>? queries,
    Map<String, String>? headers,
  }) async {
    final result = await _request(
      method: method,
      bucket: bucket,
      object: object,
      region: region,
      payload: payload,
      resource: resource,
      queries: queries,
      headers: headers,
    );

    logResponse(result.response);
    return result.response;
  }

  MinioRequest getBaseRequest(
    String method,
    String? bucket,
    String? object,
    String region,
    String? resource,
    Map<String, dynamic>? queries,
    Map<String, String>? headers,
    void Function(int)? onProgress, {
    String? host,
    int? port,
    bool? useSSL,
  }) {
    final url = getRequestUrl(
      bucket,
      object,
      resource,
      queries,
      region: region,
      host: host,
      port: port,
      useSSL: useSSL,
    );
    final request = MinioRequest(method, url, onProgress: onProgress);
    request.headers['host'] = url.authority;

    if (headers != null) {
      request.headers.addAll(headers);
    }

    return request;
  }

  Uri getRequestUrl(
    String? bucket,
    String? object,
    String? resource,
    Map<String, dynamic>? queries, {
    String? region,
    String? host,
    int? port,
    bool? useSSL,
  }) {
    // A caller may presign for a different public host, port or scheme than
    // the client itself talks to — e.g. behind a proxy or CDN (upstream
    // issue #101). The overrides flow all the way into the URL, and
    // `getBaseRequest` derives the signed `host` header from that same URL,
    // so signature can never disagree with the address.
    final effectiveSSL = useSSL ?? minio.useSSL;
    // An explicit host override is the caller's decision and is never
    // rewritten: a caller that presigns for a public host gets exactly that
    // host, even when it names a global Amazon endpoint.
    final hasHostOverride = host != null;
    var hostName = (host ?? minio.endPoint).toLowerCase();
    final effectivePort = port ?? minio.port;
    var path = '/';

    // The effective region is the one the signature will claim. It decides
    // the AWS host as well, so host and signature can never disagree.
    //
    // Upstream read `minio.region!` here, which threw "Unexpected null value"
    // whenever an Amazon endpoint was used without an explicit region
    // (upstream issue #43).
    final effectiveRegion = region ?? minio.region ?? 'us-east-1';

    var pathStyle = minio.pathStyle ?? true;
    if (isAmazonEndpoint(hostName)) {
      if (!hasHostOverride && isGlobalAmazonEndpoint(hostName)) {
        // The global Amazon endpoint is the only one that is regionalized:
        // the region the request is signed for has to match the host it is
        // sent to. An explicit override is left alone.
        hostName = getS3Endpoint(effectiveRegion);
      }
      // The default stays the one upstream used: path style. Upstream tested
      // the endpoint after it had been regionalized, so its Amazon check
      // never matched and every Amazon request went out as
      // `https://s3-<region>.amazonaws.com/<bucket>/<key>`. The fork keeps
      // that layout, so a migration is an import swap and not a change of
      // the requests on the wire. Virtual host style is one setting away:
      // `pathStyle: false`.
      pathStyle = minio.pathStyle ?? true;
    }

    if (!pathStyle) {
      if (bucket != null) hostName = '$bucket.$hostName';
      if (object != null) path = '/$object';
    } else {
      if (bucket != null) path = '/$bucket';
      if (object != null) path = '/$bucket/$object';
    }

    final query = StringBuffer();
    if (resource != null) {
      query.write(resource);
    }
    if (queries != null) {
      if (query.isNotEmpty) query.write('&');
      query.write(encodeQueries(queries));
    }

    return Uri(
      scheme: effectiveSSL ? 'https' : 'http',
      host: hostName,
      port: effectivePort,
      pathSegments: path.split('/'),
      query: query.toString(),
    );
  }

  void logRequest(MinioRequest request) {
    if (!minio.enableTrace) return;

    final buffer = StringBuffer();
    buffer.writeln('REQUEST: ${request.method} ${request.url}');
    for (var header in request.headers.entries) {
      buffer.writeln('${header.key}: ${header.value}');
    }

    if (request.body is List<int>) {
      buffer.writeln('List<int> of size ${request.body.length}');
    } else {
      buffer.writeln(request.body);
    }

    print(buffer.toString());
  }

  void logResponse(BaseResponse response) {
    if (!minio.enableTrace) return;

    final buffer = StringBuffer();
    buffer.writeln('RESPONSE: ${response.statusCode} ${response.reasonPhrase}');
    for (var header in response.headers.entries) {
      buffer.writeln('${header.key}: ${header.value}');
    }

    if (response is Response) {
      buffer.writeln(response.body);
    } else if (response is StreamedResponse) {
      buffer.writeln('STREAMED BODY');
    }

    print(buffer.toString());
  }
}
