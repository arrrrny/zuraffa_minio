## 7.3.0 - 2026-10-28

- Mono-version fleet alignment: the whole zuraffa family ships at 7.3.0 together with the core.
- `zuraffa` dependency constraints unified to ^7.3.0; cross-family constraints move with the release.
- Fleet-wide `dependency_overrides: xml: 7.1.0`; README install guides refreshed to 7.3.0.

## 7.2.0 - 2026-10-28

- Mono-version fleet alignment: the whole zuraffa family now ships at the same version as the core.
- `zuraffa` dependency constraint unified to ^7.2.0 across the fleet.
- zuraffa_storage now wraps the maintained `zuraffa_minio` fork instead of the abandoned `minio` package (xml 7 compatible).
- Fleet-wide `dependency_overrides: xml: 7.1.0` policy; README install guides refreshed to the release version.

# 0.2.5

Restores the upstream constructor with its required credentials, writes the
notification configuration shape a MinIO server really speaks, and bounds the
parallel download's buffer.

**Breaking for the users of 0.2.4** — the constructor is the one of the
upstream package again:

- `Minio(...)` asks for the `accessKey` and the `secretKey` again. In 0.2.4
  they were optional, so a client that forgot them signed every request with
  an empty key and was anonymous without saying so. A client that resolves
  its own credentials calls `Minio.withCredentialsProvider(...)` now, which
  needs no placeholder keys. The primary constructor still takes a
  `credentialsProvider`; once one resolves, it takes precedence over the
  static keys the client was built with.
- the notification configuration reads and writes the shape a MinIO server
  really speaks: the configurations are the direct children of
  `<NotificationConfiguration>`, the destination is `<Queue>`, `<Topic>` or
  `<CloudFunction>`, and the events are repeated `<Event>` elements. The
  older forms are still read, so a server that answers with them keeps
  working. The 0.2.4 entry described the wrapper element; that was wrong.
- `getObject` rejects a chunk size of zero at the entry point, before the
  size of the object is fetched over the network.
- a parallel download buffers at most `parallelism` ranges ahead of the head
  of the object. Before, the ranges that came back early were buffered
  without a bound.
- a `host` override that names a global Amazon endpoint is not discarded
  any more. Only an endpoint that was not overridden is regionalized.
- the committed model file carries the generator's header again, and the
  tests guard that much. The model list and the doc comments follow the live
  AWS API documentation, so regenerating adds whatever AWS documents today.
- the test groups remove their buckets and their objects again, so a run of
  the suite leaves nothing behind on the server.
- the workflow of the tests picks the MinIO binary for the platform of the
  runner, and the server no longer holds the step open: the tests run
  against a server that is really there.

---

# 0.2.4

The findings of the review of the pull request of the fork.

- a parallel download that lost a range hands the error to the consumer
  instead of ending the stream normally. A truncated download can no longer
  look like a complete one.
- the planner of the byte ranges rejects a chunk size of zero, which made it
  run forever.
- `uploadPart` accepts a plain list of bytes again; only a `Uint8List` could
  be sent as the body of a request before.
- `close` only closes a client the instance created itself. A client that was
  passed to the constructor belongs to the caller.
- the Amazon endpoints keep the path style of the upstream package as their
  default, so a migration stays an import swap. The virtual host style is one
  setting away: `pathStyle: false`.
- the notification configuration reads and writes the wrapper elements the
  server uses: the configurations are a list, and the events are the children
  of the `Events` element. The upstream package parsed the wrapper element
  itself, so every field of a configuration came back empty.
- the default library no longer exports the models. One of them is called
  `Object`, and the export shadowed the `Object` of `dart:core` in every
  file that imported the package. The models live in
  `package:zuraffa_minio/models.dart`, exactly as they did upstream.
- the generator of the models writes code that compiles. The committed file
  carries the corrections of the notification models by hand; the generator
  says so.

---

# 0.2.3

- the counting semaphore of the parallel download is covered by a test now.
  The test fails against the implementation of 0.2.1 and 0.2.2: that one gave
  the slot back before it handed it over, so a caller that arrived in the
  middle of the handover could take a second slot and push the number of
  requests in flight past the limit.
