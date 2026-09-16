/// Public surface of the `zuraffa_minio` package: the runtime module (lifecycle
/// entry point) and the package registrar (auto-DI registration unit).
///
/// Consuming apps import this barrel and activate the module — everything
/// else is internal architecture (spec 025).
library;

export 'src/module/zuraffa_minio_package_module.dart';
export 'src/di/zuraffa_minio_package_registrar.dart';
