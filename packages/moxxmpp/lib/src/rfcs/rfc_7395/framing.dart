import 'package:moxxmpp/src/namespaces.dart';

/// Helpers for RFC 7395 framing ↔ classic RFC 6120 `<stream:stream>` so the
/// rest of moxxmpp can keep the TCP negotiation path.

/// Translate an outbound moxxmpp stream string to a WebSocket frame body.
///
/// Returns `null` when [data] should not be sent (empty / XML declaration only).
String? streamToWebsocketFrame(String data, {String? defaultTo}) {
  var s = data.trim();
  if (s.isEmpty) return null;

  // Drop XML declaration that TCP streams include.
  s = s.replaceFirst(RegExp(r'<\?xml[^?]*\?>'), '').trim();
  if (s.isEmpty) return null;

  if (s.contains('<stream:stream') ||
      (s.startsWith('<stream') && s.contains(streamXmlns))) {
    final to = _attr(s, 'to') ?? defaultTo ?? '';
    return '<open xmlns="$xmppFramingXmlns" to="${_esc(to)}" version="1.0"/>';
  }

  if (s == '</stream:stream>' || s.contains('</stream:stream>')) {
    return '<close xmlns="$xmppFramingXmlns"/>';
  }

  return s;
}

/// Translate an inbound WebSocket frame to what moxxmpp's stream parser expects.
///
/// Returns `null` when the frame was a framing `<close/>` (caller should close).
/// For framing `<open/>`, returns a synthesised `<stream:stream …>` header.
String? websocketFrameToStream(String raw, {String? defaultFrom}) {
  final text = raw.trim();
  if (text.isEmpty) return '';

  if (_isFramingOpen(text)) {
    final from = _attr(text, 'from') ?? defaultFrom ?? '';
    final id = _attr(text, 'id');
    final idAttr = id == null ? '' : " id='${_esc(id)}'";
    return "<stream:stream xmlns='$stanzaXmlns' xmlns:stream='$streamXmlns' "
        "from='${_esc(from)}' version='1.0' xml:lang='en'$idAttr>";
  }

  if (_isFramingClose(text)) {
    return null;
  }

  return text;
}

/// `see-other-uri` from a framing `<close/>`, if present.
String? framingSeeOtherUri(String raw) => _attr(raw.trim(), 'see-other-uri');

bool _isFramingOpen(String s) =>
    s.contains(xmppFramingXmlns) && (s.contains('<open') || s.contains(':open'));

bool _isFramingClose(String s) =>
    s.contains(xmppFramingXmlns) &&
    (s.contains('<close') || s.contains(':close'));

String? _attr(String xml, String name) {
  final re = RegExp("$name=['\"]([^'\"]*)['\"]");
  return re.firstMatch(xml)?.group(1);
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll("'", '&apos;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
