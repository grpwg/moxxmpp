import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:moxlib/moxlib.dart';
import 'package:moxxmpp/src/managers/base.dart';
import 'package:moxxmpp/src/managers/namespaces.dart';
import 'package:moxxmpp/src/namespaces.dart';
import 'package:moxxmpp/src/negotiators/namespaces.dart';
import 'package:moxxmpp/src/negotiators/negotiator.dart';
import 'package:moxxmpp/src/stanza.dart';
import 'package:moxxmpp/src/stringxml.dart';
import 'package:moxxmpp/src/xeps/xep_0004.dart';

/// Result of an IQ-get against `jabber:iq:register` (XEP-0077), mirroring
/// Conversations' `RegistrationManager.Registration` variants.
sealed class RegistrationChallenge {
  const RegistrationChallenge();
}

/// Server accepts a plain username + password SET (no captcha form).
class SimpleRegistration extends RegistrationChallenge {
  const SimpleRegistration();
}

/// Captcha data form (XEP-0158 §register) with an inline BOB image.
class ExtendedRegistration extends RegistrationChallenge {
  const ExtendedRegistration({
    required this.form,
    required this.captchaBytes,
    this.captchaMime = 'image/png',
  });

  final DataForm form;
  final List<int> captchaBytes;
  final String captchaMime;
}

/// OOB / instructions redirect to an HTTPS registration page (XEP-0077 §3.3).
class RedirectRegistration extends RegistrationChallenge {
  const RedirectRegistration(this.url);

  final Uri url;
}

/// Returned from [XmppConnection.connect] when IBR completed successfully.
///
/// Not a failure: the socket is closed afterwards so the client can log in
/// with SASL (Conversations `REGISTRATION_SUCCESSFUL`).
class RegistrationSuccessful extends NegotiatorError {
  @override
  bool isRecoverable() => false;

  @override
  String toString() => 'RegistrationSuccessful';
}

class RegistrationNotSupportedError extends NegotiatorError {
  @override
  bool isRecoverable() => false;

  @override
  String toString() => 'RegistrationNotSupportedError';
}

class RegistrationFailedError extends NegotiatorError {
  RegistrationFailedError({
    this.condition = '',
    this.text = '',
    this.conflict = false,
    this.passwordTooWeak = false,
    this.invalidCaptcha = false,
    this.pleaseWait = false,
    this.redirectUrl,
  });

  final String condition;
  final String text;
  final bool conflict;
  final bool passwordTooWeak;
  final bool invalidCaptcha;
  final bool pleaseWait;
  final Uri? redirectUrl;

  @override
  bool isRecoverable() => false;

  @override
  String toString() {
    if (redirectUrl != null) return 'RegistrationRedirect($redirectUrl)';
    if (conflict) return 'RegistrationConflict';
    if (passwordTooWeak) return 'RegistrationPasswordTooWeak';
    if (invalidCaptcha) return 'RegistrationInvalidCaptcha';
    if (pleaseWait) return 'RegistrationPleaseWait';
    return 'RegistrationFailed($condition: $text)';
  }
}

/// Build a XEP-0004 submit form like Conversations `Data.submit(Map)`.
DataForm submitRegistrationForm(DataForm form, Map<String, String> overrides) {
  return DataForm(
    type: 'submit',
    title: null,
    instructions: const [],
    reported: const [],
    items: const [],
    fields: [
      for (final field in form.fields)
        DataFormField(
          varAttr: field.varAttr,
          type: field.type,
          label: null,
          description: null,
          isRequired: false,
          options: const [],
          values: overrides.containsKey(field.varAttr)
              ? [overrides[field.varAttr]!]
              : field.values,
        ),
    ],
  );
}

