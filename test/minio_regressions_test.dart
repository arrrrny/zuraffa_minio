import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:zuraffa_minio/minio.dart';

import 'helpers.dart'
    show
        detectMinioServer,
        getMinioClient,
        minioServerAvailable,
        minioServerSkipReason,
        uniqueName;

/// Regression tests for the bugs reported against the upstream `minio`
/// package.
///
/// Every test name carries the number of the upstream issue it covers, so
/// the sweep of the open issues stays traceable:
///
/// * #49  - `listBuckets` assumed every child of `<Buckets>` is an element
/// * #108 - `statObject` crashed on a response without `content-length`
/// * #43  - an Amazon endpoint without an explicit region threw
///          "Unexpected null value"
/// * #24  - a negative size failed an `assert` instead of an argument check
/// * #6   - the notification poller called `json.decode` on an XML payload
/// * #38  - a request signed for the wrong region was never recovered
Minio _mockClient(
  Future<http.Response> Function(http.Request request) handler, {
  String endPoint = '127.0.0.1',
  int port = 9000,
  bool useSSL = false,
  String? region = 'us-east-1',
}) => Minio(
  endPoint: endPoint,
  port: port,
  useSSL: useSSL,
  accessKey: 'accesskey',
  secretKey: 'secretkey',
  region: region,
  httpClient: MockClient(handler),
);

