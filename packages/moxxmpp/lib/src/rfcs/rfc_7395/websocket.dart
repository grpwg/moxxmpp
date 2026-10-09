import 'dart:async';

import 'package:logging/logging.dart';
import 'package:moxxmpp/src/rfcs/rfc_7395/framing.dart';
import 'package:moxxmpp/src/socket.dart';
import 'package:moxxmpp/src/xeps/xep_0156.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// RFC 7395 XMPP-over-WebSocket as a [BaseSocketWrapper].
///
/// Translates framing ↔ `<stream:stream>` at the socket edge so negotiators
/// stay on the RFC 6120 code path.
class WebSocketXmppSocket extends BaseSocketWrapper {
  WebSocketXmppSocket({this.preferredUrl});

  /// Explicit `wss://` / `ws://` URL, or null to discover via XEP-0156.
  final String? preferredUrl;

  final _log = Logger('WebSocketXmppSocket');
  final _data = StreamController<String>.broadcast();
  final _events = StreamController<XmppSocketEvent>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  bool _secure = false;
  bool _expectClose = false;
  String? _domain;

  @override
  Stream<String> getDataStream() => _data.stream;

  @override
  Stream<XmppSocketEvent> getEventStream() => _events.stream;

  @override
  bool isSecure() => _secure;

  @override
  bool whitespacePingAllowed() => false;

  @override
  bool managesKeepalives() => true;

  @override
  Future<bool> secure(String domain) async {
    // TLS is at the WSS layer; nothing to upgrade.
    return _secure;
  }

  @override
  void prepareDisconnect() {
    _expectClose = true;
  }

  @override
  void close() {
    _expectClose = true;
    _teardown();
  }

  void _teardown() {
    try {
      _channel?.sink.close();
    } catch (_) {}
    unawaited(_sub?.cancel());
    _sub = null;
    _channel = null;
  }

  @override
  Future<bool> connect(String domain, {String? host, int? port}) async {
    _secure = false;
    _domain = domain;
    _teardown();
    _expectClose = false;

    // [host] may carry a full WebSocket URL from the login "host" field.
    final preferred =
        (host != null && (host.startsWith('wss:') || host.startsWith('ws:')))
        ? host
        : preferredUrl;

    final url = await resolveWebsocketUrl(domain, preferredUrl: preferred);
    if (url == null || url.isEmpty) {
      _log.severe('no WebSocket URL for $domain');
      return false;
    }

    _log.info('connecting WebSocket $url (domain=$domain)');
    try {
      final uri = Uri.parse(url);
      final channel = WebSocketChannel.connect(uri, protocols: const ['xmpp']);
      await channel.ready;
      _channel = channel;
      _secure = uri.scheme == 'wss';
      _sub = channel.stream.listen(
        _onMessage,
        onError: (Object error) {
          _log.severe('WebSocket error: $error');
          _events.add(XmppSocketErrorEvent(error));
        },
        onDone: () {
          _events.add(XmppSocketClosureEvent(_expectClose));
          _expectClose = false;
        },
      );
      return true;
    } catch (e, st) {
      _log.severe('WebSocket connect failed: $e', e, st);
      _teardown();
      return false;
    }
  }

  @override
  void write(String data) {
    final channel = _channel;
    if (channel == null) {
      _log.warning('write ignored: socket not connected');
      return;
    }
    final wire = streamToWebsocketFrame(data, defaultTo: _domain);
    if (wire == null || wire.isEmpty) return;
    _log.finest('==> $wire');
    channel.sink.add(wire);
  }

  void _onMessage(dynamic message) {
    final raw = message is String
        ? message
        : (message is List<int> ? String.fromCharCodes(message) : '$message');
    _log.finest('<== $raw');

    final translated = websocketFrameToStream(raw, defaultFrom: _domain);
    if (translated == null) {
      final other = framingSeeOtherUri(raw);
      if (other != null) {
        _log.warning('WebSocket see-other-uri=$other (not followed yet)');
      }
      _expectClose = true;
      close();
      return;
    }
    if (translated.isEmpty) return;
    _data.add(translated);
  }
}
