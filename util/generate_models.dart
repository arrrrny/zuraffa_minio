/// The generator of the S3 models of this package.
///
/// It reads the API documentation of Amazon S3 and writes
/// `lib/src/minio_models_generated.dart`.
///
/// The committed file does not come out of this generator alone: it is the
/// file of the upstream package with the changes of this fork, and the
/// generator writes the models of the documentation.
///
/// The models of the notification configuration are the ones the generator
/// writes in a shape of its own, because the shape of the API is not the one
/// of the types the documentation describes: the configurations are the
/// direct children of the notification configuration, the events are one
/// `<Event>` element per event, and the destination is written `<Queue>`,
/// `<Topic>` and `<CloudFunction>`.
library;

import 'dart:io';

import 'package:html/dom.dart' show Element;
import 'package:html/parser.dart' show parse;
import 'package:http/http.dart' as http;

/// The header of the generated file.
///
/// The header holds the helpers every model uses. They are written so that
/// the code of the models compiles: `getProp` returns a nullable element,
/// because a document does not have to hold the element that is asked for.
///
/// The header is the beginning of the committed file as well, so the two
/// cannot drift apart: `test/generator_test.dart` checks it.
const String header = '''
// ignore_for_file: require_trailing_commas, deprecated_member_use

import 'package:xml/xml.dart';

XmlElement? getProp(XmlElement? xml, String name) {
  if (xml == null) return null;
  final result = xml.findElements(name);
  return result.isNotEmpty ? result.first : null;
}

/// The `<Xxxs>` element of a model holds one child element per item.
List<T>? listFromXml<T>(
  XmlElement? xml,
  String itemName,
  T Function(XmlElement? xml) parse,
) {
  if (xml == null) return null;
  final items = <T>[];
  for (final child in xml.findElements(itemName)) {
    items.add(parse(child));
  }
  return items;
}

/// The events of a notification configuration are one `<Event>` element per
/// event, directly under the configuration. A server that writes them as the
/// text of a single `<Events>` element is read as well.
List<String>? eventsFromXml(XmlElement? xml) {
  if (xml == null) return null;
  final events = <String>[];
  for (final event in xml.findElements('Event')) {
    events.add(event.text);
  }
  if (events.isEmpty) {
    final wrapper = getProp(xml, 'Events');
    if (wrapper != null) {
      for (final event in wrapper.findElements('Event')) {
        events.add(event.text);
      }
      if (events.isEmpty) {
        final text = wrapper.text.trim();
        if (text.isNotEmpty) {
          events.add(text);
        }
      }
    }
  }
  return events;
}

/// The configurations of a notification configuration are the direct children
/// of the `<NotificationConfiguration>` element, one element per
/// configuration.
///
/// A server that wraps them in an element of their own is read as well, so a
/// document written by an older version of this package is not lost.
List<T>? configurationsFromXml<T>(
  XmlElement? xml,
  String elementName,
  T Function(XmlElement? xml) parse, {
  String? wrapperName,
  String? wrapperItemName,
}) {
  if (xml == null) return null;
  final configurations = <T>[];
  for (final child in xml.findElements(elementName)) {
    configurations.add(parse(child));
  }
  if (configurations.isEmpty && wrapperName != null) {
    final wrapper = getProp(xml, wrapperName);
    if (wrapper != null) {
      for (final child in wrapper.findElements(
        wrapperItemName ?? elementName,
      )) {
        configurations.add(parse(child));
      }
    }
  }
  return configurations;
}
''';

void main() async {
  final urls = await getAllModelUrls();
  final models = await Future.wait(urls.map(getModel));

  final result = '$header\n${models.join('\n')}';

  await File(
    'lib/src/minio_models_generated.dart',
  ).writeAsString('${result.trimRight()}\n');
}

const baseUrl = 'https://docs.aws.amazon.com/AmazonS3/latest/API';

Future<List<String>> getAllModelUrls() async {
  print('Getting Index.');
  const url = '$baseUrl/API_Types_Amazon_Simple_Storage_Service.html';
  final page = await http.get(Uri.parse(url));
  final document = parse(page.body);
  final urls = document.querySelectorAll('.listitem a');
  return urls
      .map<String>((a) => a.attributes['href']!.substring(2))
      .map((a) => '$baseUrl/$a')
      .toList();
}

