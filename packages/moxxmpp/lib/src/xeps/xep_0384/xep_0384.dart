import 'dart:async';
import 'dart:convert';
import 'package:meta/meta.dart';
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
import 'package:moxxmpp/src/xeps/xep_0030/errors.dart';
import 'package:moxxmpp/src/xeps/xep_0030/types.dart';
import 'package:moxxmpp/src/xeps/xep_0030/xep_0030.dart';
import 'package:moxxmpp/src/xeps/xep_0060/errors.dart';
import 'package:moxxmpp/src/xeps/xep_0060/xep_0060.dart';
import 'package:moxxmpp/src/xeps/xep_0045/xep_0045.dart';
import 'package:moxxmpp/src/xeps/xep_0280.dart';
import 'package:moxxmpp/src/xeps/xep_0334.dart';
import 'package:moxxmpp/src/xeps/xep_0380.dart';
import 'package:moxxmpp/src/xeps/xep_0384/errors.dart';
import 'package:moxxmpp/src/xeps/xep_0384/helpers.dart';
import 'package:moxxmpp/src/xeps/xep_0384/types.dart';
import 'package:omemo_dart/omemo_dart.dart' show NoKeyMaterialAvailableError;
import 'package:omemo_dart/omemo_dart_axolotl.dart' as axolotl;

/// Acquire the axolotl (OMEMO 0.3.0 / Conversations) manager.
typedef GetOmemoManagerCallback = Future<axolotl.AxolotlOmemoManager> Function();

/// Whether a stanza should be encrypted.
typedef ShouldEncryptStanzaCallback = Future<bool> Function(
  JID toJid,
  Stanza stanza,
);

const _doNotEncryptList = [
  DoNotEncrypt('addresses', extendedAddressingXmlns),
  DoNotEncrypt('pubsub', pubsubXmlns),
  DoNotEncrypt('pubsub', pubsubOwnerXmlns),
  DoNotEncrypt('no-permanent-store', messageProcessingHintsXmlns),
  DoNotEncrypt('no-store', messageProcessingHintsXmlns),
  DoNotEncrypt('no-copy', messageProcessingHintsXmlns),
  DoNotEncrypt('store', messageProcessingHintsXmlns),
  DoNotEncrypt('origin-id', stableIdXmlns),
  DoNotEncrypt('stanza-id', stableIdXmlns),
  DoNotEncrypt('encryption', emeXmlns),
  DoNotEncrypt('encrypted', emePomemo0),
  // XEP-0184 / XEP-0333 ride outside the ciphertext (Conversations).
  DoNotEncrypt('request', deliveryXmlns),
  DoNotEncrypt('received', deliveryXmlns),
  DoNotEncrypt('markable', chatMarkersXmlns),
  DoNotEncrypt('received', chatMarkersXmlns),
  DoNotEncrypt('displayed', chatMarkersXmlns),
  DoNotEncrypt('acknowledged', chatMarkersXmlns),
];

/// Conversations-compatible fallback body (axolotl / OMEMO 0.3.0).
const axolotlFallbackBody =
    "I sent you an OMEMO encrypted message but your client doesn't seem to "
    'support that. Find more information on https://conversations.im/omemo';

/// A-track OMEMO manager speaking Conversations axolotl on the wire
/// (`eu.siacs.conversations.axolotl`, AES-128-GCM, libsignal).
class OmemoManager extends XmppManagerBase {
  OmemoManager(this._getOmemoManager, this._shouldEncryptStanza)
      : super(omemoManager);

  final GetOmemoManagerCallback _getOmemoManager;
  final ShouldEncryptStanzaCallback _shouldEncryptStanza;

  @override
  Future<bool> isSupported() async => true;

  @override
  List<StanzaHandler> getIncomingPreStanzaHandlers() => [
        StanzaHandler(
          stanzaTag: 'iq',
          tagXmlns: emeOmemo,
          tagName: 'encrypted',
          callback: _onIncomingStanza,
        ),
        StanzaHandler(
          stanzaTag: 'presence',
          tagXmlns: emeOmemo,
          tagName: 'encrypted',
          callback: _onIncomingStanza,
        ),
        StanzaHandler(
          stanzaTag: 'message',
          tagXmlns: emeOmemo,
          tagName: 'encrypted',
          callback: _onIncomingStanza,
        ),
      ];

