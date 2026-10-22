import 'dart:async';
import 'dart:convert';

import 'package:xml/xml.dart' as xml;
import 'package:zuraffa_minio/src/minio_client.dart';

class NotificationPoller {
  NotificationPoller(
    this._client,
    this.bucket,
    this.prefix,
    this.suffix,
    this.events,
  );

  final MinioClient _client;
  final String bucket;
  final String? prefix;
  final String? suffix;
  final List<String>? events;

  final _eventStream = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get stream => _eventStream.stream;

  bool _stop = true;

  /// The key of the last delivered event.
  ///
  /// A listener re-requests the notification stream every time the server
  /// closes it, and the server happily replays the event it still has
  /// buffered. Without this guard every single event arrives twice.
  String? _lastEventKey;

  bool get isStarted {
    return !_stop;
  }

  /// Starts the polling.
  Future<void> start() async {
    _stop = false;
    while (!_stop) {
      await _checkForChanges();
    }
  }

  /// Stops the polling.
  void stop() {
    _stop = true;
  }

  Future<void> _checkForChanges() async {
    // Don't continue if we're looping again but are cancelled.
    if (_stop) return;

    final queries = {
      if (prefix != null) 'prefix': prefix,
      if (suffix != null) 'suffix': suffix,
      if (events != null) 'events': events,
    };

    final respStream = await _client.requestStream(
      method: 'GET',
      bucket: bucket,
      queries: queries,
    );

    await for (var resp in respStream.stream) {
      if (_stop) break;

      final chunk = utf8.decode(resp);
      if (chunk.trim().isEmpty) continue;

      for (final record in parseNotificationRecords(chunk)) {
        final key = eventKey(record);
        if (key != null) {
          if (key == _lastEventKey) continue;
          _lastEventKey = key;
        }
        _eventStream.add(record);
      }
    }
  }
}

/// Parses the payload of a bucket notification into event records.
///
/// Two wire formats are in the wild and both have to be understood:
///
/// * JSON - `{"Records": [ ... ]}` - what current MinIO servers send.
/// * XML - `<Notification><Event> ... </Event></Notification>` - what older
///   MinIO servers sent and what the reporter of upstream issue #6 ran into.
///   Upstream called `json.decode` on that payload and died with
///   `FormatException: Unexpected character (at character 1)`.
///
/// The XML variant comes in two flavours: the event itself is JSON inside an
/// `<Event>` element, or the event fields are plain XML child elements. Both
/// are handled.
List<Map<String, dynamic>> parseNotificationRecords(String payload) {
  final trimmed = payload.trim();
  if (trimmed.isEmpty) return const [];

  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    final decoded = _tryDecodeJson(trimmed);
    if (decoded != null) return _recordsFrom(decoded);
  }

  final xml.XmlDocument document;
  try {
    document = xml.XmlDocument.parse(trimmed);
  } on xml.XmlException {
    return const [];
  }

  final records = <Map<String, dynamic>>[];
  for (final event in document.findAllElements('Event')) {
    // Only the outermost event element carries the payload.
    final parent = event.parent;
    if (parent is xml.XmlElement && parent.name.local == 'Event') continue;

    final inner = event.innerText.trim();
    if (inner.isNotEmpty) {
      final decoded = _tryDecodeJson(inner);
      if (decoded != null) {
        records.addAll(_recordsFrom(decoded));
        continue;
      }
    }

    var found = false;
    for (final nested in event.findAllElements('Event')) {
      final text = nested.innerText.trim();
      if (text.isEmpty) continue;
      final decoded = _tryDecodeJson(text);
      if (decoded == null) continue;
      records.addAll(_recordsFrom(decoded));
      found = true;
    }
    if (found) continue;

    final map = _elementToMap(event);
    if (map.isNotEmpty) records.add(map);
  }

  return records;
}

/// A key that identifies an event, used to drop the replays a listener
/// receives when it re-opens the notification stream.
String? eventKey(Map<String, dynamic> record) {
  final s3 = record['s3'];
  if (s3 is Map) {
    final object = s3['object'];
    if (object is Map) {
      final sequencer = object['sequencer'];
      if (sequencer is String && sequencer.isNotEmpty) {
        return '${record['eventName']}/$sequencer';
      }
    }
  }
  final eventTime = record['eventTime'];
  if (eventTime is String && eventTime.isNotEmpty) {
    return '${record['eventName']}/$eventTime';
  }
  return null;
}

Object? _tryDecodeJson(String text) {
  try {
    return json.decode(text);
  } on FormatException {
    return null;
  }
}

List<Map<String, dynamic>> _recordsFrom(Object? decoded) {
  if (decoded is Map) {
    final records = decoded['Records'];
    if (records is List) {
      return records.whereType<Map>().map(_asStringKeys).toList();
    }
    return [_asStringKeys(decoded)];
  }
  if (decoded is List) {
    return decoded.whereType<Map>().map(_asStringKeys).toList();
  }
  return const [];
}

Map<String, dynamic> _asStringKeys(Map value) {
  return value.map((key, dynamic v) => MapEntry(key.toString(), v));
}

Map<String, dynamic> _elementToMap(xml.XmlElement element) {
  final map = <String, dynamic>{};
  for (final child in element.children.whereType<xml.XmlElement>()) {
    final hasChildren = child.children.whereType<xml.XmlElement>().isNotEmpty;
    map[child.name.local] = hasChildren
        ? _elementToMap(child)
        : child.innerText.trim();
  }
  if (map.isEmpty) {
    return {element.name.local: element.innerText.trim()};
  }
  return map;
}
