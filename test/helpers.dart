import 'dart:io';
import 'dart:math';

import 'package:test/test.dart' as pkg_test;
import 'package:zuraffa_minio/minio.dart';

/// The S3 server the integration tests talk to.
///
/// Upstream pointed the suite at the public `play.min.io` demo server, with
/// the shared demo credentials. That no longer works: MinIO's open-source
/// server is archived, the demo instance refuses writes with "Access denied.
/// No license is installed.", and the certificate does not even cover the
/// `play.minio.io` spelling upstream used, so every request failed the TLS
/// hostname check before it reached an assertion.
///
/// The suite therefore talks to a local server by default. Start one with:
///
/// ```sh
/// docker run -p 9000:9000 -p 9001:9001 \
///   -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
///   quay.io/minio/minio server /data
/// ```
///
/// and point the tests at it with the environment variables below.
class MinioTestServer {
  MinioTestServer._();

  /// The host the server listens on.
  static final String endpoint =
      Platform.environment['MINIO_ENDPOINT'] ?? '127.0.0.1';

  /// The port the server listens on.
  static final int port =
      int.tryParse(Platform.environment['MINIO_PORT'] ?? '') ?? 9000;

  /// Whether the server speaks TLS.
  static final bool useSSL =
      (Platform.environment['MINIO_USE_SSL'] ?? 'false').toLowerCase() ==
      'true';

  /// The access key to sign with.
  static final String accessKey =
      Platform.environment['MINIO_ACCESS_KEY'] ?? 'minioadmin';

  /// The secret key to sign with.
  static final String secretKey =
      Platform.environment['MINIO_SECRET_KEY'] ?? 'minioadmin';

  /// The region to sign for.
  static final String region =
      Platform.environment['MINIO_REGION'] ?? 'us-east-1';
}

/// Sentinel for "the caller did not pass a port".
///
/// It lets an explicit `port: null` keep its upstream meaning — "let [Minio]
/// imply 80 or 443 from the scheme" — while the default becomes the test
/// server's port.
class _Unset {
  const _Unset();
}

const _Unset _unset = _Unset();

/// Initializes an instance of [Minio] with per default valid configuration.
///
/// The defaults point at [MinioTestServer]; every value can be overridden
/// per call.
Minio getMinioClient({
  String? endpoint,
  Object? port = _unset,
  bool? useSSL,
  String? accessKey,
  String? secretKey,
  String? sessionToken,
  String? region,
  bool enableTrace = false,
}) => Minio(
  endPoint: endpoint ?? MinioTestServer.endpoint,
  port: identical(port, _unset) ? MinioTestServer.port : port as int?,
  useSSL: useSSL ?? MinioTestServer.useSSL,
  accessKey: accessKey ?? MinioTestServer.accessKey,
  secretKey: secretKey ?? MinioTestServer.secretKey,
  sessionToken: sessionToken ?? '',
  region: region ?? MinioTestServer.region,
  enableTrace: enableTrace,
);

/// Generates a random name for a bucket or object.
String uniqueName() {
  final random = Random();
  final now = DateTime.now();
  final name = 'id-${now.microsecondsSinceEpoch}-${random.nextInt(8192)}';
  return name;
}

/// Whether a reachable server answered the probe.
bool _serverAvailable = false;

/// Whether the integration tests can run against a live server.
///
/// Set by [detectMinioServer] before the tests are registered.
bool get minioServerAvailable => _serverAvailable;

/// Probes the configured server once, before the tests are registered.
///
/// The probe is a real signed request, so it fails exactly when the
/// credentials or the endpoint are wrong — which is what the integration
/// tests need to know.
Future<void> detectMinioServer() async {
  try {
    await getMinioClient().listBuckets().timeout(const Duration(seconds: 15));
    _serverAvailable = true;
  } catch (_) {
    _serverAvailable = false;
  }
}

/// The reason the integration tests are skipped when no server answers.
String get minioServerSkipReason =>
    'no S3 server at ${MinioTestServer.endpoint}:${MinioTestServer.port} — '
    'start one and set MINIO_ENDPOINT/MINIO_PORT, or MINIO_ACCESS_KEY and '
    'MINIO_SECRET_KEY for a remote server';

/// A [pkg_test.test] that skips itself when no S3 server is reachable.
void test(
  Object? description,
  dynamic Function() body, {
  Object? skip,
  Object? tags,
  pkg_test.Timeout? timeout,
}) {
  pkg_test.test(
    description,
    body,
    skip: _serverAvailable ? skip : minioServerSkipReason,
    tags: tags,
    timeout: timeout,
  );
}

/// A [pkg_test.setUpAll] that does nothing when no S3 server is reachable.
void setUpAll(dynamic Function() body) {
  pkg_test.setUpAll(() async {
    if (!_serverAvailable) return;
    await body();
  });
}

/// A [pkg_test.tearDownAll] that does nothing when no S3 server is
/// reachable.
void tearDownAll(dynamic Function() body) {
  pkg_test.tearDownAll(() async {
    if (!_serverAvailable) return;
    await body();
  });
}
