import 'dart:convert';

import 'package:moxlib/moxlib.dart';
import 'package:moxxmpp/src/events.dart';
import 'package:moxxmpp/src/jid.dart';
import 'package:moxxmpp/src/managers/base.dart';
import 'package:moxxmpp/src/managers/data.dart';
import 'package:moxxmpp/src/managers/handlers.dart';
import 'package:moxxmpp/src/managers/namespaces.dart';
import 'package:moxxmpp/src/namespaces.dart';
import 'package:moxxmpp/src/stanza.dart';
import 'package:moxxmpp/src/stringxml.dart';

abstract class VCardError {}

class UnknownVCardError extends VCardError {}

class InvalidVCardError extends VCardError {}

class VCardPhoto {
  const VCardPhoto({this.binval});
  final String? binval;
}

class VCard {
  const VCard({this.nickname, this.url, this.photo});
  final String? nickname;
  final String? url;
  final VCardPhoto? photo;
}

class VCardManager extends XmppManagerBase {
  VCardManager() : super(vcardManager);
  final Map<String, String> _lastHash = {};

  @override
  List<StanzaHandler> getIncomingStanzaHandlers() => [
    StanzaHandler(
      stanzaTag: 'presence',
      tagName: 'x',
      tagXmlns: vCardTempUpdate,
      callback: _onPresence,
    ),
  ];

  @override
  Future<bool> isSupported() async => true;

  /// In case we get the avatar hash some other way.
  void setLastHash(String jid, String hash) {
    _lastHash[jid] = hash;
  }

  Future<StanzaHandlerData> _onPresence(
    Stanza presence,
    StanzaHandlerData state,
  ) async {
    final x = presence.firstTag('x', xmlns: vCardTempUpdate)!;
    final hash = x.firstTag('photo')!.innerText();

    getAttributes().sendEvent(
      VCardAvatarUpdatedEvent(JID.fromString(presence.from!), hash),
    );
    return state;
  }

  VCardPhoto? _parseVCardPhoto(XMLNode? node) {
    if (node == null) return null;

    return VCardPhoto(binval: node.firstTag('BINVAL')?.innerText());
  }

  VCard _parseVCard(XMLNode vcard) {
    final nickname = vcard.firstTag('NICKNAME')?.innerText();
    final url = vcard.firstTag('URL')?.innerText();

    return VCard(
      url: url,
      nickname: nickname,
      photo: _parseVCardPhoto(vcard.firstTag('PHOTO')),
    );
  }

  Future<Result<VCardError, VCard>> requestVCard(JID jid) async {
    // Plain IQ — same as publishPhoto / Conversations. Do not OMEMO-wrap
    // (MUC room vCards and many servers reject encrypted vCard-temp).
    final result = (await getAttributes().sendStanza(
      StanzaDetails(
        Stanza.iq(
          to: jid.toBare().toString(),
          type: 'get',
          children: [XMLNode.xmlns(tag: 'vCard', xmlns: vCardTempXmlns)],
        ),
        shouldEncrypt: false,
      ),
    ))!;

    if (result.attributes['type'] != 'result') {
      return Result(UnknownVCardError());
    }
    final vcard = result.firstTag('vCard', xmlns: vCardTempXmlns);
    if (vcard == null) {
      return Result(UnknownVCardError());
    }

    return Result(_parseVCard(vcard));
  }

  /// Publish a PHOTO on [address]'s vCard (Conversations `publishPhoto`).
  ///
  /// Used for MUC room avatars (`to=room@conference…`). Merges into an
  /// existing vCard when present; creates a fresh one on item-not-found.
  Future<Result<VCardError, bool>> publishPhoto(
    JID address,
    String type,
    List<int> imageBytes,
  ) async {
    final existing = await _requestVCardNode(address);
    final children = <XMLNode>[];
    if (existing != null) {
      for (final child in existing.children) {
        if (child.tag == 'PHOTO') continue;
        children.add(child);
      }
    }
    children.add(
      XMLNode(
        tag: 'PHOTO',
        children: [
          XMLNode(tag: 'TYPE', text: type),
          XMLNode(tag: 'BINVAL', text: base64Encode(imageBytes)),
        ],
      ),
    );

    final result = (await getAttributes().sendStanza(
      StanzaDetails(
        Stanza.iq(
          to: address.toBare().toString(),
          type: 'set',
          children: [
            XMLNode.xmlns(
              tag: 'vCard',
              xmlns: vCardTempXmlns,
              children: children,
            ),
          ],
        ),
        shouldEncrypt: false,
      ),
    ))!;

    if (result.attributes['type'] != 'result') {
      return Result(UnknownVCardError());
    }
    return const Result(true);
  }

  Future<XMLNode?> _requestVCardNode(JID jid) async {
    final result = await getAttributes().sendStanza(
      StanzaDetails(
        Stanza.iq(
          to: jid.toBare().toString(),
          type: 'get',
          children: [XMLNode.xmlns(tag: 'vCard', xmlns: vCardTempXmlns)],
        ),
        shouldEncrypt: false,
      ),
    );
    if (result == null || result.attributes['type'] != 'result') return null;
    return result.firstTag('vCard', xmlns: vCardTempXmlns);
  }
}