- the wording of the 0.2.2 entry overstated how reachable that problem was:
  the parallel download asks for all of its ranges up front, so the window was
  never open on that path. The fix stays, and it is now covered by a test.

---

# 0.2.2

- the counting semaphore that caps the number of requests in flight hands the
  slot over to the next waiter instead of giving it back first, so the number
  of slots in use never grows past the limit when a caller arrives in the
  middle of a handover.
- the parallel multipart upload remembers the failure of a part instead of
  letting it propagate. The parts that are still in flight no longer end up
  as unhandled errors, and the first failure is rethrown once the bounded
  wait is over.

---

# 0.2.1

- the presigned calls resolve the credentials of a `credentialsProvider` before
  they sign, like every other request does. Without it a client that has only
  a provider — no static keys — signed its presigned URLs with an empty
  access key.

---

# 0.2.0

The first release of `zuraffa_minio`, the maintained fork of the `minio`
package. The API of the original package is unchanged, so migrating is an
import swap:

```dart
// before
import 'package:minio/minio.dart';
// after
import 'package:zuraffa_minio/minio.dart';
```

## Dependencies

- `xml` from 6.4.2 to 7.x, and every other pin moved to its current release
  (`http` 1.6, `crypto` 3.0.7, `convert` 3.1.2, `intl` 0.20.2, `meta` 1.16,
  `mime` 2.0.0, `path` 1.9.1)

## Fixed

- #6 the notification poller called `json.decode` on the XML payload MinIO
  sends; it understands the XML and the JSON format now, and it no longer
  delivers every event twice
- #24 a negative object size failed an `assert`, which only exists in debug
  builds; it is an `ArgumentError` now
- #38 an unknown region fell back to the global endpoint, which only accepts
  `us-east-1` signatures ("the region is wrong; expecting 'us-east-1'"); the
  regional host is kept, and a request the server rejects with
  `AuthorizationHeaderMalformed` is signed and addressed again with the
  region the server names
- #43 `getRequestUrl` read the region without a null check and threw
  "Unexpected null value" for every request against an Amazon endpoint
  without a region
- #49 `listBuckets` cast the whitespace text nodes between the buckets to
  `XmlElement`
- #108 `statObject` read `content-length` and `last-modified` with a bang
  operator and crashed when a server left one of them out
- `listIncompleteUploads` sent the `uploads` parameter twice, which broke the
  signature of every request it made
- `listParts` and `listIncompleteUploads` read the wrong XML elements and
  therefore always reported an empty, untruncated page
- `listParts` cast the document node to `XmlElement`, which is a `TypeError`
- `listIncompleteUploads` failed as a whole when a single upload could not be
  inspected any more
- a client with a `credentialsProvider` signed its requests anonymously: it
  decided it was anonymous before the provider had resolved the credentials

## Added

- #85, #45, #93 a `MinioCancellationToken` that aborts the requests in flight,
  and `Minio.close()` that aborts everything that is running
- #80, #93 the `http.Client` can be injected, and `package:zuraffa_minio/io.dart`
  has `createTlsHttpClient` for a custom `SecurityContext` or for accepting
  invalid certificates
- #101 `presignedUrl` and `presignedPostPolicy` accept `host`, `port` and
  `useSSL` overrides, so a presigned URL can be generated for a public host
  while the client talks to an internal one
- #94 a `credentialsProvider` callback, so temporary (STS) credentials can be
  renewed while the application runs
- #4, #20 `getObject` and `getPartialObject` report the download progress
  through `onProgress`
- #12 `objectUrl` returns the plain URL of an object
- #99 `removeObjectsByPrefix` removes every object under a prefix
- #102 `uploadPart` uploads a single part of a multipart upload, so an
  application can drive the multipart upload itself
- #112 `getObject` can fetch the object as concurrent byte ranges
- #98 `putObject` can upload the parts of a multipart upload concurrently

## Testing

- the test suite no longer depends on the public demo server (which is gone);
  it talks to a local MinIO server and skips the integration tests with a
  reason when no server answers
- the CI workflow starts a MinIO server and runs the whole suite against it

## Note

The `zuraffa_minio` 0.1.x releases were a from-scratch rewrite with a
different API and a dependency on the `zuraffa` framework. They are withdrawn:
this release is the drop-in fork of the upstream package, which is what the
issue reports are written against. The 0.1.x implementation is kept on the
`archive/0.1.x-rewrite` branch.

