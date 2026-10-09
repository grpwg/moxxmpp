import 'package:moxxmpp/src/jid.dart';
import 'package:moxxmpp/src/namespaces.dart';
import 'package:moxxmpp/src/stringxml.dart';
import 'package:omemo_dart/omemo_dart_axolotl.dart';

/// Convert the XML representation of an OMEMO bundle (spec short tags) into
/// an [AxolotlBundle]. Keys are expected as libsignal serialize() base64
/// (33-byte public keys with `0x05` prefix).
AxolotlBundle axolotlBundleFromXML(JID jid, int id, XMLNode bundle) {
  final xmlns = bundle.attributes['xmlns'] as String?;
  assert(
    xmlns == omemoXmlns || xmlns == emeOmemo || xmlns == null,
    'Unexpected bundle xmlns: $xmlns',
  );

  final spk = bundle.firstTag('spk') ?? bundle.firstTag('signedPreKeyPublic');
  if (spk == null) {
    throw FormatException('bundle missing signed prekey');
  }
  final spkId = int.parse(
    (spk.attributes['id'] ?? spk.attributes['signedPreKeyId'])! as String,
  );
  final spks =
      bundle.firstTag('spks') ??
      bundle.firstTag('signedPreKeySignature') ??
      bundle.firstTag('spsk');
  final ik = bundle.firstTag('ik') ?? bundle.firstTag('identityKey');
  if (spks == null || ik == null) {
    throw FormatException('bundle missing spks/ik');
  }

  final prekeys = <int, String>{};
  final section = bundle.firstTag('prekeys');
  if (section != null) {
    for (final pk in section.children) {
      if (pk.tag != 'pk' && pk.tag != 'preKeyPublic') continue;
      final idText =
          (pk.attributes['id'] ?? pk.attributes['preKeyId']) as String?;
      final pkId = int.tryParse(idText ?? '');
      if (pkId == null) continue;
      prekeys[pkId] = pk.innerText();
    }
  }

  return AxolotlBundle(
    jid: jid.toBare().toString(),
    deviceId: id,
    signedPreKeyId: spkId,
    signedPreKeyPublicEncoded: spk.innerText(),
    signedPreKeySignatureEncoded: spks.innerText(),
    identityKeyEncoded: ik.innerText(),
    preKeysEncoded: prekeys,
    registrationId: id,
  );
}

/// Spec-dialect (`urn:xmpp:omemo:2`) XML for an [AxolotlBundle].
XMLNode axolotlBundleToXML(AxolotlBundle bundle) {
  final prekeys = <XMLNode>[];
  for (final pk in bundle.preKeysEncoded.entries) {
    prekeys.add(
      XMLNode(
        tag: 'pk',
        attributes: <String, String>{'id': '${pk.key}'},
        text: pk.value,
      ),
    );
  }

  return XMLNode.xmlns(
    tag: 'bundle',
    xmlns: omemoXmlns,
    children: [
      XMLNode(
        tag: 'spk',
        attributes: <String, String>{'id': '${bundle.signedPreKeyId}'},
        text: bundle.signedPreKeyPublicEncoded,
      ),
      XMLNode(tag: 'spks', text: bundle.signedPreKeySignatureEncoded),
      XMLNode(tag: 'ik', text: bundle.identityKeyEncoded),
      XMLNode(tag: 'prekeys', children: prekeys),
    ],
  );
}
