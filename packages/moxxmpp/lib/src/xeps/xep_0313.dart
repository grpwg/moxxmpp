import 'package:moxlib/moxlib.dart';
import 'package:moxxmpp/src/jid.dart';
import 'package:moxxmpp/src/managers/base.dart';
import 'package:moxxmpp/src/managers/data.dart';
import 'package:moxxmpp/src/managers/handlers.dart';
import 'package:moxxmpp/src/managers/namespaces.dart';
import 'package:moxxmpp/src/namespaces.dart';
import 'package:moxxmpp/src/stanza.dart';
import 'package:moxxmpp/src/stringxml.dart';
import 'package:moxxmpp/src/xeps/xep_0004.dart';
import 'package:moxxmpp/src/xeps/xep_0203.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

abstract class MAMError {}

class UnknownMAMError extends MAMError {}

/// (The JID we sent the query to, the ID we used).
typedef PendingQueryKey = (JID, String);

/// One page of a MAM query, including the RSM cursor from `<fin/>`.
class MamQueryResult {
  const MamQueryResult({
    required this.count,
    required this.complete,
    this.first,
    this.last,
  });

  /// Number of `<result/>` messages received for this page.
  final int count;

  /// True when the archive has no further matching results after this page.
  final bool complete;

  /// RSM `<first/>` id from `<fin/>`, if present.
  final String? first;

  /// RSM `<last/>` id from `<fin/>`, if present. Use as `rsmAfter` for the
  /// next catch-up page.
  final String? last;
}

class MAMData extends StanzaHandlerExtension {
  MAMData(this.queryId, this.delay, {this.archiveId});

  /// The id of the query.
  final String? queryId;

  /// The MAM result's stable archive id (`<result id='…'/>`). This is the
  /// value RSM `after`/`before` expect for catch-up paging.
  final String? archiveId;

  /// The MAM-attached delayed delivery tag.
  final DelayedDeliveryData delay;
}

class MessageArchiveManagementManager extends XmppManagerBase {
  MessageArchiveManagementManager() : super(mamManager);

  /// Map for keeping track of pending queries. Query key -> Number of messages we received.
  final Map<PendingQueryKey, int> _pendingQueries = {};

  /// Lock for accessing [_pendingQueries].
  final Lock _lock = Lock();

  @override
  Future<bool> isSupported() async => true;

  @override
  List<StanzaHandler> getIncomingStanzaHandlers() => [
        StanzaHandler(
          stanzaTag: 'message',
          tagName: 'result',
          tagXmlns: mamXmlns,
          callback: _onMAMMessage,
          priority: -98,
        ),
      ];

  Future<StanzaHandlerData> _onMAMMessage(
    Stanza stanza,
    StanzaHandlerData data,
  ) async {
    if (stanza.from == null) {
      return data;
    }

    final result = stanza.firstTag('result', xmlns: mamXmlns)!;
    final qid = result.attributes['queryid']! as String;
    final archiveId = result.attributes['id'] as String?;
    final jid = JID.fromString(stanza.from!);
    final key = (jid, qid);
    final isQuerying = await _lock.synchronized(() {
      final contains = _pendingQueries.containsKey(key);
      if (contains) {
        // Increment if the key exists.
        _pendingQueries[key] = _pendingQueries[key]! + 1;
      }

      return contains;
    });
    if (!isQuerying) {
      logger.warning('Received unexpected MAM result. Ignoring...');
      return StanzaHandlerData(true, true, stanza, data.extensions);
    }
    final forwarded = result.firstTag('forwarded', xmlns: forwardedXmlns)!;
    final message = forwarded.firstTag('message', xmlns: stanzaXmlns)!;
    final delay = forwarded.firstTag('delay', xmlns: delayedDeliveryXmlns)!;

    return StanzaHandlerData(
      false,
      false,
      Stanza.fromXMLNode(message),
      data.extensions
        ..set(
          MAMData(
            qid,
            DelayedDeliveryData(
              jid,
              DateTime.parse(delay.attributes['stamp']! as String),
            ),
            archiveId: archiveId,
          ),
        ),
    );
  }

