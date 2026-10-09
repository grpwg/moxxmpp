import 'package:moxxmpp/moxxmpp.dart';
import 'package:test/test.dart';

void main() {
  group('parseHostMetaXrd', () {
    test('extracts wss websocket and https bosh like converse.js', () {
      const xrd = '''
<?xml version="1.0" encoding="UTF-8"?>
<XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0">
  <Link rel="urn:xmpp:alt-connections:xbosh"
        href="https://example.org/http-bind"/>
  <Link rel="urn:xmpp:alt-connections:websocket"
        href="wss://example.org:443/xmpp-websocket"/>
  <Link rel="urn:xmpp:alt-connections:websocket"
        href="ws://insecure.example.org/xmpp-websocket"/>
</XRD>
''';
      final alt = parseHostMetaXrd(xrd);
      expect(alt.websocketUrls, [
        'wss://example.org:443/xmpp-websocket',
        'ws://insecure.example.org/xmpp-websocket',
      ]);
      expect(alt.boshUrls, ['https://example.org/http-bind']);
      // Prefer last wss: (converse.js .pop() on filtered wss list).
      expect(alt.preferredWebsocketUrl, 'wss://example.org:443/xmpp-websocket');
    });

    test('rejects wrong root', () {
      final alt = parseHostMetaXrd('<html></html>');
      expect(alt.websocketUrls, isEmpty);
    });
  });

  group('RFC 7395 framing', () {
    test('stream header becomes open frame', () {
      final wire = streamToWebsocketFrame(
        "<?xml version='1.0'?><stream:stream xmlns='jabber:client' "
        "xmlns:stream='http://etherx.jabber.org/streams' to='example.org' "
        "version='1.0'>",
      );
      expect(
        wire,
        '<open xmlns="urn:ietf:params:xml:ns:xmpp-framing" '
        'to="example.org" version="1.0"/>',
      );
    });

    test('open frame becomes stream header', () {
      final stream = websocketFrameToStream(
        '<open xmlns="urn:ietf:params:xml:ns:xmpp-framing" '
        'from="example.org" id="abc" version="1.0"/>',
      );
      expect(stream, contains('<stream:stream'));
      expect(stream, contains("from='example.org'"));
      expect(stream, contains("id='abc'"));
    });
  });
}