Future<void> main() async {
  await detectMinioServer();

  group('upstream issue #49 - listBuckets', () {
    test(
      '#49 listBuckets ignores whitespace text nodes between <Bucket> elements',
      () async {
        final minio = _mockClient((request) async {
          return http.Response('''
<?xml version="1.0" encoding="UTF-8"?>
<ListAllMyBucketsResult>
  <Owner>
    <ID>minio</ID>
    <DisplayName>minio</DisplayName>
  </Owner>
  <Buckets>
    <Bucket>
      <Name>bucket-one</Name>
      <CreationDate>2024-01-01T00:00:00.000Z</CreationDate>
    </Bucket>
    <Bucket>
      <Name>bucket-two</Name>
      <CreationDate>2024-01-02T00:00:00.000Z</CreationDate>
    </Bucket>
  </Buckets>
</ListAllMyBucketsResult>''', 200);
        });

        final buckets = await minio.listBuckets();

        expect(buckets.map((bucket) => bucket.name), [
          'bucket-one',
          'bucket-two',
        ]);
      },
    );
  });

  group('upstream issue #108 - statObject', () {
    test(
      '#108 statObject survives a response without content-length',
      () async {
        final minio = _mockClient((request) async {
          return http.Response(
            '',
            200,
            headers: {'etag': '"d41d8cd98f00b204"'},
          );
        });

        final stat = await minio.statObject(
          'bucket',
          'object',
          retrieveAcls: false,
        );

        expect(stat.size, isNull);
        expect(stat.lastModified, isNull);
        expect(stat.etag, 'd41d8cd98f00b204');
      },
    );

    test('#108 statObject still reports the size when it is present', () async {
      final minio = _mockClient((request) async {
        return http.Response(
          '',
          200,
          headers: {
            'content-length': '42',
            'last-modified': 'Tue, 01 Jan 2024 00:00:00 GMT',
            'etag': '"abc"',
          },
        );
      });

      final stat = await minio.statObject(
        'bucket',
        'object',
        retrieveAcls: false,
      );

      expect(stat.size, 42);
      expect(stat.lastModified, DateTime.utc(2024));
    });
  });

  group('upstream issue #43 - region', () {
    test(
      '#43 an Amazon endpoint without an explicit region does not throw',
      () async {
        final minio = _mockClient((request) async {
          return http.Response(
            '<?xml version="1.0"?><ListAllMyBucketsResult><Buckets/>'
            '</ListAllMyBucketsResult>',
            200,
          );
        }, endPoint: 's3.amazonaws.com');

        // Upstream read `minio.region!` while building the request URL and
        // threw "Unexpected null value" for every request against an Amazon
        // endpoint without a region.
        await expectLater(minio.listBuckets(), completes);
      },
    );

    test('#43 a request against an Amazon endpoint keeps a region', () async {
      final seen = <Uri>[];
      final minio = _mockClient(
        (request) async {
          seen.add(request.url);
          return http.Response(
            '<?xml version="1.0"?><ListAllMyBucketsResult><Buckets/>'
            '</ListAllMyBucketsResult>',
            200,
          );
        },
        endPoint: 's3.amazonaws.com',
        region: 'ap-northeast-1',
      );

      await minio.listBuckets();

      expect(seen.single.host, 's3-ap-northeast-1.amazonaws.com');
    });
  });

  group('upstream issue #38 - wrong region', () {
    test('#38 a request signed for the wrong region is retried with the region '
        'the server names', () async {
      final requests = <http.Request>[];
      final minio = _mockClient(
        (request) async {
          requests.add(request);
          if (requests.length == 1) {
            return http.Response(
              '<?xml version="1.0" encoding="UTF-8"?>'
              '<Error><Code>AuthorizationHeaderMalformed</Code>'
              '<Message>The authorization header is malformed; the region is '
              "wrong; expecting 'us-east-1'.</Message>"
              '<Region>us-east-1</Region></Error>',
              400,
            );
          }
          return http.Response(
            '<?xml version="1.0"?><ListAllMyBucketsResult><Buckets/>'
            '</ListAllMyBucketsResult>',
            200,
          );
        },
        endPoint: 's3.amazonaws.com',
        region: 'ap-northeast-1',
      );

      await minio.listBuckets();

      expect(requests, hasLength(2));
      expect(
        requests.first.headers['authorization'],
        contains('/ap-northeast-1/'),
        reason: 'the first attempt is signed for the configured region',
      );
      expect(
        requests.last.headers['authorization'],
        contains('/us-east-1/'),
        reason: 'the retry is signed for the region the server asked for',
      );
      expect(requests.last.url.host, 's3.amazonaws.com');
    });
  });

  group('upstream issue #24 - object size', () {
    test('#24 a negative size is rejected with an argument error', () async {
      final minio = getMinioClient();

      await expectLater(
        minio.putObject(
          'bucket',
          'object',
          Stream<Uint8List>.value(Uint8List.fromList([1, 2, 3])),
          size: -1,
        ),
        throwsA(isA<MinioInvalidArgumentError>()),
      );
    });
  });

  group('upstream issue #6 - bucket notifications', () {
    test('#6 the JSON payload of a current MinIO server is understood', () {
      final records = parseNotificationRecords(
        '{"Records":[{"eventVersion":"2.0","eventSource":"minio:s3",'
        '"eventTime":"2026-10-22T10:32:29.682Z",'
        '"eventName":"s3:ObjectCreated:Put",'
        '"s3":{"object":{"key":"capture/object.txt","sequencer":"18E0D374"}}}]}',
      );

      expect(records, hasLength(1));
      expect(records.first['eventName'], 's3:ObjectCreated:Put');
    });

    test('#6 an XML payload is understood', () {
      final records = parseNotificationRecords('''
<?xml version="1.0" encoding="UTF-8"?>
<Notification>
  <Event>
    <EventConfiguration>{"eventVersion":"2.0","configurationId":"Config"}</EventConfiguration>
    <EventConfiguration>{"eventVersion":"2.0","configurationId":"Config"}</EventConfiguration>
    <Event>{"eventVersion":"2.0","eventSource":"minio:s3","eventName":"s3:ObjectCreated:Put","s3":{"object":{"key":"a/b.txt","sequencer":"1"}}}</Event>
  </Event>
</Notification>''');

      expect(records, hasLength(1));
      expect(records.first['eventName'], 's3:ObjectCreated:Put');
    });

    test('#6 an XML payload with plain elements is understood', () {
      final records = parseNotificationRecords('''
<?xml version="1.0" encoding="UTF-8"?>
<Notification>
  <Event>
    <key>photos/2019/</key>
    <eventName>s3:ObjectCreated:Put</eventName>
    <eventTime>2022-01-01T00:00:00.000Z</eventTime>
  </Event>
</Notification>''');

      expect(records, hasLength(1));
      expect(records.first['eventName'], 's3:ObjectCreated:Put');
      expect(records.first['key'], 'photos/2019/');
    });

    test('#6 a payload that is neither JSON nor XML yields no records', () {
      expect(parseNotificationRecords('not a payload'), isEmpty);
      expect(parseNotificationRecords(''), isEmpty);
    });
  });

  group('upstream issue #38 and #43 - endpoint mapping', () {
    test('#38 an unmapped region keeps its regional host', () async {
      final seen = <Uri>[];
      final minio = _mockClient(
        (request) async {
          seen.add(request.url);
          return http.Response(
            '<?xml version="1.0"?><ListAllMyBucketsResult><Buckets/>'
            '</ListAllMyBucketsResult>',
            200,
          );
        },
        endPoint: 's3.amazonaws.com',
        region: 'ap-southeast-4',
      );

      await minio.listBuckets();

      // Upstream fell back to the global endpoint for every region it did not
      // know, and AWS rejects that with "the region is wrong; expecting
      // 'us-east-1'".
      expect(seen.single.host, 's3.ap-southeast-4.amazonaws.com');
    });
  });

  group('multipart listings', () {
    test('listParts parses the server response', () async {
      final minio = _mockClient((request) async {
        return http.Response('''
<?xml version="1.0" encoding="UTF-8"?>
<ListPartsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Bucket>bucket</Bucket>
  <Key>object</Key>
  <UploadId>upload-id</UploadId>
  <Initiator><ID>minio</ID><DisplayName>minio</DisplayName></Initiator>
  <Owner><ID>minio</ID><DisplayName>minio</DisplayName></Owner>
  <StorageClass>STANDARD</StorageClass>
  <PartNumberMarker>0</PartNumberMarker>
  <NextPartNumberMarker>1</NextPartNumberMarker>
  <MaxParts>1000</MaxParts>
  <IsTruncated>false</IsTruncated>
  <Part>
    <PartNumber>1</PartNumber>
    <LastModified>2024-01-01T00:00:00.000Z</LastModified>
    <ETag>"d41d8cd98f00b204e9800998ecf8427e"</ETag>
    <Size>11</Size>
  </Part>
</ListPartsResult>''', 200);
      }, region: 'us-east-1');

      final parts = await minio
          .listParts('bucket', 'object', 'upload-id')
          .toList();

      expect(parts, hasLength(1));
      expect(parts.first.partNumber, 1);
      expect(parts.first.size, 11);
    });

    test('listIncompleteUploads parses the server response', () async {
      final minio = _mockClient((request) async {
        if (request.url.query.contains('uploadId')) {
          return http.Response('''
<?xml version="1.0" encoding="UTF-8"?>
<ListPartsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Bucket>bucket</Bucket>
  <Key>object</Key>
  <UploadId>upload-id</UploadId>
  <NextPartNumberMarker>0</NextPartNumberMarker>
  <IsTruncated>false</IsTruncated>
</ListPartsResult>''', 200);
        }
        return http.Response('''
<?xml version="1.0" encoding="UTF-8"?>
<ListMultipartUploadsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Bucket>bucket</Bucket>
  <KeyMarker></KeyMarker>
  <UploadIdMarker></UploadIdMarker>
  <NextKeyMarker></NextKeyMarker>
  <NextUploadIdMarker></NextUploadIdMarker>
  <MaxUploads>1000</MaxUploads>
  <IsTruncated>false</IsTruncated>
  <Upload>
    <Key>object</Key>
    <UploadId>upload-id</UploadId>
    <Initiator><ID>minio</ID><DisplayName>minio</DisplayName></Initiator>
    <Owner><ID>minio</ID><DisplayName>minio</DisplayName></Owner>
    <StorageClass>STANDARD</StorageClass>
    <Initiated>2024-01-01T00:00:00.000Z</Initiated>
  </Upload>
</ListMultipartUploadsResult>''', 200);
      }, region: 'us-east-1');

      final uploads = await minio.listIncompleteUploads('bucket', '').toList();

      expect(uploads, hasLength(1));
      expect(uploads.first.upload?.uploadId, 'upload-id');
    });
  });

  group('integration', () {
    test('an incomplete upload is listed by the server', () async {
      final minio = getMinioClient();
      final bucket = uniqueName();
      await minio.makeBucket(bucket);

      try {
        await minio.initiateNewMultipartUpload(bucket, 'object', null);

        final uploads = await minio.listIncompleteUploads(bucket, '').toList();
        expect(
          uploads.any((upload) => upload.upload?.key == 'object'),
          isTrue,
          reason: 'the upload that was started has to show up in the listing',
        );
      } finally {
        await minio.removeBucket(bucket);
      }
    }, skip: minioServerAvailable ? null : minioServerSkipReason);

    test('statObject reports the size of a stored object', () async {
      final minio = getMinioClient();
      final bucket = uniqueName();
      final object = 'object.txt';
      await minio.makeBucket(bucket);

      try {
        await minio.putObject(
          bucket,
          object,
          Stream<Uint8List>.value(Uint8List.fromList('hello'.codeUnits)),
          size: 5,
        );

        final stat = await minio.statObject(bucket, object);
        expect(stat.size, 5);
      } finally {
        await minio.removeObject(bucket, object);
        await minio.removeBucket(bucket);
      }
    }, skip: minioServerAvailable ? null : minioServerSkipReason);
  });
}
