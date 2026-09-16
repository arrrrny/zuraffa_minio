# zuraffa_minio

**Zuraffa-native MinIO / S3-compatible client** — the replacement for the
**abandoned `minio` pub package** in the zuraffa ecosystem.

## Why this package exists

The `minio` pub package (last release 2023) pins `xml ^6.4.2`, and zuraffa
depends on it — which dragged `xml` 6 into every consumer of
`dart_curl` / the scraping family and blocked the ecosystem's `xml ^7` line.
`zuraffa_minio` reimplements the surface the ecosystem actually uses on a
plain HTTP transport + its own **AWS SigV4 signer** (no abandoned
dependencies, no xml 6 pin).

## Surface

```dart
final client = MinioClient(
  endpoint: 'http://localhost:9000',
  accessKey: 'minioadmin',
  secretKey: 'minioadmin',
);
await client.ensureBucket('photos');
await client.putObjectBytes(
  bucket: 'photos', key: 'a.jpg', bytes: bytes,
  contentType: 'image/jpeg', metadata: {'ctx-barcode': '123'},
);
final stat = await client.statObject('photos', 'a.jpg');
final objects = await client.listObjects('photos', recursive: true);
final url = client.presignedGetObject('photos', 'a.jpg');
```

- Buckets: `bucketExists`, `ensureBucket`, `removeBucket`
- Objects: `putObject`, `putObjectBytes`, `getObject`, `getObjectBytes`,
  `deleteObject`, `deleteObjects`, `statObject`, `listObjects` (xml 7)
- Presigned: `presignedGetObject`, `presignedPutObject`

## Zuraffa auto-DI

```dart
final engine = ZuraffaEngine()
  ..registerPackage(ZuraffaMinioModule(
    endpoint: 'http://localhost:9000',
    accessKey: 'minioadmin',
    secretKey: 'minioadmin',
  ));
await engine.bootstrap();

await engine.di.get<UploadObjectUseCase>()(UploadObjectParams(
  bucket: 'photos', key: 'a.jpg', bytes: bytes,
));
```

UseCases: `UploadObjectUseCase`, `DownloadObjectUseCase`,
`DeleteObjectUseCase`, `EnsureBucketUseCase` — failures surface as
`NetworkFailure` with the typed `MinioException` on `cause`.

## Verification

- SigV4 is pinned to the **published AWS documentation vector**
  (`get-vanilla`, expected signature `5fa00fa3…bf31`) plus an independent
  oracle vector for S3 PUT signing.
- Full suite: 24 tests, `dart analyze` clean.
- Transports are injectable (`MinioTransport`) — the entire client runs
  offline against scripted responses.

## Status / follow-ups

`xml` is constrained to `>=6.6.1 <8.0.0` (dev override pins 7.0.1) while
zuraffa still depends on the abandoned `minio`; the window narrows to `^7`
once zuraffa switches to this package or drops `minio` (tracked by the
zuraffa 1653 “trim heavy deps” work).
