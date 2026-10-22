import 'dart:typed_data';

import 'package:zuraffa_minio/minio.dart';

/// Uploading from a browser.
///
/// On the web there is no `dart:io`, so there is no `File` and no file
/// system. The bytes come from the browser instead — from a file input, from
/// a drag and drop, or from a `fetch` — and they are handed to the client as
/// a `Stream<Uint8List>`.
///
/// This example shows the upload half of that. In a real application the
/// bytes are read with `package:web` (or `dart:html` on older Flutter
/// versions), for example:
///
/// ```dart
/// // The file picker of the browser, with package:web.
/// final input = document.querySelector('#file') as HTMLInputElement;
/// final file = input.files!.first;
/// final bytes = (await file.arrayBuffer().toDart).asUint8List();
/// ```
///
/// Two things to keep in mind on the web:
///
/// * the access key is signed **in the browser**, so everybody can read it.
///   Use a presigned URL for anything that matters.
/// * the bucket has to allow the origin of the page (CORS), otherwise the
///   browser rejects the request before it leaves the page.
///
/// The same code runs on the server, because the client itself is pure Dart
/// and web safe.
Future<void> main() async {
  final minio = Minio(
    endPoint: '127.0.0.1',
    port: 9000,
    accessKey: 'minioadmin',
    secretKey: 'minioadmin',
    useSSL: false,
  );

  const bucket = 'web-upload-example';
  const object = 'picture.png';

  if (!await minio.bucketExists(bucket)) {
    await minio.makeBucket(bucket);
  }

  // In the browser these bytes come from the file the user picked.
  final bytes = Uint8List.fromList(List<int>.filled(1024, 42));

  final etag = await minio.putObject(
    bucket,
    object,
    Stream<Uint8List>.value(bytes),
    size: bytes.length,
    metadata: {'Content-Type': 'image/png'},
    onProgress: (bytesWritten) {
      print('uploaded $bytesWritten of ${bytes.length} bytes');
    },
  );
  print('etag: $etag');

  // A time limited link the browser can use without the credentials.
  //
  // Workaround for arrrrrny/zuraffa_minio#1: `expires` is a number of
  // seconds, not a Duration — upstream minio never accepted a Duration
  // here either.
  final url = await minio.presignedUrl('GET', bucket, object, expires: 15 * 60);
  print('download url: $url');

  minio.close();
}
