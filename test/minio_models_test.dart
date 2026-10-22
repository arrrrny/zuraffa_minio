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
    // The shape a server sends: the configurations are the direct children
    // of the notification configuration, the events are one element per
    // event and the destination is written `<Queue>`.
    const configuration = '''
<NotificationConfiguration>
  <CloudFunctionConfiguration>
    <Id>the-id</Id>
    <CloudFunction>arn:aws:lambda:eu-central-1:1:function:f</CloudFunction>
    <Event>s3:ObjectCreated:*</Event>
    <Event>s3:ObjectRemoved:*</Event>
  </CloudFunctionConfiguration>
  <QueueConfiguration>
    <Id>the-queue</Id>
    <Queue>arn:aws:sqs:eu-central-1:1:q</Queue>
    <Event>s3:ObjectCreated:*</Event>
  </QueueConfiguration>
</NotificationConfiguration>''';

    // The shape an older version of this package wrote: the configurations
    // are wrapped in an element of their own, the events are the children of
    // an `<Events>` element and the destination is written `<QueueArn>`.
    const legacyConfiguration = '''
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

    test('is read out of the shape a server sends', () {
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

    test('is read out of the shape an older version wrote', () {
      final xml = XmlDocument.parse(legacyConfiguration);
      final parsed = NotificationConfiguration.fromXml(xml.rootElement);

      expect(parsed.lambdaFunctionConfigurations, hasLength(1));
      expect(
        parsed.lambdaFunctionConfigurations!.first.lambdaFunctionArn,
        'arn:aws:lambda:eu-central-1:1:function:f',
      );
      expect(parsed.lambdaFunctionConfigurations!.first.events, [
        's3:ObjectCreated:*',
        's3:ObjectRemoved:*',
      ]);

      expect(parsed.queueConfigurations, hasLength(1));
      expect(
        parsed.queueConfigurations!.first.queueArn,
        'arn:aws:sqs:eu-central-1:1:q',
      );
      expect(parsed.queueConfigurations!.first.events, ['s3:ObjectCreated:*']);
    });

    test('is written back in the shape the server expects', () {
      final parsed = NotificationConfiguration.fromXml(
        XmlDocument.parse(configuration).rootElement,
      );

      final xml = parsed.toXml().toXmlString();

      // The configurations are the direct children of the notification
      // configuration. A wrapper element is ignored by the server, and the
      // configuration is then silently lost.
      expect(xml, contains('<CloudFunctionConfiguration>'));
      expect(xml, contains('<QueueConfiguration>'));
      expect(xml, isNot(contains('<QueueConfigurations>')));
      // The events are one element per event, not the text of one element.
      expect(xml, contains('<Event>s3:ObjectCreated:*</Event>'));
      expect(xml, contains('<Event>s3:ObjectRemoved:*</Event>'));
      expect(xml, isNot(contains('<Events>')));
      // The destination is written the way the server names it.
      expect(xml, contains('<Queue>arn:aws:sqs:eu-central-1:1:q</Queue>'));
      expect(
        xml,
        contains(
          '<CloudFunction>arn:aws:lambda:eu-central-1:1:function:f'
          '</CloudFunction>',
        ),
      );
      // The configuration must not be written twice.
      expect('<QueueConfiguration>'.allMatches(xml).length, 1);
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
      expect(
        again.queueConfigurations!.first.queueArn,
        'arn:aws:sqs:eu-central-1:1:q',
      );
      expect(again.queueConfigurations!.first.events, ['s3:ObjectCreated:*']);
    });
  });
}
