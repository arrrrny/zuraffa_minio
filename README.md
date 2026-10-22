<p align="center">
  <h1 align="center">zuraffa_minio</h1>
</p>

A maintained fork of the [`minio`](https://pub.dev/packages/minio) package — the
pure Dart client for MinIO and Amazon S3 compatible object storage.

<p align="center">
  <a href="https://github.com/arrrrny/zuraffa_minio/actions/workflows/test.yml">
    <img src="https://github.com/arrrrny/zuraffa_minio/workflows/test/badge.svg">
  </a>
  <a href="https://pub.dev/packages/zuraffa_minio">
    <img src="https://img.shields.io/pub/v/zuraffa_minio">
  </a>
</p>

## Why a fork?

The upstream `minio` package has been unmaintained since August 2025. Its
issue tracker grew to 36 open issues, most of them unanswered, and its test
suite pointed at a public demo server that no longer exists — so the suite was
red for everyone, not just for the maintainer.

`zuraffa_minio` keeps the API of the original package **unchanged**, so
migrating is an import swap:

```dart
// before
import 'package:minio/minio.dart';
// after
import 'package:zuraffa_minio/minio.dart';
// or, the default library, which is web safe:
import 'package:zuraffa_minio/zuraffa_minio.dart';
```

Nothing else in your code has to change: the class is still `Minio`, the
methods keep their names and their parameters, and the models keep their
fields.

The models live in their own library, exactly as they did upstream:

```dart
import 'package:zuraffa_minio/models.dart';
```

They are deliberately not exported from the default library: one of them is
called `Object`, and an export would shadow the `Object` of `dart:core` in
every file that imports the package.

What the fork adds on top:

| | |
|---|---|
| **Dependencies** | `xml` 7 (upstream was pinned to 6.4.2), and every other pin moved to its current release |
| **Tests** | A hermetic suite that runs against a real MinIO server in CI — the upstream suite could not run at all |
| **Bug fixes** | Six reported bugs fixed, plus four more found on the way (see [What was fixed](#what-was-fixed)) |
| **Features** | The feature requests from the issue tracker: cancellation, credential renewal, presigned URL overrides, progress callbacks, parallel transfer, `objectUrl`, `removeObjectsByPrefix` |

## Usage

### Initialize the client

**A local MinIO server**

```dart
final minio = Minio(
  endPoint: '127.0.0.1',
  port: 9000,
  accessKey: 'minioadmin',
  secretKey: 'minioadmin',
  useSSL: false,
);
```

**Amazon S3**

```dart
final minio = Minio(
  endPoint: 's3.amazonaws.com',
  accessKey: 'YOUR-ACCESSKEYID',
  secretKey: 'YOUR-SECRETACCESSKEY',
  region: 'eu-central-1',
);
```

### Upload and download

```dart
import 'dart:typed_data';

import 'package:zuraffa_minio/minio.dart';

Future<void> main() async {
  final minio = Minio(
    endPoint: '127.0.0.1',
    port: 9000,
    accessKey: 'minioadmin',
    secretKey: 'minioadmin',
    useSSL: false,
  );

  final bytes = Uint8List.fromList('hello world'.codeUnits);

  final etag = await minio.putObject(
    'my-bucket',
    'greeting.txt',
    Stream<Uint8List>.value(bytes),
    size: bytes.length,
    onProgress: (written) => print('uploaded $written bytes'),
  );
  print('etag: $etag');

  final data = await minio.getObject('my-bucket', 'greeting.txt');
  final buffer = BytesBuilder();
  await for (final chunk in data) {
    buffer.add(chunk);
  }
  print(String.fromCharCodes(buffer.takeBytes()));

  minio.close();
}
```

### Files

`package:zuraffa_minio/io.dart` adds the `dart:io` helpers. It is a separate
library on purpose: the default library stays web safe.

```dart
import 'package:zuraffa_minio/io.dart';

await minio.fPutObject('my-bucket', 'picture.png', '/tmp/picture.png');
await minio.fGetObject('my-bucket', 'picture.png', '/tmp/picture-copy.png');
```

### Presigned URLs

```dart
// expires is a number of seconds
final url = await minio.presignedGetObject(
  'my-bucket',
  'greeting.txt',
  expires: 3600,
);
```

When the server the client talks to is not the host the browser reaches — a
proxy, a CDN, an internal and an external address — the presigned URL can be
generated for the public host while the client keeps talking to the internal
one:

```dart
final url = await minio.presignedUrl(
  'GET',
  'my-bucket',
  'greeting.txt',
  expires: 3600,
  host: 'objects.example.com',
  port: 443,
  useSSL: true,
);
```

The override is used in the url **and** in the signature, so the two can never
disagree.

### Temporary credentials

STS credentials expire. Instead of recreating the client, hand it a provider
that returns fresh credentials when they are needed:

```dart
final minio = Minio(
  endPoint: 's3.amazonaws.com',
  region: 'eu-central-1',
  credentialsProvider: () async {
    final session = await assumeRoleWithWebIdentity();
    return MinioCredentials(
      accessKey: session.accessKey,
      secretKey: session.secretKey,
      sessionToken: session.sessionToken,
    );
  },
);
```

The provider is called before the first request is signed, and again whenever
the credentials it returned are older than `credentialsTtl` (five minutes by
default). `refreshCredentials()` forces a new resolution right away. The
`accessKey`, `secretKey` and `sessionToken` getters always report the
credentials the next request will be signed with.

### Cancelling

```dart
final token = MinioCancellationToken();
final minio = Minio(
  endPoint: '127.0.0.1',
  port: 9000,
  accessKey: 'minioadmin',
  secretKey: 'minioadmin',
  useSSL: false,
  cancellationToken: token,
);

final upload = minio.putObject(
  'my-bucket',
  'big.bin',
  Stream<Uint8List>.value(data),
);
token.cancel();     // aborts the request that is in flight
await upload;       // the upload fails
```

Cancelling closes the underlying HTTP client, so the request that is in flight
is aborted. A request that has not been sent yet fails with a
`MinioRequestCancelledError`.

`minio.close()` aborts everything that is running as well.

### Your own HTTP client

The client is injectable, which is the escape hatch for proxies, custom
certificates and retry policies:

```dart
import 'package:http/io_client.dart';

final minio = Minio(
  endPoint: 'example.com',
  accessKey: '...',
  secretKey: '...',
  httpClient: IOClient(HttpClient()..badCertificateCallback = (_, __, ___) => true),
);
```

`package:zuraffa_minio/io.dart` has a shortcut for the certificate case:

```dart
final minio = Minio(
  endPoint: 'example.com',
  accessKey: '...',
  secretKey: '...',
  httpClient: createTlsHttpClient(allowInvalidCertificates: true),
);
```

### Parallel transfers

```dart
// upload the parts of a multipart upload concurrently
await minio.putObject(
  'my-bucket',
  'big.bin',
  Stream<Uint8List>.value(data),
  size: data.length,
  maxParallelUploads: 4,
);

// download the object as concurrent byte ranges
final stream = await minio.getObject(
  'my-bucket',
  'big.bin',
  parallelism: 8,
  chunkSize: 4 << 20,
);
```

## Regions

The region decides two things: the AWS host the request goes to and the scope
the request is signed with. The client keeps both in sync, and it asks the
server for the region of a bucket when it does not know it yet.

If the server rejects a request because the region is wrong, it answers with
`AuthorizationHeaderMalformed` and names the region the bucket really lives
in. The client then signs and addresses the request again with that region
and remembers it for the bucket.

## What was fixed

Every fix has a regression test whose name carries the number of the upstream
issue it reproduces.

| Issue | What was wrong |
|---|---|
| [#6](https://github.com/xtyxtyx/minio-dart/issues/6) | The notification poller called `json.decode` on the XML payload MinIO sends |
| [#24](https://github.com/xtyxtyx/minio-dart/issues/24) | A negative object size failed an `assert`, which only exists in debug builds |
| [#38](https://github.com/xtyxtyx/minio-dart/issues/38) | An unknown region fell back to the global endpoint, which only accepts `us-east-1` signatures |
| [#43](https://github.com/xtyxtyx/minio-dart/issues/43) | `getRequestUrl` read the region without a null check and threw "Unexpected null value" |
| [#49](https://github.com/xtyxtyx/minio-dart/issues/49) | `listBuckets` cast the whitespace text nodes between the buckets to `XmlElement` |
| [#108](https://github.com/xtyxtyx/minio-dart/issues/108) | `statObject` read `content-length` and `last-modified` with a bang operator |

Four more bugs were found while writing those tests:

- `listIncompleteUploads` sent the `uploads` parameter twice, which broke the
  signature of every request it made.
- `listParts` and `listIncompleteUploads` read the wrong XML elements and
  therefore always reported an empty, untruncated page.
- `listParts` cast the document node to `XmlElement`, which is a `TypeError`.
- `listIncompleteUploads` failed as a whole when a single upload could not be
  inspected any more.

## Running the tests

The suite needs an S3 compatible server. By default it talks to
`127.0.0.1:9000` with the `minioadmin` credentials:

```sh
minio server /tmp/minio-data --address 127.0.0.1:9000
dart test -j 2
```

Without a server the integration tests are skipped and the offline tests still
run. The server can be pointed somewhere else:

| Variable | Default | Meaning |
|---|---|---|
| `MINIO_ENDPOINT` | `127.0.0.1` | The host of the server |
| `MINIO_PORT` | `9000` | The port of the server |
| `MINIO_USE_SSL` | `false` | Whether the server speaks TLS |
| `MINIO_ACCESS_KEY` | `minioadmin` | The access key |
| `MINIO_SECRET_KEY` | `minioadmin` | The secret key |
| `MINIO_REGION` | `us-east-1` | The region to sign for |

> MinIO's open source server is archived: the docker images are gone and
> `dl.min.io` answers `410 Gone`. The CI workflow downloads the last release
> that ships a binary and runs that.

## API

| Bucket operations | Object operations | Presigned operations | Bucket policy & notification |
|---|---|---|---|
| `makeBucket` | `getObject` | `presignedUrl` | `getBucketNotification` |
| `listBuckets` | `getPartialObject` | `presignedGetObject` | `setBucketNotification` |
| `bucketExists` | `putObject` | `presignedPutObject` | `removeAllBucketNotification` |
| `removeBucket` | `statObject` | `presignedPostPolicy` | `listenBucketNotification` |
| `listObjects` | `copyObject` | | `getBucketPolicy` |
| `listObjectsV2` | `removeObject` | | `setBucketPolicy` |
| `listIncompleteUploads` | `removeObjects` | | |
| `listAllObjects` | `removeObjectsByPrefix` | | |
| `listAllObjectsV2` | `objectUrl` | | |
| | `initiateNewMultipartUpload` | | |
| | `uploadPart` | | |
| | `completeMultipartUpload` | | |
| | `removeIncompleteUpload` | | |

## What was added

Every addition answers an open issue of the upstream package, so the issue
tracker and the API stay traceable:

| Issue | What was added |
|---|---|
| [#4](https://github.com/xtyxtyx/minio-dart/issues/4), [#20](https://github.com/xtyxtyx/minio-dart/issues/20) | `onProgress` on `getObject` and `getPartialObject` |
| [#12](https://github.com/xtyxtyx/minio-dart/issues/12) | `objectUrl` |
| [#35](https://github.com/xtyxtyx/minio-dart/issues/35), [#98](https://github.com/xtyxtyx/minio-dart/issues/98) | `putObject(maxParallelUploads:)` |
| [#45](https://github.com/xtyxtyx/minio-dart/issues/45), [#85](https://github.com/xtyxtyx/minio-dart/issues/85), [#93](https://github.com/xtyxtyx/minio-dart/issues/93) | `MinioCancellationToken` and `MinioRequestCancelledError` |
| [#80](https://github.com/xtyxtyx/minio-dart/issues/80) | `createTlsHttpClient` |
| [#94](https://github.com/xtyxtyx/minio-dart/issues/94) | `MinioCredentials`, `credentialsProvider`, `refreshCredentials` |
| [#99](https://github.com/xtyxtyx/minio-dart/issues/99) | `removeObjectsByPrefix` |
| [#101](https://github.com/xtyxtyx/minio-dart/issues/101) | `host`, `port` and `useSSL` on the presigned calls |
| [#102](https://github.com/xtyxtyx/minio-dart/issues/102) | `uploadPart` and the multipart example |
| [#112](https://github.com/xtyxtyx/minio-dart/issues/112) | `getObject(parallelism:)` |

## License

MIT — see [LICENSE](LICENSE). The original package is MIT licensed as well;
the copyright of `xuty` is kept.
