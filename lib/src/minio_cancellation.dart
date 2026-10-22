import 'dart:async';

/// A token that cancels the requests of a Minio client.
///
/// Hand it to the Minio constructor and call [cancel] to stop the client:
/// every request that is in flight when the token is cancelled is aborted
/// (the underlying HTTP client is closed), and every request issued
/// afterwards fails fast with a `MinioRequestCancelledError` instead of
/// being sent.
///
/// This answers upstream issues #85 ("How to cancel a request?"), #45
/// ("Cancel get object") and #93 ("Abort / cancel ongoing API requests")
/// of the `minio` package.
class MinioCancellationToken {
  final Completer<void> _completer = Completer<void>();

  /// Whether [cancel] has already been called.
  bool get isCancelled => _completer.isCompleted;

  /// Completes as soon as [cancel] is called.
  ///
  /// Awaiting this is the way to pause until cancellation happens:
  ///
  /// ```dart
  /// token.whenCancelled.then((_) => print('cancelled'));
  /// ```
  Future<void> get whenCancelled => _completer.future;

  /// Cancels every in-flight and future request of the client this token
  /// was given to.
  ///
  /// Calling [cancel] more than once has no additional effect.
  void cancel() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}
