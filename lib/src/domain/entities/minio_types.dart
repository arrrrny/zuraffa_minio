/// A typed failure from the MinIO client surface.
class MinioException implements Exception {
  final String code;
  final String message;
  final bool recoverable;

  const MinioException(this.code, this.message, {this.recoverable = true});

  @override
  String toString() => 'MinioException($code): $message';
}

/// Metadata for a stored object (HEAD Object).
class ObjectStat {
  final int size;
  final String? etag;
  final String? contentType;
  final DateTime? lastModified;

  const ObjectStat({
    required this.size,
    this.etag,
    this.contentType,
    this.lastModified,
  });
}

/// One entry from a bucket listing (ListObjectsV2).
class ObjectInfo {
  final String key;
  final int size;
  final String? etag;
  final DateTime? lastModified;

  const ObjectInfo({
    required this.key,
    required this.size,
    this.etag,
    this.lastModified,
  });

  @override
  String toString() => 'ObjectInfo(key=$key, size=$size, etag=$etag)';
}
