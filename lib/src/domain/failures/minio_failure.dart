import 'package:zuraffa/zuraffa.dart';

import '../entities/minio_types.dart';

/// Builds the zuraffa failure for a [MinioException].
///
/// `AppFailure` is sealed: the typed error rides on [AppFailure.cause] and
/// the code rides on [AppFailure.code] (`minio_<code>`).
AppFailure minioFailure(MinioException error) => NetworkFailure(
      error.message,
      code: 'minio_${error.code}',
      cause: error,
    );

/// Maps a zuraffa [AppFailure] back onto the legacy surface.
MinioException mapFailureToMinioException(AppFailure failure) {
  final cause = failure.cause;
  if (cause is MinioException) return cause;
  return MinioException('app_failure', failure.message);
}
