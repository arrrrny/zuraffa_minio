import 'package:test/test.dart';
import 'package:xml/xml.dart';
import 'package:zuraffa_minio/models.dart';

void main() {
  final date = DateTime.utc(2017, 8, 11, 19, 34, 18);
  final dateString = 'Fri, 11 Aug 2017 19:34:18 GMT';

  test('CopyConditions.setModified() works', () {
    final cc = CopyConditions();
    cc.setModified(date);
    expect(cc.modified, equals(dateString));
  });

  test('CopyConditions.setUnmodified() works', () {
    final cc = CopyConditions();
    cc.setUnmodified(date);
    expect(cc.unmodified, dateString);
  });

  group('the optional elements of a model', () {
    test('an expiration with days has no date', () {
      // S3 sends either a date or a number of days, never both. Reading the
      // one that is not there must not throw.
      final xml = XmlDocument.parse('''
<LifecycleConfiguration>
  <Rule>
    <ID>expire</ID>
    <Expiration>
      <Days>30</Days>
    </Expiration>
    <Status>Enabled</Status>
  </Rule>
</LifecycleConfiguration>''');

      final expiration = LifecycleExpiration.fromXml(
        xml.rootElement.getElement('Rule')!.getElement('Expiration'),
      );

      expect(expiration.days, 30);
      expect(expiration.date, isNull);
    });

    test('an expiration with a date has no days', () {
      final xml = XmlDocument.parse('''
<LifecycleConfiguration>
  <Rule>
    <Expiration>
      <Date>2024-01-01T00:00:00.000Z</Date>
    </Expiration>
  </Rule>
</LifecycleConfiguration>''');

      final expiration = LifecycleExpiration.fromXml(
        xml.rootElement.getElement('Rule')!.getElement('Expiration'),
      );

      expect(expiration.date, isNotNull);
      expect(expiration.days, isNull);
    });
  });

  group('a notification configuration', () {
    const configuration = '''
<NotificationConfiguration>
  <LambdaFunctionConfigurations>
    <LambdaFunctionConfiguration>
      <Id>the-id</Id>
      <LambdaFunctionArn>arn:aws:lambda:eu-central-1:1:function:f</LambdaFunctionArn>
      <Events>
        <Event>s3:ObjectCreated:*</Event>
        <Event>s3:ObjectRemoved:*</Event>
      </Events>
    </LambdaFunctionConfiguration>
  </LambdaFunctionConfigurations>
  <QueueConfigurations>
    <QueueConfiguration>
      <Id>the-queue</Id>
      <QueueArn>arn:aws:sqs:eu-central-1:1:q</QueueArn>
      <Events>
        <Event>s3:ObjectCreated:*</Event>
      </Events>
    </QueueConfiguration>
  </QueueConfigurations>
</NotificationConfiguration>''';

    test('is read out of the wrapper elements', () {
      final xml = XmlDocument.parse(configuration);
      final parsed = NotificationConfiguration.fromXml(xml.rootElement);

      expect(parsed.lambdaFunctionConfigurations, hasLength(1));
      final lambda = parsed.lambdaFunctionConfigurations!.first;
      expect(lambda.id, 'the-id');
      expect(
        lambda.lambdaFunctionArn,
        'arn:aws:lambda:eu-central-1:1:function:f',
      );
      expect(lambda.events, ['s3:ObjectCreated:*', 's3:ObjectRemoved:*']);

      expect(parsed.queueConfigurations, hasLength(1));
      final queue = parsed.queueConfigurations!.first;
      expect(queue.id, 'the-queue');
      expect(queue.queueArn, 'arn:aws:sqs:eu-central-1:1:q');
      expect(queue.events, ['s3:ObjectCreated:*']);
    });

    test('is written back in the shape the server expects', () {
      final parsed = NotificationConfiguration.fromXml(
        XmlDocument.parse(configuration).rootElement,
      );

      final xml = parsed.toXml().toXmlString();

      expect(xml, contains('<LambdaFunctionConfigurations>'));
      expect(xml, contains('<LambdaFunctionConfiguration>'));
      expect(xml, contains('<Event>s3:ObjectCreated:*</Event>'));
      expect(xml, contains('<QueueConfigurations>'));
      expect(xml, contains('<QueueConfiguration>'));
      // The configuration must not be written twice.
      expect('<LambdaFunctionConfiguration>'.allMatches(xml).length, 1);
    });

    test('is read back what it wrote', () {
      final parsed = NotificationConfiguration.fromXml(
        XmlDocument.parse(configuration).rootElement,
      );

      final again = NotificationConfiguration.fromXml(
        XmlDocument.parse(parsed.toXml().toXmlString()).rootElement,
      );

      expect(again.lambdaFunctionConfigurations, hasLength(1));
      expect(
        again.lambdaFunctionConfigurations!.first.lambdaFunctionArn,
        'arn:aws:lambda:eu-central-1:1:function:f',
      );
      expect(again.lambdaFunctionConfigurations!.first.events, [
        's3:ObjectCreated:*',
        's3:ObjectRemoved:*',
      ]);
      expect(again.queueConfigurations, hasLength(1));
    });
  });
}