Future<String> getModel(String url) async {
  print('Getting: $url.');
  final page = await http.get(Uri.parse(url));
  final document = parse(page.body);

  final name = document.querySelector('h1')!.text;
  final description = document
      .querySelector('#main-col-body p')!
      .text
      .replaceAll(RegExp(r'\s+'), ' ');

  final fields = <FieldSpec>[];
  for (var dt in document.querySelectorAll('dt')) {
    final name = dt.text.trim();
    final spec = parseField(name, dt.nextElementSibling!);
    fields.add(spec);
  }

  return generateModel(name, description, fields);
}

/// The code of one model.
///
/// Every field is nullable, so a document that does not hold it is read
/// without a bang. Every element is only written when the field has a value,
/// so a model that is half filled does not write empty elements into the
/// body of a request.
String generateModel(String name, String description, List<FieldSpec> fields) {
  final buffer = StringBuffer();
  buffer.writeln('/// $description');
  buffer.writeln('class $name {');
  buffer.writeln('  $name(');
  for (final field in fields) {
    buffer.writeln('      this.${field.dartName},');
  }
  buffer.writeln('  );');
  buffer.writeln('');

  buffer.writeln('  $name.fromXml(XmlElement? xml) {');
  for (final field in fields) {
    buffer.writeln('    ${field.dartName} = ${readValue(field)};');
  }
  buffer.writeln('  }');
  buffer.writeln('');

  buffer.writeln('  XmlNode toXml() {');
  buffer.writeln('    final builder = XmlBuilder();');
  buffer.writeln("    builder.element('$name', nest: () {");
  for (final field in fields) {
    _writeField(buffer, field);
  }
  buffer.writeln('    });');
  buffer.writeln('    return builder.buildDocument();');
  buffer.writeln('  }');
  buffer.writeln('');

  for (final field in fields) {
    buffer.writeln('  /// ${field.description}');
    buffer.writeln('  ${field.type.declaredType} ${field.dartName};');
    buffer.writeln('');
  }
  buffer.writeln('}');
  buffer.writeln('');

  return buffer.toString();
}

/// The expression that reads a field out of a document.
String readValue(FieldSpec field) {
  final element = field.name!;
  final type = field.type;

  if (isNotificationConfigurationList(field)) {
    // The configurations of a notification configuration are the direct
    // children of the notification configuration.
    final item = singularElementName(element);
    final buffer = StringBuffer();
    buffer.writeln('configurationsFromXml<${type.name}>(');
    buffer.writeln('      xml,');
    buffer.writeln("      '${elementNames[item] ?? item}',");
    buffer.writeln('      ${type.name}.fromXml,');
    buffer.writeln("      wrapperName: '$element',");
    if (item != (elementNames[item] ?? item)) {
      buffer.writeln("      wrapperItemName: '$item',");
    }
    buffer.write('    )');
    return buffer.toString();
  }

  if (isEventList(field)) {
    // The events are one `<Event>` element per event, directly under the
    // configuration.
    return 'eventsFromXml(xml)';
  }

  if (type.isArray && type.isObject) {
    return 'listFromXml<${type.name}>(\n'
        "      getProp(xml, '$element'),\n"
        "      '${itemElementName(element)}',\n"
        '      ${type.name}.fromXml,\n'
        '    )';
  }
  if (type.isArray) {
    return 'listFromXml<String>(\n'
        "      getProp(xml, '$element'),\n"
        "      '$element',\n"
        '      (item) => item?.text ?? \'\',\n'
        '    )';
  }
  switch (type.name) {
    case 'String':
      return readString(element);
    case 'int':
      return "int.tryParse(getProp(xml, '$element')?.text ?? '')";
    case 'bool':
      return "getProp(xml, '$element')?.text.toUpperCase() == 'TRUE'";
    case 'DateTime':
      return "DateTime.tryParse(getProp(xml, '$element')?.text ?? '')";
    default:
      return "${type.name}.fromXml(getProp(xml, '$element'))";
  }
}