/// Parse a register IQ result into a [RegistrationChallenge].
///
/// Exposed for tests; production code goes through
/// [InBandRegistrationNegotiator].
RegistrationChallenge parseRegistrationQuery(XMLNode query) {
  assert(
    query.attributes['xmlns'] == registerXmlns || query.tag == 'query',
    'Expected jabber:iq:register query',
  );

  final hasUsername = query.firstTag('username') != null;
  final hasPassword = query.firstTag('password') != null;
  if (hasUsername && hasPassword) {
    return const SimpleRegistration();
  }

  final x = query.firstTag('x', xmlns: dataFormsXmlns);
  if (x != null) {
    final form = parseDataForm(x);
    final formType = form.getFieldByVar(formVarFormType)?.values.firstOrNull;
    if (formType == registerXmlns || formType == captchaXmlns) {
      final extended = _parseExtendedRegistration(query, form);
      if (extended != null) return extended;
    }
  }

  final oob = query.firstTag('x', xmlns: oobDataXmlns);
  final oobUrl = oob?.firstTag('url')?.innerText();
  if (oobUrl != null) {
    final uri = Uri.tryParse(oobUrl);
    if (uri != null && uri.isScheme('https')) {
      return RedirectRegistration(uri);
    }
  }

  final instructions = query.firstTag('instructions')?.innerText();
  if (instructions != null) {
    final match = RegExp(
      r'https://[^\s<>]+',
      caseSensitive: false,
    ).firstMatch(instructions);
    if (match != null) {
      final uri = Uri.tryParse(match.group(0)!);
      if (uri != null && uri.isScheme('https')) {
        return RedirectRegistration(uri);
      }
    }
  }

  throw StateError('No supported registration method in register query');
}

ExtendedRegistration? _parseExtendedRegistration(XMLNode query, DataForm form) {
  final ocr = form.getFieldByVar('ocr');
  if (ocr == null) return null;

  // Prefer Bits of Binary attached to the register query (Conversations).
  for (final data in query.findTags('data', xmlns: bobXmlns)) {
    final cid = data.attributes['cid'] as String?;
    final raw = data.innerText().replaceAll(RegExp(r'\s'), '');
    if (cid == null || raw.isEmpty) continue;
    try {
      final bytes = base64.decode(raw);
      final mime = (data.attributes['type'] as String?) ?? 'image/png';
      return ExtendedRegistration(
        form: form,
        captchaBytes: bytes,
        captchaMime: mime,
      );
    } catch (_) {
      continue;
    }
  }

  return null;
}

RegistrationFailedError registrationErrorFromIq(XMLNode iq) {
  final error = iq.firstTag('error');
  final conditionNode = error?.firstTagByXmlns(fullStanzaXmlns);
  final condition = conditionNode?.tag ?? '';
  final text = (error?.firstTag('text')?.innerText() ?? '').toLowerCase();

  return RegistrationFailedError(
    condition: condition,
    text: error?.firstTag('text')?.innerText() ?? '',
    conflict: condition == 'conflict',
    pleaseWait: condition == 'resource-constraint',
    passwordTooWeak:
        (condition == 'not-acceptable' || condition == 'not-allowed') &&
        text.contains('password'),
    invalidCaptcha:
        (condition == 'not-acceptable' || condition == 'not-allowed') &&
        text.contains('captcha'),
  );
}

enum _IbrPhase { idle, awaitingGet, awaitingUser, awaitingSet }

/// Stream-feature negotiator for XEP-0077 (Conversations registration path).
///
/// Matches only when [ConnectionSettings.register] is true. After STARTTLS /
/// WSS it issues IQ-get register, then IQ-set. Captcha forms pause until
/// [submitCaptcha] is called.
class InBandRegistrationNegotiator extends XmppFeatureNegotiatorBase {
  InBandRegistrationNegotiator()
    : super(
        // Above SASL so IBR runs instead of authentication.
        100,
        false,
        registerStreamFeatureXmlns,
        inBandRegistrationNegotiator,
      );

  final Logger _log = Logger('InBandRegistrationNegotiator');

  _IbrPhase _phase = _IbrPhase.idle;
  String? _pendingId;
  DataForm? _pendingForm;
  final Completer<RegistrationChallenge> _challengeCompleter =
      Completer<RegistrationChallenge>();

