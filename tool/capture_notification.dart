import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:zuraffa_minio/minio.dart';

/// Captures the raw payload MinIO sends to a bucket notification listener.
///
/// Not part of the published package - it is a development aid used to pin
/// the wire format the poller has to understand.
Future<void> main() async {
  final minio = Minio(
    endPoint: '127.0.0.1',
    port: 9000,
    accessKey: 'minioadmin',
    secretKey: 'minioadmin',
    useSSL: false,
    region: 'us-east-1',
  );

  const bucket = 'notification-capture';
  try {
    await minio.makeBucket(bucket);
  } catch (_) {
    // already there
  }

  final poller = minio.listenBucketNotification(
    bucket,
    prefix: 'capture/',
    events: ['s3:ObjectCreated:*'],
  );
  final subscription = poller.stream.listen(
    (event) => print('EVENT: $event'),
    onError: (Object error) => print('ERROR: $error'),
  );
  unawaited(poller.start());

  await Future<void>.delayed(const Duration(seconds: 2));
  await minio.putObject(
    bucket,
    'capture/object.txt',
    Stream<Uint8List>.value(Uint8List.fromList('hello'.codeUnits)),
  );
  await Future<void>.delayed(const Duration(seconds: 3));

  poller.stop();
  await subscription.cancel();
  minio.close();
  exit(0);
}
