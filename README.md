# zuraffa_minio

Zuraffa-native MinIO / S3-compatible client — SigV4 signing, bucket/object operations, usecases, auto-DI.

Created with `zfa package create` (spec 025). See
[Writing Zuraffa packages](https://github.com/arrrrny/zuraffa/blob/master/docs/writing_zuraffa_packages.md)
for the full guide.

## Develop

```bash
dart pub get
zfa entity create -n Product --field id:String --field name:String
zfa make Product datasource repository usecase di
zfa build
dart test
```

## Consume

```dart
final engine = ZuraffaEngine();
engine.registerPackage(ZuraffaMinioPackageModule());
await engine.bootstrap();
// the app container now resolves this package's
// datasources / repositories / usecases — no manual registration.
```