  @override
  List<StanzaHandler> getOutgoingPreStanzaHandlers() => [
        StanzaHandler(
          stanzaTag: 'iq',
          callback: _onOutgoingStanza,
        ),
        StanzaHandler(
          stanzaTag: 'presence',
          callback: _onOutgoingStanza,
        ),
        StanzaHandler(
          stanzaTag: 'message',
          callback: _onOutgoingStanza,
          priority: 100,
        ),
      ];

  @override
  Future<void> onXmppEvent(XmppEvent event) async {
    if (event is PubSubNotificationEvent) {
      // Spec devices node (secondary). Defacto notify is handled in the app.
      if (event.item.node != omemoDevicesXmlns) return;

      logger.finest('Received PubSub device notification for ${event.from}');
      final ownJid = getAttributes().getFullJID().toBare().toString();
      final jid = JID.fromString(event.from).toBare();
      final ids = event.item.payload.children
          .map((child) => int.parse(child.attributes['id']! as String))
          .toList();

      if (event.from == ownJid) {
        if (!ids.contains(await _getDeviceId())) {
          unawaited(publishBundle(await _getDeviceBundle()));
        }
      } else {
        logger.finest('Got devices $ids');
      }

      await (await _getOmemoManager()).onDeviceListUpdate(jid.toString(), ids);
      getAttributes().sendEvent(OmemoDeviceListUpdatedEvent(jid, ids));
    }
  }

  Future<int> _getDeviceId() async => (await _getOmemoManager()).getDeviceId();

  Future<axolotl.AxolotlBundle> _getDeviceBundle() async {
    final om = await _getOmemoManager();
    return om.getLocalBundle();
  }

  @visibleForOverriding
  bool shouldEncryptElement(XMLNode element) {
    for (final ignore in _doNotEncryptList) {
      final xmlns = element.attributes['xmlns'] ?? '';
      if (element.tag == ignore.tag &&
          (ignore.xmlns.isEmpty || xmlns == ignore.xmlns)) {
        return false;
      }
    }
    return true;
  }

  XMLNode _buildEncryptedElement(
    axolotl.AxolotlEncryptionResult result,
    int deviceId,
  ) {
    final keyChildren = <XMLNode>[];
    for (final entry in result.encryptedKeys.entries) {
      for (final ek in entry.value) {
        keyChildren.add(
          XMLNode(
            tag: 'key',
            attributes: {
              'rid': ek.rid.toString(),
              if (ek.prekey) 'prekey': 'true',
            },
            text: ek.value,
          ),
        );
      }
    }

    final headerChildren = <XMLNode>[
      ...keyChildren,
      if (result.iv != null)
        XMLNode(
          tag: 'iv',
          text: base64Encode(result.iv!),
        ),
    ];

    return XMLNode.xmlns(
      tag: 'encrypted',
      xmlns: emeOmemo,
      children: [
        if (result.ciphertext != null)
          XMLNode(
            tag: 'payload',
            text: base64Encode(result.ciphertext!),
          ),
        XMLNode(
          tag: 'header',
          attributes: <String, String>{
            'sid': deviceId.toString(),
          },
          children: headerChildren,
        ),
      ],
    );
  }

  Future<void> sendEmptyMessageImpl(
    axolotl.AxolotlEncryptionResult result,
    String toJid,
  ) async {
    await getAttributes().sendStanza(
      StanzaDetails(
        Stanza.message(
          to: toJid,
          type: 'chat',
          children: [
            _buildEncryptedElement(result, await _getDeviceId()),
            MessageProcessingHint.store.toXML(),
          ],
        ),
        awaitable: false,
        encrypted: true,
      ),
    );
  }

  Future<void> sendOmemoHeartbeat(String jid) async {
    final om = await _getOmemoManager();
    final result = await om.onOutgoingStanza(
      axolotl.AxolotlOutgoingStanza(
        recipientJids: [jid],
        payload: null,
      ),
    );
    if (result.canSend) {
      await sendEmptyMessageImpl(result, jid);
    }
  }

  Future<List<int>?> fetchDeviceList(String jid) async {
    final result = await getDeviceList(JID.fromString(jid));
    if (result.isType<OmemoError>()) return null;
    return result.get<List<int>>();
  }

  Future<axolotl.AxolotlBundle?> fetchDeviceBundle(String jid, int id) async {
    final result = await retrieveDeviceBundle(JID.fromString(jid), id);
    if (result.isType<OmemoError>()) return null;
    return result.get<axolotl.AxolotlBundle>();
  }

