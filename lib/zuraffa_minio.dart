/// zuraffa_minio — a maintained fork of the `minio` package.
///
/// A pure Dart client for MinIO and Amazon S3 compatible object storage.
/// This library is the package's default entry point and is web-safe; the
/// `dart:io` only helpers live in `package:zuraffa_minio/io.dart`.
///
/// The API is the upstream `minio` API, unchanged, so migrating is an import
/// swap:
///
/// ```dart
/// // Before
/// import 'package:minio/minio.dart';
/// // After
/// import 'package:zuraffa_minio/minio.dart';
/// // or
/// import 'package:zuraffa_minio/zuraffa_minio.dart';
/// ```
///
/// The S3 models keep their own library, `package:zuraffa_minio/models.dart`,
/// exactly as they did upstream. They are not exported from here on purpose:
/// one of them is called `Object`, and an export would shadow `dart:core`'s
/// `Object` in every file that imports this library.
library;

export 'minio.dart';
