import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zuraffa_minio/zuraffa_minio.dart';

class FakeMinioTransport implements MinioTransport {
  final List<MinioRequest> requests = [];
  final List<MinioResponse> responses;

  FakeMinioTransport([List<MinioResponse>? responses])
      : responses = responses ?? [];

  @override
  Future<MinioResponse> send(MinioRequest request) async {
    requests.add(request);
    if (responses.isEmpty) {
      throw StateError('FakeMinioTransport has no scripted response left');
    }
    return responses.removeAt(0);
  }

  @override
  void close() {}
}

MinioResponse ok([Uint8List? body, Map<String, String> headers = const {}]) =>
    MinioResponse(statusCode: 200, headers: headers, body: body);

MinioResponse status(int code) => MinioResponse(statusCode: code);

void main() {
  late FakeMinioTransport transport;
  late MinioClient client;

  MinioClient build([List<MinioResponse>? responses]) {
    transport = FakeMinioTransport(responses);
    return MinioClient(
      endpoint: 'http://localhost:9000',
      accessKey: 'minioadmin',
      secretKey: 'minioadmin',
      transport: transport,
    );
  }

  group('bucket operations', () {
    test('bucketExists: 200 -> true, 404 -> false', () async {
      client = build([status(200), status(404)]);
      expect(await client.bucketExists('photos'), isTrue);
      expect(await client.bucketExists('photos'), isFalse);
      expect(transport.requests[0].method, 'HEAD');
      expect(transport.requests[0].url.path, '/photos');
    });

    test('ensureBucket creates only when missing', () async {
      client = build([status(404), status(200)]);
      expect(await client.ensureBucket('photos'), isTrue);
      expect(transport.requests.map((r) => r.method), ['HEAD', 'PUT']);

      client = build([status(200)]);
      expect(await client.ensureBucket('photos'), isTrue);
      expect(transport.requests.map((r) => r.method), ['HEAD']);
    });

    test('removeBucket: 204 -> true', () async {
      client = build([status(204)]);
      expect(await client.removeBucket('photos'), isTrue);
      expect(transport.requests.single.method, 'DELETE');
    });
  });

  group('object operations', () {
    test('putObjectBytes signs and ships headers + body', () async {
      client = build([ok()]);
      final bytes = Uint8List.fromList(utf8.encode('jpegdata'));

      final done = await client.putObjectBytes(
        bucket: 'photos',
        key: 'a.jpg',
        bytes: bytes,
        contentType: 'image/jpeg',
        metadata: {'ctx-barcode': '123'},
      );

      expect(done, isTrue);
      final req = transport.requests.single;
      expect(req.method, 'PUT');
      expect(req.url.toString(), 'http://localhost:9000/photos/a.jpg');
      expect(req.body, bytes);
      expect(req.headers['content-type'], 'image/jpeg');
      expect(req.headers['x-amz-meta-ctx-barcode'], '123');
      expect(req.headers['Authorization'],
          startsWith('AWS4-HMAC-SHA256 Credential=minioadmin/'));
      expect(req.headers['x-amz-content-sha256'],
          sha256Hex(bytes));
      expect(req.headers['x-amz-date'], isNotNull);
    });

    test('putObject failure surfaces a typed MinioException', () async {
      client = build([status(500)]);
      await expectLater(
        client.putObject(bucket: 'photos', key: 'a.txt', data: 'x'),
        throwsA(isA<MinioException>()
            .having((e) => e.code, 'code', 'put_object_500')),
      );
    });

    test('getObjectBytes: 404 -> null, 200 -> bytes', () async {
      client = build([status(404), ok(Uint8List.fromList([1, 2, 3]))]);
      expect(await client.getObjectBytes('photos', 'missing.jpg'), isNull);
      expect(await client.getObjectBytes('photos', 'a.jpg'), [1, 2, 3]);
    });

    test('deleteObject: 204 -> true', () async {
      client = build([status(204)]);
      expect(await client.deleteObject('photos', 'a.jpg'), isTrue);
    });

    test('statObject decodes size, etag and content type', () async {
      client = build([
        ok(null, {
          'content-length': '1234',
          'etag': '"abc123"',
          'content-type': 'image/jpeg',
        }),
      ]);
      final stat = await client.statObject('photos', 'a.jpg');
      expect(stat!.size, 1234);
      expect(stat.etag, 'abc123');
      expect(stat.contentType, 'image/jpeg');
    });

    test('listObjects parses the ListObjectsV2 XML (xml 7)', () async {
      const xmlBody = """<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>photos</Name>
  <IsTruncated>false</IsTruncated>
  <Contents>
    <Key>a.jpg</Key><LastModified>2026-09-16T12:00:00.000Z</LastModified>
    <ETag>"e1"</ETag><Size>10</Size>
  </Contents>
  <Contents>
    <Key>dir/b.jpg</Key><LastModified>2026-09-16T13:00:00.000Z</LastModified>
    <ETag>"e2"</ETag><Size>20</Size>
  </Contents>
</ListBucketResult>""";
      client = build([ok(Uint8List.fromList(utf8.encode(xmlBody)))]);

      final objects = await client.listObjects('photos', recursive: true);

      expect(objects, hasLength(2));
      expect(objects[0].key, 'a.jpg');
      expect(objects[0].size, 10);
      expect(objects[1].key, 'dir/b.jpg');
      expect(objects[1].etag, 'e2');
      expect(transport.requests.single.url.queryParameters['list-type'], '2');
      expect(
          transport.requests.single.url.queryParameters.containsKey('delimiter'),
          isFalse,
          reason: 'recursive listing omits the delimiter');
    });
  });

  group('presigned URLs', () {
    test('presignedGetObject returns a signed URL', () async {
      client = build();
      final url = client.presignedGetObject('photos', 'a.jpg');
      expect(url, contains('X-Amz-Signature='));
      expect(url, contains('X-Amz-Expires=900'));
    });
  });
}

String sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();
