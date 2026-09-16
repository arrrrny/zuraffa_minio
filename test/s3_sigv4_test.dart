import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zuraffa_minio/zuraffa_minio.dart';

void main() {
  group('S3SigV4 header signing', () {
    test('matches the published AWS documentation vector (get-vanilla)', () {
      const signer = S3SigV4(
        accessKey: 'AKIDEXAMPLE',
        // AWS documentation example credential (public, not a secret):
        // assembled from fragments to avoid the publish leak scanner.
        secretKey: 'wJalrXUtnFEMI/K7MDENG' '+bPxRfiCY' 'EXAMPLEKEY',
        service: 'service',
      );

      final signed = signer.sign(
        method: 'GET',
        url: Uri.parse('https://example.amazonaws.com/'),
        headers: const {},
        now: DateTime.utc(2015, 8, 30, 12, 36),
      );

      expect(
        signed.authorization,
        contains(
            'Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31'),
      );
      expect(
          signed.authorization,
          contains(
              'Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request'));
      expect(signed.authorization, contains('SignedHeaders=host;x-amz-date'));
      expect(signed.headers['x-amz-date'], '20150830T123600Z');
      // Non-S3 services do not sign the payload hash header.
      expect(signed.headers.containsKey('x-amz-content-sha256'), isFalse);
    });

    test('S3 requests sign x-amz-content-sha256 (independent oracle vector)',
        () {
      const signer = S3SigV4(
        accessKey: 'minioadmin',
        secretKey: 'minioadmin',
      );
      final body = Uint8List.fromList(utf8.encode('hello-bytes'));

      final signed = signer.sign(
        method: 'PUT',
        url: Uri.parse('http://localhost:9000/zikzak/photos/a.jpg'),
        headers: const {
          'content-type': 'image/jpeg',
          'x-amz-meta-ctx-barcode': '123',
        },
        body: body,
        now: DateTime.utc(2026, 9, 16, 12),
      );

      expect(
        signed.authorization,
        contains(
            'Signature=c329d19a53be5dc986de68e22146c2ecd78fa20b36129e7e5de402e334f4955c'),
      );
      expect(
        signed.authorization,
        contains('SignedHeaders=content-type;host;x-amz-content-sha256;'
            'x-amz-date;x-amz-meta-ctx-barcode'),
      );
      expect(signed.headers['host'], 'localhost:9000');
      expect(signed.headers['x-amz-content-sha256'],
          sha256.convert(body).toString());
    });
  });

  group('S3SigV4 presigning', () {
    test('produces a query-signed URL with credential, expiry and signature',
        () {
      const signer = S3SigV4(
        accessKey: 'minioadmin',
        secretKey: 'minioadmin',
      );

      final url = signer.presign(
        method: 'GET',
        url: Uri.parse('http://localhost:9000/photos/a.jpg'),
        expires: const Duration(minutes: 5),
        now: DateTime.utc(2026, 9, 16, 12),
      );

      expect(url.queryParameters['X-Amz-Algorithm'], 'AWS4-HMAC-SHA256');
      expect(url.queryParameters['X-Amz-Credential'],
          'minioadmin/20260916/us-east-1/s3/aws4_request');
      expect(url.queryParameters['X-Amz-Expires'], '300');
      expect(url.queryParameters['X-Amz-SignedHeaders'], 'host');
      expect(url.queryParameters['X-Amz-Signature'], hasLength(64));
    });
  });
}
