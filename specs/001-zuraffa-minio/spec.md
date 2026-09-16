# Feature Specification: zuraffa_minio

**Template Version**: `zuraffa-migrate-1.0`
**Replaces**: the abandoned `minio` pub package (last release 2023,
`xml ^6.4.2` pin) for the zuraffa ecosystem.

## Overview / Mission

A zuraffa-native MinIO / S3-compatible client: SigV4-signed requests over an
injectable HTTP transport, no legacy dependency, xml 7 compatible. The
constructor and method surface mirror the wrapper the ecosystem already
used, so adoption is an import swap.

## Requirements

- FR-1: AWS SigV4 header signing + query presigning, spec-exact.
- FR-2: Bucket + object operations over `MinioTransport` (port), with a
  single dart:io adapter (`IoMinioTransport`).
- FR-3: `listObjects` parses ListObjectsV2 XML with `xml ^7`.
- FR-4: UseCases (`UploadObjectUseCase`, `DownloadObjectUseCase`,
  `DeleteObjectUseCase`, `EnsureBucketUseCase`) with `AppFailure` mapping
  (`NetworkFailure`, code `minio_<code>`, typed cause).
- FR-5: `ZuraffaMinioModule` + `registerZuraffaMinio` (auto-DI, never
  overrides pre-registered clients).

## Verification (TDD record)

| Vector | Source | Status |
|---|---|---|
| `get-vanilla` signature `5fa00fa3…bf31` | AWS SigV4 documentation | ✅ |
| S3 PUT signature `c329d19a…955c` | independent Python oracle | ✅ |
| Client ops (bucket/object/stat/list/presign) | scripted transport | ✅ 10 |
| UseCases + failure mapping | scripted transport | ✅ 5 |
| Registrar/module (incl. config_missing, never-override) | container | ✅ 5 |
| Smoke (registrable module) | scaffold contract | ✅ 2 |

Total: 24 tests, `dart analyze` clean.
