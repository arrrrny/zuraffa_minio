# Feature Specification: zuraffa_minio — the maintained fork of `minio`

**Feature Branch**: `001-upstream-fork`
**Created**: 2026-10-22
**Status**: Implemented
**Input**: User description: "Fork the abandoned `minio` package as `zuraffa_minio`, upgrade the dependencies (xml first), sweep all the open upstream issues and notify their openers about the new package."

## Overview

The `minio` package on pub.dev — the pure-Dart client for MinIO and Amazon S3
compatible object storage — has been unmaintained since 2025-08-15. Its issue
tracker carries 36 open issues, the newest of which asks whether the repository
is dead. It is.

MinIO itself has gone the same way: the open-source server, the `mc` client and
the Docker image are archived, `dl.min.io` answers `410 Gone`, and the public
demo server refuses writes with *"Access denied. No license is installed."*. The
**client** is still worth maintaining — it speaks plain S3 and works against
every S3-compatible server — but its test suite, which depended on the public
demo server, has been failing for everyone since before the last release.

This feature forks the upstream package into `zuraffa_minio`:

- the source and the history come from upstream, so the fork is a fork;
- the public API is **unchanged**, so migrating is an import swap and the
  people who filed the issues can use their fix;
- the dependency pins move forward — `xml` from 6.4.2 to 7.x first, and every
  other pin to its current release;
- the 36 open issues are swept: every one gets a disposition, the bugs get
  fixed with tests, the features get implemented or answered, and every opener
  is told about the fork.

## The upstream issue sweep

36 open issues, one disposition each. "Stale" means upstream already fixed it
and the fix is verified in this fork.

| # | Issue | Disposition |
|---|---|---|
| 118 | Is this repository dead? | Answered — yes, now maintained here |
| 112 | Parallel downloading | **Implemented** — `getObject(parallelism:)` |
| 108 | `statObject` crashes on a null check | **Fixed** — a missing `content-length` no longer crashes |
| 106 | Error when the path has a `+` sign | Stale — fixed in 3.5.8, verified by a test |
| 104 | Wrap the Rust or Go implementation | Answered — no FFI, the pure Dart client stays |
| 102 | MultipartUpload example | **Added** — `example/multipart_upload_example.dart` |
| 101 | Presigned URL host/port/scheme | **Implemented** — overrides on the presigned calls |
| 100 | Image upload fails, namespace/access key | Answered — credentials and endpoint configuration |
| 99 | Delete a folder and its data | **Implemented** — `removeObjectsByPrefix` |
| 98 | Upload the parts in parallel | **Implemented** — `putObject(parallelism:)` |
| 94 | Temporary credential renewal | **Implemented** — a credentials provider callback |
| 93 | Switch from `http` to `dio` | Answered — instead the `http.Client` is injectable |
| 85 | Cancel the request session | **Implemented** — `close()`, and the client is injectable |
| 80 | Bypass the certificate check | Answered — through the injectable `http.Client` |
| 68 | Fix the more understandable document | **Fixed** — the examples that confused people |
| 64 | Flutter web image upload example | **Added** — `example/web_upload_example.dart` |
| 60 | Cannot upload large files on web in debug | Answered — the web constraints, and what to do |
| 59 | `fPutObject` does not contain `onProgress` | Stale — present since 3.4.0, verified |
| 58 | How to create a `File` from a stream on web | Answered — `dart:io` does not exist on the web |
| 56 | XMLHttpRequest error on `putObject` | Answered — CORS on the server |
| 49 | `listBuckets` assumes the XML type | **Fixed** — the parsing is type-safe now |
| 47 | Cognito federated pool ids | Answered — fetch temporary credentials, pass them in |
| 45 | Cancel the upload session | **Implemented** — as #85 |
| 43 | `putObject` throws "Unexpected null value" | **Fixed** — a null region no longer crashes |
| 41 | Temporary credentials support | Stale — the token header landed in 2022, verified |
| 40 | The web upload of a 2 GB file interrupts | Answered — the browser's limits, and what to do |
| 38 | The region is not the one specified | **Fixed** — the region is used, and the error explains itself |
| 37 | The web upload hangs at completion | Answered — CORS and the preflight request |
| 35 | The upload speed is too slow | **Implemented** — as #98 and #112 |
| 33 | `WRONG_VERSION_NUMBER` handshake error | Answered — the endpoint speaks plain HTTP |
| 24 | The `assert(size)` issue | **Fixed** — a real check with a real message |
| 20 | 上传进度监听 (upload progress) | **Implemented** — `getObject(onProgress:)` |
| 12 | Get the upload url instead of the etag | **Implemented** — `objectUrl(bucket, object)` |
| 6 | Parse error when listening to notifications | **Fixed** — MinIO's XML notification format is parsed |
| 4 | Progress callback | **Implemented** — as #20 |
| 3 | AccessKey error | Stale — as #41, plus an answer |

