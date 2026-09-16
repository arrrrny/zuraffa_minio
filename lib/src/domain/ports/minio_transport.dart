import 'dart:typed_data';

/// An HTTP request as the MinIO client emits it (post-signing).
class MinioRequest {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final Uint8List body;

  MinioRequest({
    required this.method,
    required this.url,
    this.headers = const {},
    Uint8List? body,
  }) : body = body ?? Uint8List(0);
}

/// An HTTP response as the transport delivers it.
class MinioResponse {
  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;

  MinioResponse({
    required this.statusCode,
    this.headers = const {},
    Uint8List? body,
  }) : body = body ?? Uint8List(0);
}

/// The transport seam: real I/O in `IoMinioTransport`, scripted fakes in
/// tests. The MinIO client signs requests and hands them here.
abstract class MinioTransport {
  Future<MinioResponse> send(MinioRequest request);
  void close() {}
}