  /// Completes once the IQ-get response is classified.
  Future<RegistrationChallenge> get challenge => _challengeCompleter.future;

  @override
  bool matchesFeature(List<XMLNode> features) {
    if (!attributes.getConnectionSettings().register) return false;
    // IBR is only defined on a confidential channel (TLS / WSS).
    if (!attributes.getSocket().isSecure()) return false;
    return features.any(
      (f) =>
          f.attributes['xmlns'] == registerStreamFeatureXmlns ||
          (f.tag == 'register' &&
              f.attributes['xmlns'] == registerStreamFeatureXmlns),
    );
  }

  @override
  Future<Result<NegotiatorState, NegotiatorError>> negotiate(
    XMLNode nonza,
  ) async {
    switch (_phase) {
      case _IbrPhase.idle:
        if (!matchesFeature(
          nonza.tag == 'stream:features' ? nonza.children : const [],
        )) {
          // Called with features that somehow selected us without register.
          if (nonza.tag == 'stream:features') {
            return Result(RegistrationNotSupportedError());
          }
        }
        if (nonza.tag == 'stream:features' &&
            !nonza.children.any(
              (f) => f.attributes['xmlns'] == registerStreamFeatureXmlns,
            )) {
          return Result(RegistrationNotSupportedError());
        }
        _sendGet();
        _phase = _IbrPhase.awaitingGet;
        return const Result(NegotiatorState.ready);

      case _IbrPhase.awaitingGet:
        if (!_isOurIq(nonza)) {
          _log.warning('Ignoring unexpected nonza while awaiting register GET');
          return const Result(NegotiatorState.ready);
        }
        if (nonza.attributes['type'] == 'error') {
          return Result(registrationErrorFromIq(nonza));
        }
        final query = nonza.firstTag('query', xmlns: registerXmlns);
        if (query == null) {
          return Result(
            RegistrationFailedError(text: 'missing register query'),
          );
        }
        late final RegistrationChallenge challenge;
        try {
          challenge = parseRegistrationQuery(query);
        } catch (e) {
          _log.severe('Unsupported registration response: $e');
          return Result(RegistrationFailedError(text: '$e'));
        }
        if (!_challengeCompleter.isCompleted) {
          _challengeCompleter.complete(challenge);
        }

        if (challenge is SimpleRegistration) {
          _sendSimpleSet();
          _phase = _IbrPhase.awaitingSet;
          return const Result(NegotiatorState.ready);
        }
        if (challenge is RedirectRegistration) {
          return Result(RegistrationFailedError(redirectUrl: challenge.url));
        }
        if (challenge is ExtendedRegistration) {
          _pendingForm = challenge.form;
          _phase = _IbrPhase.awaitingUser;
          return const Result(NegotiatorState.ready);
        }
        return Result(RegistrationFailedError(text: 'unknown challenge'));

      case _IbrPhase.awaitingUser:
        // Captcha OCR arrives via [submitCaptcha]; ignore stray traffic.
        _log.finest('Waiting for captcha submission; ignoring $nonza');
        return const Result(NegotiatorState.ready);

      case _IbrPhase.awaitingSet:
        if (!_isOurIq(nonza)) {
          return const Result(NegotiatorState.ready);
        }
        if (nonza.attributes['type'] == 'error') {
          return Result(registrationErrorFromIq(nonza));
        }
        if (nonza.attributes['type'] == 'result') {
          _log.info('In-band registration succeeded');
          return Result(RegistrationSuccessful());
        }
        return Result(RegistrationFailedError(text: 'unexpected set response'));
    }
  }

  /// Submit OCR for an [ExtendedRegistration] challenge.
  Future<void> submitCaptcha(String ocr) async {
    final form = _pendingForm;
    if (form == null || _phase != _IbrPhase.awaitingUser) {
      throw StateError('No captcha registration pending');
    }
    final settings = attributes.getConnectionSettings();
    final submission = submitRegistrationForm(form, {
      'username': settings.jid.local,
      'password': settings.password,
      'ocr': ocr,
    });
    _sendSetWithForm(submission);
    _phase = _IbrPhase.awaitingSet;
  }