  Future<StanzaHandlerData> _onOutgoingStanza(
    Stanza stanza,
    StanzaHandlerData state,
  ) async {
    if (!state.shouldEncrypt) {
      logger.finest('Not encrypting since state.shouldEncrypt is false');
      return state;
    }
    if (state.encrypted) {
      logger.finest('Not encrypting since state.encrypted is true');
      return state;
    }
    if (stanza.to == null) {
      logger.finest('Not encrypting since stanza.to is null');
      return state;
    }

    final toJid = JID.fromString(stanza.to!).toBare();
    final shouldEncryptResult = await _shouldEncryptStanza(toJid, stanza);
    if (!shouldEncryptResult && !state.forceEncryption) {
      logger.finest(
        'Not encrypting stanza for $toJid: Both shouldEncryptStanza and forceEncryption are false.',
      );
      return state;
    }

    // Conversations encrypts the chat body only; other children stay in the
    // clear (receipts, chat states, …). The original <body> is removed and
    // replaced with a fallback after encryption.
    final children = <XMLNode>[];
    String? bodyText;
    for (final child in stanza.children) {
      if (child.tag == 'body') {
        bodyText = child.innerText();
        continue;
      }
      if (!shouldEncryptElement(child)) {
        children.add(child);
      }
      // Non-body encryptable children are dropped from the cleartext stanza
      // (axolotl has no SCE envelope for them).
    }

    // No body → not a content message (e.g. XEP-0085 chat state). Encrypting
    // those as empty OMEMO makes peers show an undecryptable phantom bubble.
    // Heartbeats use forceEncryption and build the element themselves.
    if (bodyText == null && !state.forceEncryption) {
      logger.finest('Not encrypting body-less message stanza');
      return state;
    }

    logger.finest('Beginning axolotl encryption');
    final carbonsEnabled = getAttributes()
            .getManagerById<CarbonsManager>(carbonsManager)
            ?.isEnabled ??
        false;
    final om = await _getOmemoManager();
    final ownBare = getAttributes().getFullJID().toBare().toString();
    // MUC (Conversations): keys for every member real JID; stanza.to is the
    // room and must not be treated as an OMEMO peer.
    final override = state.omemoRecipientJids;
    final encryptToJids = override != null && override.isNotEmpty
        ? <String>{
            ...override,
            ownBare,
          }.toList()
        : [
            toJid.toString(),
            if (carbonsEnabled) ownBare,
          ];
    final plaintext = bodyText != null ? utf8.encode(bodyText) : null;
    final result = await om.onOutgoingStanza(
      axolotl.AxolotlOutgoingStanza(
        recipientJids: encryptToJids,
        payload: plaintext,
      ),
    );
    logger.finest('Axolotl encryption done');

    if (!result.canSend) {
      // Prefer an error against the primary peer; for MUC any recipient error.
      final ownErrors = result.deviceEncryptionErrors[toJid.toString()] ??
          (override != null && override.isNotEmpty
              ? result.deviceEncryptionErrors[override.first]
              : null);
      return state
        ..cancel = true
        ..cancelReason = ownErrors != null &&
                ownErrors.first.error is NoKeyMaterialAvailableError
            ? OmemoNotSupportedForContactException()
            : UnknownOmemoError()
        ..encryptionError = OmemoEncryptionError(
          result.deviceEncryptionErrors,
        );
    }

    children
      ..add(
        XMLNode(
          tag: 'body',
          text: axolotlFallbackBody,
        ),
      )
      ..add(_buildEncryptedElement(result, await _getDeviceId()));

    if (stanza.tag == 'message') {
      children
        ..add(ExplicitEncryptionType.omemo.toXML(name: 'OMEMO'))
        ..add(MessageProcessingHint.store.toXML());
    }

    return state
      ..stanza = state.stanza.copyWith(children: children)
      ..encrypted = true;
  }

