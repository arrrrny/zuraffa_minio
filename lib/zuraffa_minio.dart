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
library;

export 'minio.dart';
export 'models.dart';
