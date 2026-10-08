import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:moxxmpp/src/namespaces.dart';
import 'package:xml/xml.dart';

final _log = Logger('Xep0156');

/// Result of XEP-0156 discovery for one domain.
class AltConnections {
  const AltConnections({
    this.websocketUrls = const [],
    this.boshUrls = const [],
  });

  final List<String> websocketUrls;
  final List<String> boshUrls;

  /// Prefer secure WebSocket (converse.js: last `wss:` link).
  String? get preferredWebsocketUrl {
    final wss = websocketUrls.where((u) => u.startsWith('wss:')).toList();
    if (wss.isNotEmpty) return wss.last;
    return null;
  }
}

/// Parse an XRD host-meta document (converse.js `onDomainDiscovered`).
AltConnections parseHostMetaXrd(String text) {
  final doc = XmlDocument.parse(text);
  final xrd = doc.rootElement;
  if (xrd.name.local != 'XRD') {
    return const AltConnections();
  }
  // Namespace is required by converse; tolerate missing NS for lenient servers.
  final ns = xrd.namespaceUri;
  if (ns != null && ns.isNotEmpty && ns != hostMetaXrdXmlns) {
    return const AltConnections();
  }

  final ws = <String>[];
  final bosh = <String>[];
  for (final link in xrd.findAllElements('Link')) {
    final rel = link.getAttribute('rel') ?? '';
    final href = link.getAttribute('href') ?? '';
    if (href.isEmpty) continue;
    if (rel == websocketAltConnectionsXmlns) {
      ws.add(href);
    } else if (rel == boshAltConnectionsXmlns) {
      bosh.add(href);
    }
  }
  return AltConnections(websocketUrls: ws, boshUrls: bosh);
}

/// Discover alternative connection methods for [domain] (XEP-0156).
///
/// Mirrors converse.js: only `https://{domain}/.well-known/host-meta`, XRD XML.
Future<AltConnections> discoverAltConnections(
  String domain, {
  http.Client? client,
}) async {
  final host = domain.trim().toLowerCase();
  if (host.isEmpty) return const AltConnections();

  final url = Uri.https(host, '/.well-known/host-meta');
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient.get(
      url,
      headers: const {'Accept': 'application/xrd+xml, text/xml'},
    );
    if (response.statusCode < 200 || response.statusCode >= 400) {
      _log.info('host-meta $url → HTTP ${response.statusCode}');
      return const AltConnections();
    }
    final parsed = parseHostMetaXrd(response.body);
    _log.info(
      'host-meta $host: ws=${parsed.websocketUrls} bosh=${parsed.boshUrls}',
    );
    return parsed;
  } catch (e) {
    _log.info('host-meta discovery failed for $host: $e');
    return const AltConnections();
  } finally {
    if (owned) httpClient.close();
  }
}

/// Resolve a WebSocket URL for [domain].
///
/// Order (converse-like):
/// 1. Explicit [preferredUrl] if it is `ws:` / `wss:`
/// 2. XEP-0156 `wss:` from host-meta
/// 3. Common Prosody default under [domain]
Future<String?> resolveWebsocketUrl(
  String domain, {
  String? preferredUrl,
  http.Client? client,
}) async {
  final explicit = preferredUrl?.trim();
  if (explicit != null &&
      (explicit.startsWith('wss:') || explicit.startsWith('ws:'))) {
    return explicit;
  }

  final discovered = await discoverAltConnections(domain, client: client);
  final fromMeta = discovered.preferredWebsocketUrl;
  if (fromMeta != null) return fromMeta;

  // Last-resort guess when host-meta is missing/mis-proxied.
  return 'wss://$domain/xmpp-websocket';
}