/// The expression that reads a text out of a document.
///
/// The element on the wire is not always named after the property of the
/// model: the destination of a notification configuration is written
/// `<Queue>`, `<Topic>` and `<CloudFunction>`. The name an older version of
/// this package wrote is read as well, so nothing is lost.
String readString(String element) {
  final wireElement = elementNames[element];
  if (wireElement == null) {
    return "getProp(xml, '$element')?.text";
  }
  return "getProp(xml, '$wireElement')?.text ?? getProp(xml, '$element')?.text";
}

/// The code that writes a field into a document.
void _writeField(StringBuffer buffer, FieldSpec field) {
  final element = field.name!;
  final type = field.type;
  final name = field.dartName;

  if (isNotificationConfigurationList(field)) {
    // The configurations of a notification configuration are the direct
    // children of the notification configuration. A wrapper element is
    // ignored by the server, and the configuration is then silently lost.
    final item = singularElementName(element);
    buffer.writeln('    if ($name != null) {');
    buffer.writeln('      for (final configuration in $name!) {');
    buffer.writeln('        builder.element(');
    buffer.writeln("          '${elementNames[item] ?? item}',");
    buffer.writeln(
      '          nest: (configuration.toXml() as XmlDocument).rootElement.children,',
    );
    buffer.writeln('        );');
    buffer.writeln('      }');
    buffer.writeln('    }');
    return;
  }

  if (isEventList(field)) {
    // The events are one `<Event>` element per event.
    buffer.writeln('    if ($name != null) {');
    buffer.writeln('      for (final event in $name!) {');
    buffer.writeln("        builder.element('Event', nest: event);");
    buffer.writeln('      }');
    buffer.writeln('    }');
    return;
  }

  if (type.isArray && type.isObject) {
    buffer.writeln('    if ($name != null) {');
    buffer.writeln("      builder.element('$element', nest: () {");
    buffer.writeln('        for (final item in $name!) {');
    buffer.writeln("          builder.element('${itemElementName(element)}',");
    buffer.writeln('              nest: (item.toXml() as XmlDocument)');
    buffer.writeln('                  .rootElement');
    buffer.writeln('                  .children,');
    buffer.writeln('          );');
    buffer.writeln('        }');
    buffer.writeln('      });');
    buffer.writeln('    }');
    return;
  }

  if (type.isArray) {
    buffer.writeln('    if ($name != null) {');
    buffer.writeln("      builder.element('$element', nest: () {");
    buffer.writeln('        for (final item in $name!) {');
    buffer.writeln("          builder.element('$element', nest: item);");
    buffer.writeln('        }');
    buffer.writeln('      });');
    buffer.writeln('    }');
    return;
  }

  buffer.writeln('    if ($name != null) {');
  switch (type.name) {
    case 'String':
      buffer.writeln(
        "      builder.element('${elementNames[element] ?? element}', nest: $name);",
      );
      break;
    case 'int':
      buffer.writeln(
        "      builder.element('${elementNames[element] ?? element}', nest: $name!.toString());",
      );
      break;
    case 'bool':
      buffer.writeln(
        "      builder.element('${elementNames[element] ?? element}', nest: $name! ? 'TRUE' : 'FALSE');",
      );
      break;
    case 'DateTime':
      buffer.writeln(
        "      builder.element('${elementNames[element] ?? element}', nest: $name!.toIso8601String());",
      );
      break;
    default:
      // A nested model is written as its children: the builder cannot take a
      // whole document as the content of an element.
      buffer.writeln('      builder.element(');
      buffer.writeln("        '${elementNames[element] ?? element}',");
      buffer.writeln(
        '        nest: ($name!.toXml() as XmlDocument).rootElement.children,',
      );
      buffer.writeln('      );');
  }
  buffer.writeln('    }');
}

/// Whether the field holds the configurations of a notification
/// configuration.
///
/// They are the direct children of the `<NotificationConfiguration>` element;
/// a wrapper element is ignored by the server.
bool isNotificationConfigurationList(FieldSpec field) {
  return field.type.isArray &&
      field.type.isObject &&
      (field.name ?? '').endsWith('Configurations');
}

