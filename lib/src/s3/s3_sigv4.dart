import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A SigV4-signed request: the caller sends exactly these headers.
class SignedHeaders {
  /// Authorization header value (AWS4-HMAC-SHA256 Credential=..., ...).
  final String authorization;
  final Map<String, String> headers;

  const SignedHeaders({required this.authorization, required this.headers});
}

/// AWS Signature Version 4 signer (header signing + query presigning).
///
/// Implements the documented algorithm:
/// canonical request -> string to sign -> HMAC-SHA256 signing key chain.
/// The `get-vanilla` example from the AWS documentation is pinned in tests
/// (`test/s3_sigv4_test.dart`) with its published expected signature.
class S3SigV4 {
  static const _algorithm = 'AWS4-HMAC-SHA256';

  final String accessKey;
  final String secretKey;
  final String region;
  final String service;

  const S3SigV4({
    required this.accessKey,
    required this.secretKey,
    this.region = 'us-east-1',
    this.service = 's3',
  });

  /// Signs [method] [url] with [headers] and [body] for the given [now].
  ///
  /// Adds `x-amz-date`, `x-amz-content-sha256`, and `Authorization` to the
  /// returned header map (existing values are preserved).
  SignedHeaders sign({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    Uint8List? body,
    DateTime? now,
  }) {
    final ts = _amzDate(now ?? DateTime.now().toUtc());
    final date = ts.substring(0, 8);
    final payloadHash = _hex(sha256.convert(body ?? Uint8List(0)));

    final allHeaders = <String, String>{
      for (final e in headers.entries) e.key.toLowerCase().trim(): e.value.trim(),
      'host': url.hasPort ? '${url.host}:${url.port}' : url.host,
      'x-amz-date': ts,
    };
    // S3 requires the payload hash as a signed header; other services follow
    // the base SigV4 spec (and the AWS documentation vector signs host +
    // x-amz-date only).
    if (service == 's3' || allHeaders.containsKey('x-amz-content-sha256')) {
      allHeaders['x-amz-content-sha256'] = payloadHash;
    }

    final canonicalRequest = _canonicalRequest(
      method: method,
      url: url,
      headers: allHeaders,
      payloadHash: payloadHash,
    );
    final scope = '$date/$region/$service/aws4_request';
    final stringToSign = '$_algorithm\n$ts\n$scope\n'
        '${_hex(sha256.convert(utf8.encode(canonicalRequest)))}';
    final signature = _signature(stringToSign, date);

    final signedNames = (allHeaders.keys.toList()..sort()).join(';');
    return SignedHeaders(
      authorization: '$_algorithm Credential=$accessKey/$scope, '
          'SignedHeaders=$signedNames, Signature=$signature',
      headers: allHeaders,
    );
  }

  /// Builds a presigned [url] (query-string authentication) valid for
  /// [expires], for [method].
  Uri presign({
    required String method,
    required Uri url,
    Duration expires = const Duration(minutes: 15),
    DateTime? now,
  }) {
    final ts = _amzDate(now ?? DateTime.now().toUtc());
    final date = ts.substring(0, 8);
    final scope = '$date/$region/$service/aws4_request';
    final host = url.hasPort ? '${url.host}:${url.port}' : url.host;

    final query = <String, String>{
      for (final e in url.queryParameters.entries) e.key: e.value,
      'X-Amz-Algorithm': _algorithm,
      'X-Amz-Credential': '$accessKey/$scope',
      'X-Amz-Date': ts,
      'X-Amz-Expires': '${expires.inSeconds}',
      'X-Amz-SignedHeaders': 'host',
    };
    final canonicalQuery = _canonicalQuery(query);
    final canonicalRequest = '${method.toUpperCase()}\n'
        '${_canonicalPath(url)}\n'
        '$canonicalQuery\n'
        'host:$host\n\n'
        'host\n'
        'UNSIGNED-PAYLOAD';
    final stringToSign = '$_algorithm\n$ts\n$scope\n'
        '${_hex(sha256.convert(utf8.encode(canonicalRequest)))}';
    final signature = _signature(stringToSign, date);

    return url.replace(query: '$canonicalQuery&X-Amz-Signature=$signature');
  }

  // ── internals ──────────────────────────────────────────────────────────

  String _canonicalRequest({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required String payloadHash,
  }) {
    final names = headers.keys.toList()..sort();
    final canonicalHeaders =
        names.map((n) => '$n:${headers[n]}\n').join();
    return '${method.toUpperCase()}\n'
        '${_canonicalPath(url)}\n'
        '${_canonicalQuery(url.queryParameters)}\n'
        '$canonicalHeaders\n'
        '${names.join(';')}\n'
        '$payloadHash';
  }

  /// RFC3986-encodes each path segment once (S3-style; '/' preserved).
  String _canonicalPath(Uri url) {
    if (url.path.isEmpty) return '/';
    final encoded = Uri.encodeFull(url.path);
    return encoded.isEmpty ? '/' : encoded;
  }

  String _canonicalQuery(Map<String, String> params) {
    final keys = params.keys.toList()..sort();
    return keys
        .map((k) =>
            '${Uri.encodeQueryComponent(k).replaceAll('+', '%20')}='
            '${Uri.encodeQueryComponent(params[k]!).replaceAll('+', '%20')}')
        .join('&');
  }

  String _signature(String stringToSign, String date) {
    final kDate = _hmac(utf8.encode('AWS4$secretKey'), date);
    final kRegion = _hmac(kDate, region);
    final kService = _hmac(kRegion, service);
    final kSigning = _hmac(kService, 'aws4_request');
    return _hex(Hmac(sha256, kSigning).convert(utf8.encode(stringToSign)));
  }

  List<int> _hmac(List<int> key, String message) =>
      Hmac(sha256, key).convert(utf8.encode(message)).bytes;

  String _hex(digest) => digest.toString();

  String _amzDate(DateTime utc) =>
      '${utc.year.toString().padLeft(4, '0')}'
      '${utc.month.toString().padLeft(2, '0')}'
      '${utc.day.toString().padLeft(2, '0')}T'
      '${utc.hour.toString().padLeft(2, '0')}'
      '${utc.minute.toString().padLeft(2, '0')}'
      '${utc.second.toString().padLeft(2, '0')}Z';
}
