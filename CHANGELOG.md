## 0.1.0

### Added

- `S3SigV4` — AWS Signature Version 4 header signing + query presigning,
  pinned to the published AWS documentation vector (`get-vanilla`) and an
  independent oracle vector for S3 PUT signing.
- `MinioClient` — bucket operations (`bucketExists`, `ensureBucket`,
  `removeBucket`), object operations (`putObject`, `putObjectBytes`,
  `getObject`, `getObjectBytes`, `deleteObject`, `deleteObjects`,
  `statObject`, `listObjects` with xml 7), presigned URLs — implemented
  over an injectable `MinioTransport` with a single dart:io adapter.
- UseCases (`UploadObjectUseCase`, `DownloadObjectUseCase`,
  `DeleteObjectUseCase`, `EnsureBucketUseCase`) mapping `MinioException`
  onto `NetworkFailure` (code `minio_<code>`, typed cause on `cause`).
- `ZuraffaMinioModule` + `registerZuraffaMinio` — auto-DI that never
  overrides pre-registered clients and fails typed (`config_missing`) when
  no config is supplied.

Replaces the abandoned `minio` pub package (last release 2023, `xml ^6.4.2`
pin) for the zuraffa ecosystem.
