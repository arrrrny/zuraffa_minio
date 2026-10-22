import 'dart:io';

import 'package:test/test.dart';

import '../util/generate_models.dart';

FieldSpec _field(
  String name,
  String typeName, {
  bool isObject = false,
  bool isArray = false,
}) {
  final type = TypeSpec()
    ..name = typeName
    ..dartName = isArray ? 'List<$typeName>' : typeName
    ..isObject = isObject
    ..isArray = isArray;
  return FieldSpec()
    ..name = name
    ..dartName = name[0].toLowerCase() + name.substring(1)
    ..description = 'The $name of the thing.'
    ..isRequired = false
    ..type = type;
}

/// The stubs of the models a sample refers to.
const String _stubs = '''
class S3KeyFilter {
  S3KeyFilter.fromXml(XmlElement? xml);
  XmlNode toXml() {
    final builder = XmlBuilder();
    builder.element('S3KeyFilter');
    return builder.buildDocument();
  }
}

class ObjectIdentifier {
  ObjectIdentifier.fromXml(XmlElement? xml);
  XmlNode toXml() {
    final builder = XmlBuilder();
    builder.element('ObjectIdentifier');
    return builder.buildDocument();
  }
}
''';

void main() {
  test('the generator writes code that compiles', () {
    final code = generateModel('Sample', 'A sample model.', [
      _field('Name', 'String'),
      _field('Count', 'int'),
      _field('Enabled', 'bool'),
      _field('Created', 'DateTime'),
      _field('Filter', 'S3KeyFilter', isObject: true),
      _field('Objects', 'ObjectIdentifier', isObject: true, isArray: true),
      _field('AllowedHeaders', 'String', isArray: true),
    ]);

    final directory = Directory('test/.generated_check');
    directory.createSync(recursive: true);
    final file = File('${directory.path}/sample.dart');
    file.writeAsStringSync('''
$header
$_stubs
$code
void main() {
  final sample = Sample.fromXml(null);
  print(sample.toXml());
}
''');

    final result = Process.runSync(Platform.resolvedExecutable, [
      'run',
      file.path,
    ]);

    expect(
      result.exitCode,
      0,
      reason:
          'the generated code does not compile:\n'
          '${result.stdout}\n${result.stderr}',
    );

    directory.deleteSync(recursive: true);
  });

  test('the generator writes the nullable shape of the models', () {
    final code = generateModel('Sample', 'A sample model.', [
      _field('Name', 'String'),
      _field('Count', 'int'),
      _field('Created', 'DateTime'),
      _field('Filter', 'S3KeyFilter', isObject: true),
    ]);

    // The document does not have to hold every element of a model.
    expect(code, contains('Sample.fromXml(XmlElement? xml)'));
    expect(code, contains('String? name;'));
    expect(code, contains('int? count;'));
    expect(code, contains('DateTime? created;'));

    // A value that is not there is not written.
    expect(code, contains('if (name != null) {'));
    expect(code, contains('if (count != null) {'));

    // A number and a date are parsed out of a text that may be empty.
    expect(code, contains("int.tryParse(getProp(xml, 'Count')?.text ?? '')"));
    expect(
      code,
      contains("DateTime.tryParse(getProp(xml, 'Created')?.text ?? '')"),
    );

    // A nested model is written as its children.
    expect(code, contains('as XmlDocument).rootElement.children'));
  });

  test('the committed file starts with the header of the generator', () {
    // The file is named `_generated`: the helpers it uses must be the ones
    // the generator writes, or the two drift apart and a regeneration loses
    // the corrections.
    final committed = File(
      'lib/src/minio_models_generated.dart',
    ).readAsStringSync();

    expect(committed, startsWith(header));
  });

  group('the generator writes the notification configuration', () {
    test('with the elements the server reads', () {
      final code = generateModel('QueueConfiguration', 'A queue.', [
        _field('QueueArn', 'String'),
        _field('Id', 'String'),
        _field('Events', 'String', isArray: true),
      ]);

      // The destination is written `<Queue>`, and the name an older version
      // of this package wrote is read as well.
      expect(code, contains("getProp(xml, 'Queue')?.text"));
      expect(code, contains("getProp(xml, 'QueueArn')?.text"));
      expect(code, contains("builder.element('Queue', nest: queueArn)"));

      // The events are one `<Event>` element per event, directly under the
      // configuration.
      expect(code, contains('eventsFromXml(xml)'));
      expect(code, contains("builder.element('Event', nest: event)"));
      expect(code, contains('List<String>? events;'));
    });

    test('with the configurations as direct children', () {
      final code = generateModel('NotificationConfiguration', 'A config.', [
        _field(
          'QueueConfigurations',
          'QueueConfiguration',
          isObject: true,
          isArray: true,
        ),
      ]);

      // A wrapper element is ignored by the server, and the configuration is
      // then silently lost.
      expect(code, contains('configurationsFromXml<QueueConfiguration>'));
      expect(code, isNot(contains("builder.element('QueueConfigurations'")));
      expect(code, contains('builder.element('));
      expect(code, contains("'QueueConfiguration',"));
    });
  });
}
