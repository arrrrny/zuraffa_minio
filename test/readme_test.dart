import 'dart:io';

import 'package:test/test.dart';

/// The snippets of the README that are a whole program.
///
/// Every one of them is written to a file of its own and analyzed, so the
/// example of the README cannot drift away from the API without a failure.
const List<String> programs = [
  '''
import 'dart:typed_data';

import 'package:zuraffa_minio/minio.dart';

Future<void> main() async {
  final minio = Minio(
    endPoint: '127.0.0.1',
    port: 9000,
    accessKey: 'minioadmin',
    secretKey: 'minioadmin',
    useSSL: false,
  );

  final bytes = Uint8List.fromList('hello world'.codeUnits);

  final etag = await minio.putObject(
    'my-bucket',
    'greeting.txt',
    Stream<Uint8List>.value(bytes),
    size: bytes.length,
    onProgress: (written) => print('uploaded \$written bytes'),
  );
  print('etag: \$etag');

  final data = await minio.getObject('my-bucket', 'greeting.txt');
  final buffer = BytesBuilder();
  await for (final chunk in data) {
    buffer.add(chunk);
  }
  print(String.fromCharCodes(buffer.takeBytes()));

  minio.close();
}
''',
];

/// The snippets of the README that are a part of a program.
///
/// They are written into one file, each one in a block of its own, so that
/// two of them can use the same name.
const List<String> fragments = [
  '''
final minio = Minio(
  endPoint: 's3.amazonaws.com',
  accessKey: 'YOUR-ACCESSKEYID',
  secretKey: 'YOUR-SECRETACCESSKEY',
  region: 'eu-central-1',
);
''',
  '''
final url = await minio.presignedGetObject(
  'my-bucket',
  'greeting.txt',
  expires: 3600,
);
''',
  '''
final url = await minio.presignedUrl(
  'GET',
  'my-bucket',
  'greeting.txt',
  expires: 3600,
  host: 'objects.example.com',
  port: 443,
  useSSL: true,
);
''',
  '''
final minio = Minio(
  endPoint: 's3.amazonaws.com',
  region: 'eu-central-1',
  credentialsProvider: () async {
    final session = await assumeRoleWithWebIdentity();
    return MinioCredentials(
      accessKey: session.accessKey,
      secretKey: session.secretKey,
      sessionToken: session.sessionToken,
    );
  },
);
''',
  '''
final token = MinioCancellationToken();
final minio = Minio(
  endPoint: '127.0.0.1',
  port: 9000,
  accessKey: 'minioadmin',
  secretKey: 'minioadmin',
  useSSL: false,
  cancellationToken: token,
);

final upload = minio.putObject(
  'my-bucket',
  'big.bin',
  Stream<Uint8List>.value(data),
);
token.cancel();     // aborts the request that is in flight
await upload;       // the upload fails
''',
  '''
final minio = Minio(
  endPoint: 'example.com',
  accessKey: '...',
  secretKey: '...',
  httpClient: IOClient(HttpClient()..badCertificateCallback = (_, __, ___) => true),
);
''',
  '''
final minio = Minio(
  endPoint: 'example.com',
  accessKey: '...',
  secretKey: '...',
  httpClient: createTlsHttpClient(allowInvalidCertificates: true),
);
''',
  '''
// upload the parts of a multipart upload concurrently
await minio.putObject(
  'my-bucket',
  'big.bin',
  Stream<Uint8List>.value(data),
  size: data.length,
  maxParallelUploads: 4,
);

// download the object as concurrent byte ranges
final stream = await minio.getObject(
  'my-bucket',
  'big.bin',
  parallelism: 8,
  chunkSize: 4 << 20,
);
''',
];

/// The file the fragments are written into.
///
/// It carries the imports and the helpers the snippets of the README lean
/// on, so that a snippet that names something the package does not have
/// fails the analysis.
const String harness = '''
// ignore_for_file: unused_local_variable, unnecessary_import, unused_import

import 'dart:io';
import 'dart:typed_data';

import 'package:http/io_client.dart';
import 'package:zuraffa_minio/io.dart';
import 'package:zuraffa_minio/minio.dart';
import 'package:zuraffa_minio/models.dart';

class Session {
  final String accessKey = '';
  final String secretKey = '';
  final String sessionToken = '';
}

Future<Session> assumeRoleWithWebIdentity() async => Session();

Future<void> main() async {
  final data = Uint8List.fromList([1, 2, 3]);
  final minio = Minio(
    endPoint: '127.0.0.1',
    accessKey: 'minioadmin',
    secretKey: 'minioadmin',
  );
''';

/// The errors of an analysis, and nothing else.
List<String> errorsOf(String output) =>
    output.split('\n').where((line) => line.contains(' error - ')).toList();

void main() {
  test('the examples of the README are the ones that are checked', () {
    final readme = File('README.md').readAsStringSync();

    for (final program in programs) {
      expect(
        readme.contains(program.trim()),
        isTrue,
        reason: 'the README no longer holds this example:\n$program',
      );
    }

    for (final fragment in fragments) {
      expect(
        readme.contains(fragment.trim()),
        isTrue,
        reason: 'the README no longer holds this example:\n$fragment',
      );
    }
  });

  test('the whole examples of the README compile', () {
    final directory = Directory('test/.readme_check');
    directory.createSync(recursive: true);

    for (var index = 0; index < programs.length; index++) {
      File(
        '${directory.path}/program_$index.dart',
      ).writeAsStringSync(programs[index]);
    }

    final result = Process.runSync(Platform.resolvedExecutable, [
      'analyze',
      directory.path,
    ]);

    directory.deleteSync(recursive: true);

    expect(
      errorsOf('${result.stdout}\n${result.stderr}'),
      isEmpty,
      reason:
          'the examples of the README do not compile:\n'
          '${result.stdout}\n${result.stderr}',
    );
  });

  test('the parts of an example of the README compile', () {
    final directory = Directory('test/.readme_check');
    directory.createSync(recursive: true);

    final file = File('${directory.path}/fragments.dart');
    file.writeAsStringSync(
      '$harness${fragments.map((f) => '{\n$f}\n').join()}\n}\n',
    );

    final result = Process.runSync(Platform.resolvedExecutable, [
      'analyze',
      file.path,
    ]);

    directory.deleteSync(recursive: true);

    expect(
      errorsOf('${result.stdout}\n${result.stderr}'),
      isEmpty,
      reason:
          'the examples of the README do not compile:\n'
          '${result.stdout}\n${result.stderr}',
    );
  });
}