## User Scenarios & Testing

### User Story 1 - Migrate without changing code (Priority: P1)

Someone using the `minio` package swaps the import and keeps everything else:
the `Minio` class, its methods, its models and its exceptions are the same
ones. A file-based helper (`package:zuraffa_minio/io.dart`) keeps its name too.

**Why this priority**: every other story is worthless if the migration is not
drop-in — the issue reporters cannot use the fixes otherwise.

**Independent test**: compile a file that uses `Minio`, `MinioByteStream`,
`putObject` and `StatObjectResult` against `package:zuraffa_minio/minio.dart`.

### User Story 2 - Call statObject on a server that omits a header (Priority: P1)

A user calls `statObject` against a server that answers a `HEAD` without a
`content-length`. They get a result with the size they can read, not a crash.

**Why this priority**: it is the newest bug report on the tracker, it is a
one-line crash, and it takes down the caller's whole upload flow.

**Independent test**: a `HEAD` response without `content-length` yields a
`StatObjectResult` whose `size` is null instead of throwing.

### User Story 3 - List the buckets of a server that pads its XML (Priority: P1)

A user points the client at Backblaze, whose XML carries text nodes between
the elements. `listBuckets` returns the buckets instead of throwing a cast
error.

**Independent test**: XML with whitespace text nodes between `<Bucket>`
elements parses to the same bucket list.

### User Story 4 - Stop a runaway upload (Priority: P2)

A user starts an upload that is going the wrong way and wants to stop it. They
close the client, and the in-flight request ends.

**Why this priority**: asked for twice (#85, #45), and the answer also unlocks
the custom TLS configuration of #80.

**Independent test**: a request in flight is aborted when the client is closed.

### User Story 5 - Upload and download in parallel (Priority: P2)

A user on a slow link wants the parts of a multipart upload to go out
concurrently, and wants a large object to be fetched in ranges.

**Independent test**: a multi-part object uploads with `parallelism: 4` and
reads back byte-identical; a ranged download reassembles the original bytes.

### User Story 6 - Read the issue tracker and find the answer (Priority: P2)

Someone lands on an old issue and learns what happened to it: fixed, stale,
implemented here, or answered.

**Why this priority**: the sweep is the point of the exercise, and an issue
tracker full of silence is what made the package look dead.

**Independent test**: every one of the 36 issues carries a comment from this
maintainer with the disposition above.

## Requirements

### Functional requirements

- **FR-1** The package is named `zuraffa_minio` and its public API is
  byte-for-byte the upstream API: `Minio`, `MinioByteStream`, the models, the
  errors, `lib/minio.dart`, `lib/models.dart` and `lib/io.dart`.
- **FR-2** `package:zuraffa_minio/zuraffa_minio.dart` is the default library
  and is web-safe; `lib/io.dart` stays separate because it needs `dart:io`.
- **FR-3** `xml` moves from `^6.4.2` to `^7.0.0`, and every other dependency
  pin moves to its current release.
- **FR-4** The test suite runs against a local S3 server, configured through
  the environment, and skips the integration tests with an explicit reason when
  no server answers. The unit tests always run.
- **FR-5** `statObject` tolerates a response without `content-length` or
  `last-modified`.
- **FR-6** The XML parsing never assumes a node is an `XmlElement`.
- **FR-7** The notification poller parses the XML notification format MinIO
  returns, and still accepts the JSON event format.
- **FR-8** A null region never crashes a request; the region is used when one
  is given, and the error message says so when the endpoint rejects it.
- **FR-9** The client can be closed, and the underlying `http.Client` can be
  supplied by the caller.
- **FR-10** The presigned calls accept a host, a port and a scheme override.
- **FR-11** `getObject` reports progress.
- **FR-12** The upload and the download can run their parts in parallel.
- **FR-13** The credentials can come from a callback, so a temporary
  credential can be renewed while a long transfer runs.
- **FR-14** `removeObjectsByPrefix` removes a "folder" and everything under it.
- **FR-15** `objectUrl` builds the url of an object.
- **FR-16** The examples cover the multipart upload and the web upload, and the
  documentation explains the confusing parts.

### Non-functional requirements

- **NFR-1** The upstream test suite passes unchanged, plus the new tests.
- **NFR-2** `dart analyze` is clean and `dart format` changes nothing.
- **NFR-3** The public API only grows: nothing an upstream user calls today
  changes its meaning. The new parameters are optional.
- **NFR-4** The package keeps no dependency on the `zuraffa` framework, so it
  stays as light as it was.

## Success Criteria

- `dart test` passes against a local MinIO, and the unit tests pass with no
  server at all.
- `dart analyze` reports no issues.
- Every one of the 36 open issues carries a maintainer's comment naming its
  disposition.
- The package is published, and the README says plainly that it is a fork of
  an unmaintained package, and what changed.
