import 'dart:io';
import 'dart:typed_data';

import '../domain/ports/minio_transport.dart';

/// The single dart:io adapter: sends MinIO requests via [HttpClient].
class IoMinioTransport implements MinioTransport {
  final HttpClient _client;

  IoMinioTransport({HttpClient? client})
      : _client = client ?? HttpClient();

  @override
  Future<MinioResponse> send(MinioRequest request) async {
    final req = await _client.openUrl(request.method, request.url);
    request.headers.forEach(req.headers.set);
    if (request.body.isNotEmpty) {
      req.add(request.body);
    }
    final resp = await req.close();
    final bytes = await resp.fold<List<int>>(
        <int>[], (acc, chunk) => acc..addAll(chunk));
    return MinioResponse(
      statusCode: resp.statusCode,
      headers: {
        for (final name in ['etag', 'content-type', 'last-modified'])
          if (resp.headers.value(name) != null) name: resp.headers.value(name)!
      },
      body: Uint8List.fromList(bytes),
    );
  }

  @override
  void close() => _client.close(force: true);
}