  /// Query the MAM archive located at [archive].
  ///
  /// Prefer querying the user's own bare JID (account archive). Filter a
  /// single conversation with [withJid]; page catch-up with [rsmAfter] (classic
  /// RSM, Conversations-style) and older history with [rsmBefore].
  ///
  /// [beforeId]/[afterId]/[ids] are the optional `urn:xmpp:mam:2#extended`
  /// form fields. They require server support for that feature.
  ///
  /// Returns either a [MAMError] or a [MamQueryResult] describing the page.
  Future<Result<MAMError, MamQueryResult>> requestMessages(
    JID archive, {
    JID? withJid,
    DateTime? start,
    DateTime? end,
    String? rsmAfter,
    String? rsmBefore,
    String? beforeId,
    String? afterId,
    List<String>? ids,
    int? pageSize,
  }) async {
    assert(
      !(ids != null && (beforeId != null || afterId != null)),
      'beforeId/afterId cannot be specified with ids',
    );
    assert(
      !(rsmAfter != null && rsmBefore != null),
      'rsmAfter and rsmBefore cannot both be specified',
    );

    final uuid = const Uuid().v4();
    final key = (archive, uuid);
    await _lock.synchronized(() {
      _pendingQueries[key] = 0;
    });

    final formFields = <DataFormField>[
      const DataFormField(
        varAttr: 'FORM_TYPE',
        type: 'hidden',
        options: [],
        values: [mamXmlns],
        isRequired: false,
      ),
      if (withJid != null)
        DataFormField(
          varAttr: 'with',
          options: [],
          values: [withJid.toBare().toString()],
          isRequired: false,
        ),
      if (start != null)
        DataFormField(
          varAttr: 'start',
          options: [],
          values: [start.toUtc().toIso8601String()],
          isRequired: false,
        ),
      if (end != null)
        DataFormField(
          varAttr: 'end',
          options: [],
          values: [end.toUtc().toIso8601String()],
          isRequired: false,
        ),
      if (beforeId != null)
        DataFormField(
          varAttr: 'before-id',
          options: [],
          values: [beforeId],
          isRequired: false,
        ),
      if (afterId != null)
        DataFormField(
          varAttr: 'after-id',
          options: [],
          values: [afterId],
          isRequired: false,
        ),
      if (ids != null)
        DataFormField(
          varAttr: 'ids',
          options: [],
          values: ids,
          isRequired: false,
        ),
    ];

    // Always submit a form when filtering; a bare max-only query is still
    // valid and returns the most recent page of the account archive.
    final dataForm = formFields.length > 1
        ? DataForm(
            type: 'submit',
            instructions: [],
            fields: formFields,
            reported: [],
            items: [],
          )
        : null;

    final rsmChildren = <XMLNode>[
      if (pageSize != null)
        XMLNode(
          tag: 'max',
          text: pageSize.toString(),
        ),
      if (rsmAfter != null)
        XMLNode(
          tag: 'after',
          text: rsmAfter,
        ),
      if (rsmBefore != null)
        XMLNode(
          tag: 'before',
          text: rsmBefore,
        ),
    ];

    final request = Stanza.iq(
      type: 'set',
      to: archive.toString(),
      children: [
        XMLNode.xmlns(
          tag: 'query',
          xmlns: mamXmlns,
          attributes: {
            'queryid': uuid,
          },
          children: [
            if (dataForm != null) dataForm.toXml(),
            if (rsmChildren.isNotEmpty)
              XMLNode.xmlns(
                tag: 'set',
                xmlns: rsmXmlns,
                children: rsmChildren,
              ),
          ],
        ),
      ],
    );
    final result = await getAttributes().sendStanza(
      StanzaDetails(
        request,
        responseBypassesQueue: false,
      ),
    );

    // Remove the pending query key.
    final messageCount =
        await _lock.synchronized(() => _pendingQueries.remove(key)) ?? 0;

    // Check if the query finished successfully
    if (result == null || result.attributes['type'] != 'result') {
      return Result(UnknownMAMError());
    }

    final fin = result.firstTag('fin', xmlns: mamXmlns);
    final complete = fin?.attributes['complete'] == 'true' ||
        // Some servers omit complete when the page is the last one and
        // returned fewer than max; treat an empty page as done.
        messageCount == 0;
    final set = fin?.firstTag('set', xmlns: rsmXmlns);
    return Result(
      MamQueryResult(
        count: messageCount,
        complete: complete || (pageSize != null && messageCount < pageSize),
        first: set?.firstTag('first')?.innerText(),
        last: set?.firstTag('last')?.innerText(),
      ),
    );
  }
}