  void _sendGet() {
    final settings = attributes.getConnectionSettings();
    _pendingId = attributes.getConnection().generateId();
    attributes.sendNonza(
      XMLNode(
        tag: 'iq',
        attributes: <String, String>{
          'type': 'get',
          'id': _pendingId!,
          'to': settings.jid.domain,
          'xmlns': stanzaXmlns,
        },
        children: [XMLNode.xmlns(tag: 'query', xmlns: registerXmlns)],
      ),
    );
  }

  void _sendSimpleSet() {
    final settings = attributes.getConnectionSettings();
    _pendingId = attributes.getConnection().generateId();
    attributes.sendNonza(
      XMLNode(
        tag: 'iq',
        attributes: <String, String>{
          'type': 'set',
          'id': _pendingId!,
          'to': settings.jid.domain,
          'xmlns': stanzaXmlns,
        },
        children: [
          XMLNode.xmlns(
            tag: 'query',
            xmlns: registerXmlns,
            children: [
              XMLNode(tag: 'username', text: settings.jid.local),
              XMLNode(tag: 'password', text: settings.password),
            ],
          ),
        ],
      ),
    );
  }

  void _sendSetWithForm(DataForm form) {
    _pendingId = attributes.getConnection().generateId();
    attributes.sendNonza(
      XMLNode(
        tag: 'iq',
        attributes: <String, String>{
          'type': 'set',
          'id': _pendingId!,
          'xmlns': stanzaXmlns,
        },
        children: [
          XMLNode.xmlns(
            tag: 'query',
            xmlns: registerXmlns,
            children: [form.toSubmitXml()],
          ),
        ],
      ),
    );
  }

  bool _isOurIq(XMLNode nonza) {
    return nonza.tag == 'iq' && nonza.attributes['id'] == _pendingId;
  }

  @override
  void reset() {
    _phase = _IbrPhase.idle;
    _pendingId = null;
    _pendingForm = null;
    super.reset();
  }
}

/// Post-login helpers (change password / delete account) over XEP-0077.
class InBandRegistrationManager extends XmppManagerBase {
  InBandRegistrationManager() : super(inBandRegistrationManager);

  @override
  Future<bool> isSupported() async => isFeatureSupported(registerXmlns);

  /// Change the account password while authenticated.
  Future<Result<bool, StanzaError>> setPassword(String password) async {
    final settings = getAttributes().getConnectionSettings();
    final result = await getAttributes().sendStanza(
      StanzaDetails(
        Stanza.iq(
          type: 'set',
          to: settings.jid.domain,
          children: [
            XMLNode.xmlns(
              tag: 'query',
              xmlns: registerXmlns,
              children: [
                XMLNode(tag: 'username', text: settings.jid.local),
                XMLNode(tag: 'password', text: password),
              ],
            ),
          ],
        ),
      ),
    );
    if (result == null) {
      return Result(UnknownStanzaError());
    }
    if (result.attributes['type'] == 'result') {
      return const Result(true);
    }
    return Result(StanzaError.fromXMLNode(result) ?? UnknownStanzaError());
  }

  /// Request account removal (`<remove/>`).
  Future<Result<bool, StanzaError>> unregister() async {
    final settings = getAttributes().getConnectionSettings();
    final result = await getAttributes().sendStanza(
      StanzaDetails(
        Stanza.iq(
          type: 'set',
          to: settings.jid.domain,
          children: [
            XMLNode.xmlns(
              tag: 'query',
              xmlns: registerXmlns,
              children: [XMLNode(tag: 'remove')],
            ),
          ],
        ),
      ),
    );
    if (result == null) {
      return Result(UnknownStanzaError());
    }
    if (result.attributes['type'] == 'result') {
      return const Result(true);
    }
    return Result(StanzaError.fromXMLNode(result) ?? UnknownStanzaError());
  }
}
