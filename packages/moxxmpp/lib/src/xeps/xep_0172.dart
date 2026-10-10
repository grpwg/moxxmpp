// XEP-0172: User Nickname (PEP node http://jabber.org/protocol/nick).
// Conversations NickManager.publish.

import 'package:moxlib/moxlib.dart';
import 'package:moxxmpp/src/jid.dart';
import 'package:moxxmpp/src/managers/base.dart';
import 'package:moxxmpp/src/managers/namespaces.dart';
import 'package:moxxmpp/src/namespaces.dart';
import 'package:moxxmpp/src/stringxml.dart';
import 'package:moxxmpp/src/xeps/xep_0060/errors.dart';
import 'package:moxxmpp/src/xeps/xep_0060/xep_0060.dart';

abstract class NickError {}

class UnknownNickError extends NickError {}

/// Publishes / fetches the User Nickname PEP node (XEP-0172).
class NickManager extends XmppManagerBase {
  NickManager() : super(nickManager);

  PubSubManager get _pubsub =>
      getAttributes().getManagerById(pubsubManager)! as PubSubManager;

  @override
  List<String> getDiscoFeatures() => ['$nickXmlns+notify'];

  @override
  Future<bool> isSupported() async => true;

  /// Publish [name] as our nickname (empty → delete node content via empty nick).
  ///
  /// Conversations uses `access_model=presence` (`NodeConfiguration.PRESENCE`).
  Future<Result<NickError, bool>> publish(String name) async {
    final bare = getAttributes().getFullJID().toBare();
    final trimmed = name.trim();
    final result = await _pubsub.publish(
      bare,
      nickXmlns,
      XMLNode.xmlns(tag: 'nick', xmlns: nickXmlns, text: trimmed),
      id: 'current',
      options: const PubSubPublishOptions(accessModel: 'presence'),
    );
    if (result.isType<PubSubError>()) return Result(UnknownNickError());
    return const Result(true);
  }

  /// Latest nick for [jid], or null when none / error.
  Future<String?> fetch(JID jid) async {
    final result = await _pubsub.getItems(jid.toBare(), nickXmlns, maxItems: 1);
    if (result.isType<PubSubError>()) return null;
    final items = result.get<List<PubSubItem>>();
    if (items.isEmpty) return null;
    final nick = items.first.payload;
    if (nick.tag != 'nick') return null;
    final text = nick.innerText().trim();
    return text.isEmpty ? null : text;
  }
}