  Future<StanzaHandlerData> _onIncomingStanza(
    Stanza stanza,
    StanzaHandlerData state,
  ) async {
    if (stanza.from == null) return state;

    final encrypted = stanza.firstTag('encrypted', xmlns: emeOmemo)!;
    final fromFull = JID.fromString(stanza.from!);
    // Conversations MessageParser: groupchat OMEMO uses the occupant's real
    // JID as the ratchet peer, never the bare room address. Anonymous rooms
    // have no real JID → drop (cannot open).
    String bareSender;
    if (stanza.type == 'groupchat') {
      final muc = getAttributes().getManagerById<MUCManager>(mucManager);
      final nick = fromFull.resource;
      final room = await muc?.getRoomState(fromFull.toBare());
      final real = (nick.isEmpty ? null : room?.members[nick]?.realJid)
          ?.toBare();
      if (real == null) {
        logger.finest(
          'OMEMO groupchat from anonymous occupant ${stanza.from}; '
          'cannot decrypt',
        );
        return state
          ..encrypted = true
          ..encryptionError = UnknownOmemoError();
      }
      bareSender = real.toString();
    } else {
      bareSender = fromFull.toBare().toString();
    }
    final header = encrypted.firstTag('header')!;
    final ourId = await _getDeviceId();

    final keys = <axolotl.AxolotlEncryptedKey>[];
    for (final child in header.children) {
      if (child.tag != 'key') continue;
      final rid = int.tryParse('${child.attributes['rid']}');
      if (rid == null) continue;
      // Keep all keys; manager filters by our rid (Conversations may duplicate).
      keys.add(
        axolotl.AxolotlEncryptedKey(
          rid,
          child.innerText(),
          child.attributes['prekey'] == 'true',
        ),
      );
    }

    List<int>? iv;
    final ivEl = header.firstTag('iv');
    if (ivEl != null) {
      iv = base64Decode(ivEl.innerText());
    }

    List<int>? payload;
    final payloadEl = encrypted.firstTag('payload');
    if (payloadEl != null) {
      payload = base64Decode(payloadEl.innerText());
    }

    final sid = int.parse(header.attributes['sid']! as String);
    final om = await _getOmemoManager();
    final result = await om.onIncomingStanza(
      axolotl.AxolotlIncomingStanza(
        bareSenderJid: bareSender,
        senderDeviceId: sid,
        keys: keys,
        iv: iv,
        payload: payload,
      ),
    );

    var children = stanza.children;
    if (result.error != null) {
      state.encryptionError = result.error;
    } else {
      children = stanza.children
          .where(
            (child) =>
                child.tag != 'encrypted' ||
                child.attributes['xmlns'] != emeOmemo,
          )
          .toList();
      // Drop the plaintext fallback body; replace with decrypted text.
      children = children.where((c) => c.tag != 'body').toList();
    }

    if (result.payload != null) {
      children.add(
        XMLNode(
          tag: 'body',
          text: result.payload!,
        ),
      );
    }

    if (stanza.tag == 'message' && encrypted.firstTag('payload') == null) {
      logger.finest('Received empty axolotl message. Ending processing early.');
      return state
        ..encrypted = true
        ..skip = true
        ..done = true;
    }

    // Silence unused-var for ourId (used implicitly via manager filter).
    assert(ourId > 0, 'device id');

    return state
      ..encrypted = true
      ..stanza = Stanza(
        to: stanza.to,
        from: stanza.from,
        id: stanza.id,
        type: stanza.type,
        children: children,
        tag: stanza.tag,
        attributes: Map<String, String>.from(stanza.attributes),
      )
      ..extensions.set<OmemoData>(
        OmemoData(
          result.newSessions,
          const {},
        ),
      );
  }

  Future<Result<OmemoError, XMLNode>> _retrieveDeviceListPayload(
    JID jid,
  ) async {
    final pm = getAttributes().getManagerById<PubSubManager>(pubsubManager)!;
    final result = await pm.getItems(jid.toBare(), omemoDevicesXmlns);
    if (result.isType<PubSubError>()) return Result(UnknownOmemoError());

    final itemList = result.get<List<PubSubItem>>();
    if (itemList.isEmpty) return Result(EmptyDeviceListException());
    return Result(itemList.first.payload);
  }

  Future<Result<OmemoError, List<int>>> getDeviceList(JID jid) async {
    final itemsRaw = await _retrieveDeviceListPayload(jid);
    if (itemsRaw.isType<OmemoError>()) return Result(UnknownOmemoError());

    final ids = itemsRaw
        .get<XMLNode>()
        .children
        .map((child) => int.parse(child.attributes['id']! as String))
        .toList();
    return Result(ids);
  }

  Future<Result<OmemoError, List<axolotl.AxolotlBundle>>> retrieveDeviceBundles(
    JID jid,
  ) async {
    final pm = getAttributes().getManagerById<PubSubManager>(pubsubManager)!;
    final bundlesRaw = await pm.getItems(jid, omemoBundlesXmlns);
    if (bundlesRaw.isType<PubSubError>()) return Result(UnknownOmemoError());

    final bundles = bundlesRaw
        .get<List<PubSubItem>>()
        .map(
          (bundle) =>
              axolotlBundleFromXML(jid, int.parse(bundle.id), bundle.payload),
        )
        .toList();

    return Result(bundles);
  }