---

# 3.5.8

- Fix path encoding for space and plus characters in object names to prevent signature mismatch errors #7
- Update fPutObject method signature to use named parameters for better API consistency

# 3.5.7

- fix maxKeys error while using listObject query #97
- Bump intl from 0.19.0 to 0.20.0 in the root-pub group #96

# 3.5.6

- Fix non en-US date time parse #95

# 3.5.5

- Move x-amz-security-token allocation before signV4 to correctly sign the request #92
- Bump mime from 1.0.6 to 2.0.0 in the root-pub group #91

# 3.5.4

- Add validation for HTTP response for `getObjectACL` / Make retrieval of ACLs optional for `statObject` #48

# 3.5.3

- Add `pathStyle` parameter to `Minio` constructor to support custom endpoints.

# 3.5.2

- Downgrade `meta` package to `1.12.0` to fix compatibility issues with Flutter.

# 3.5.1

- Updates minimum supported SDK version to Dart 3.0.
- Fixes all lint warnings.
- Added x-amz-security-token header support for session tokens.
- Wait for rename to finish before in `fGetObject`.
- Updated `MinioError` to implement the `Exception` interface.
- Added XML validation before parsing response body.
- Updated return type of `presignedPostPolicy` to `Future<PostPolicyResult>`.
- Replaced `push` with `add` for adding conditions to the policy.

# 3.5.0

- Fix listObject with utf-8 prefix

# 3.4.0-pre

- Better upload progress on web

# 3.3.3

- Fix empty upload error
- Update README.md

# 3.3.3-pre

- Update stream file upload

# 3.3.2-pre

- Add tests

# 3.3.1-pre

- Improve upload progress granularity
- Fix broken test

# 3.3.0-pre

- Support listening upload progress

# 3.2.0

- Fix response body utf-8 encoding [#14]

# 3.1.0

- Add `listAllObjects` and `listAllObjectsV2`
- Fix signing error in `listObjects` when prefix contains spaces [#34]
- Improved compatibility with Filebase [#31]

# 3.0.0

- Fixes signing error in case object name contains symbols [#29]

# 2.1.0-pre

- `getObject` now returns `MinioByteStream` with an additional `contentLength` field.

## 2.0.0-pre

- Migrate to NNBD

## 1.4.0-pre

- Object's ACL Query; Include object's ACL in stat [#23](https://github.com/xtyxtyx/minio-dart/pull/23), thanks [@rtgnx](https://github.com/rtgnx)

## 1.3.0

- fix HTTP header for user-defined object metadata [#17](https://github.com/xtyxtyx/minio-dart/issues/17), thanks [@philenius](https://github.com/philenius)

## 1.2.0

- fix [#15](https://github.com/xtyxtyx/minio-dart/issues/15) fPutObject content-type: 'image/jpeg' is ignored

## 1.1.0

## 1.1.0-pre

- fix bucketExists is true when bucket doesn't exist #13

## 1.0.2-pre

- Replace static region 'us-east-1' in method listBuckets() with variable's value

## 1.0.1-pre

- Updated dependencies
- Fixed Malformed XML error
- Fixed Types incompatibility in minio_uploader stream subscription queries
- Temporarily closed call for search of unfinished uploads (Causes Signature Error)

## 0.1.8

- Update dependency

## 0.1.7

- Fix region issue, thanks @ivoryxiong

## 0.1.6

- support policy apis

## 0.1.5

- support notification apis

## 0.1.4

- support presignedPostPolicy

## 0.1.3

- support presignedGetObject and presignedPutObject

## 0.1.2

- support presignedUrl

## 0.1.1

- update dependency

## 0.1.0+2

- try to fix table display

## 0.1.0+1

- update README

## 0.1.0

- Initial version, created by Stagehand

[#34]: https://github.com/xtyxtyx/minio-dart/issues/34
[#31]: https://github.com/xtyxtyx/minio-dart/issues/31
[#29]: https://github.com/xtyxtyx/minio-dart/issues/29
[#14]: https://github.com/xtyxtyx/minio-dart/issues/14