/// Whether the field holds the events of a notification configuration.
///
/// They are one `<Event>` element per event, directly under the
/// configuration.
bool isEventList(FieldSpec field) {
  return field.name == 'Events' && field.type.isArray;
}

/// The name of the element that holds one item of a list.
///
/// The AWS documents name the type of the items but not the element that
/// holds them. The element is the name of the field without its plural
/// `s`, which is how the API names it: `Objects` holds `Object` elements.
String itemElementName(String fieldName) {
  final singular = singularElementName(fieldName);
  return elementNames[singular] ?? singular;
}

/// The name of the element that holds one item, without the name the wire
/// format uses.
String singularElementName(String fieldName) {
  if (fieldName.endsWith('ies')) {
    return '${fieldName.substring(0, fieldName.length - 3)}y';
  }
  if (fieldName.endsWith('s')) {
    return fieldName.substring(0, fieldName.length - 1);
  }
  return fieldName;
}

/// The name of the element on the wire for a property of a model.
///
/// The documentation names the property of the model, and the element on the
/// wire is not always named the same: the destination of a notification
/// configuration is written `<Queue>`, `<Topic>` and `<CloudFunction>`, and
/// the configuration of a lambda function is written
/// `<CloudFunctionConfiguration>`.
const Map<String, String> elementNames = {
  'QueueArn': 'Queue',
  'TopicArn': 'Topic',
  'LambdaFunctionArn': 'CloudFunction',
  'LambdaFunctionConfiguration': 'CloudFunctionConfiguration',
};

class FieldSpec {
  String? name;
  String? dartName;
  String? source;
  String? description;
  bool? isRequired;
  late TypeSpec type;

  @override
  String toString() {
    return '<Field $name>';
  }
}

class TypeSpec {
  String? name;
  String? dartName;
  bool isObject = false;
  bool isArray = false;

  /// The type of the field as it is declared.
  ///
  /// Every field is nullable: a document does not have to hold it.
  String get declaredType {
    if (isArray) return 'List<$name>?';
    return '$name?';
  }

  @override
  String toString() {
    return '<TypeSpec $name>';
  }
}

String toCamelCase(String name) {
  return name.substring(0, 1).toLowerCase() + name.substring(1);
}

FieldSpec parseField(String name, Element dd) {
  final source = dd.text;
  final description = dd
      .querySelector('p')!
      .text
      .replaceAll(RegExp(r'\s+'), ' ');
  final isRequired = dd.text.contains('Required: Yes');
  var type = parseType(source);
  if (name == 'Events') {
    // The events of a notification configuration are one `<Event>` element
    // per event. The documentation does not name them as a list.
    type = TypeSpec()
      ..name = 'String'
      ..dartName = 'List<String>'
      ..isArray = true
      ..isObject = false;
  }

  return FieldSpec()
    ..name = name
    ..dartName = toCamelCase(name)
    ..source = source
    ..description = description
    ..isRequired = isRequired
    ..type = type;
}

TypeSpec parseType(String source) {
  if (source.contains('Type: Base64-encoded binary data object')) {
    return TypeSpec()..name = 'String';
  }

  const typeMap = {
    'Integer': 'int',
    'Long': 'int',
    'String': 'String',
    'strings': 'String',
    'Timestamp': 'DateTime',
    'Boolean': 'bool',
  };
  final pattern = RegExp(r'Type: (Array of |)(\w+)( data type|)');
  final match = pattern.firstMatch(source);
  if (match == null) {
    // A field whose type the documentation words in a way the generator does
    // not know is read as a string. The generator must not stop at the
    // first field it does not understand: the models that follow would be
    // missing from the file.
    stderr.writeln('unknown type "$source" - read as a string');
    return TypeSpec()..name = 'String';
  }

  final isArray = match.group(1)!.trim().isNotEmpty;
  final isObject = match.group(3)!.trim().isNotEmpty;
  final type = match.group(2);

  final dartType = isObject ? type : (typeMap[type] ?? 'String');
  final dartName = isArray ? 'List<$dartType>' : dartType;

  return TypeSpec()
    ..name = dartType
    ..dartName = dartName
    ..isObject = isObject
    ..isArray = isArray;
}