  Future<Result<OmemoError, axolotl.AxolotlBundle>> retrieveDeviceBundle(
    JID jid,
    int deviceId,
  ) async {
    final pm = getAttributes().getManagerById<PubSubManager>(pubsubManager)!;
    final bareJid = jid.toBare();
    final item = await pm.getItem(bareJid, omemoBundlesXmlns, '$deviceId');
    if (item.isType<PubSubError>()) return Result(UnknownOmemoError());

    return Result(
      axolotlBundleFromXML(jid, deviceId, item.get<PubSubItem>().payload),
    );
  }

  Future<Result<OmemoError, bool>> publishBundle(
    axolotl.AxolotlBundle bundle,
  ) async {
    final attrs = getAttributes();
    final pm = attrs.getManagerById<PubSubManager>(pubsubManager)!;
    final bareJid = attrs.getFullJID().toBare();

    XMLNode? deviceList;
    final deviceListRaw = await _retrieveDeviceListPayload(bareJid);
    if (!deviceListRaw.isType<OmemoError>()) {
      deviceList = deviceListRaw.get<XMLNode>();
    }

    deviceList ??= XMLNode.xmlns(
      tag: 'devices',
      xmlns: omemoDevicesXmlns,
    );

    final ids = deviceList.children
        .map((child) => int.parse(child.attributes['id']! as String));

    if (!ids.contains(bundle.deviceId)) {
      final newDeviceList = XMLNode.xmlns(
        tag: 'devices',
        xmlns: omemoDevicesXmlns,
        children: [
          ...deviceList.children,
          XMLNode(
            tag: 'device',
            attributes: <String, String>{
              'id': '${bundle.deviceId}',
            },
          ),
        ],
      );

      final deviceListPublish = await pm.publish(
        bareJid,
        omemoDevicesXmlns,
        newDeviceList,
        id: 'current',
        options: const PubSubPublishOptions(
          accessModel: 'open',
        ),
      );
      if (deviceListPublish.isType<PubSubError>()) return const Result(false);
    }

    final deviceBundlePublish = await pm.publish(
      bareJid,
      omemoBundlesXmlns,
      axolotlBundleToXML(bundle),
      id: '${bundle.deviceId}',
      options: const PubSubPublishOptions(
        accessModel: 'open',
        maxItems: 'max',
      ),
    );

    return Result(deviceBundlePublish.isType<PubSubError>());
  }

  Future<void> subscribeToDeviceListImpl(String jid) async {
    final pm = getAttributes().getManagerById<PubSubManager>(pubsubManager)!;
    await pm.subscribe(JID.fromString(jid), omemoDevicesXmlns);
  }

  Future<void> publishDeviceImpl(axolotl.AxolotlDevice device) async {
    final om = await _getOmemoManager();
    om.trackPreKeyIds(device.store.preKeyStore.store.keys);
    await publishBundle(await om.getLocalBundle());
  }

  Future<Result<OmemoError, bool>> supportsOmemo(JID jid) async {
    final dm = getAttributes().getManagerById<DiscoManager>(discoManager)!;
    final items = await dm.discoItemsQuery(jid.toBare());

    if (items.isType<DiscoError>()) return Result(UnknownOmemoError());

    final nodes = items.get<List<DiscoItem>>();
    final result = nodes.any((item) => item.node == omemoDevicesXmlns) &&
        nodes.any((item) => item.node == omemoBundlesXmlns);
    return Result(result);
  }

  Future<Result<OmemoError, bool>> deleteDevice(int deviceId) async {
    final pm = getAttributes().getManagerById<PubSubManager>(pubsubManager)!;
    final jid = getAttributes().getFullJID().toBare();

    final bundleResult = await pm.retract(jid, omemoBundlesXmlns, '$deviceId');
    if (bundleResult.isType<PubSubError>()) {
      return Result(UnknownOmemoError());
    }

    final deviceListResult = await _retrieveDeviceListPayload(jid);
    if (deviceListResult.isType<OmemoError>()) {
      return Result(UnknownOmemoError());
    }

    final payload = deviceListResult.get<XMLNode>();
    final newPayload = XMLNode.xmlns(
      tag: 'devices',
      xmlns: omemoDevicesXmlns,
      children: payload.children
          .where((child) => child.attributes['id'] != '$deviceId')
          .toList(),
    );
    final publishResult = await pm.publish(
      jid,
      omemoDevicesXmlns,
      newPayload,
      id: 'current',
      options: const PubSubPublishOptions(
        accessModel: 'open',
      ),
    );

    if (publishResult.isType<PubSubError>()) return Result(UnknownOmemoError());

    return const Result(true);
  }
}
