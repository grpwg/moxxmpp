import 'dart:async';

import 'package:logging/logging.dart';
import 'package:moxlib/moxlib.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:moxxmpp/src/xeps/xep_0077/errors.dart';
import 'package:moxxmpp/src/xeps/xep_0077/events.dart';
import 'package:moxxmpp/src/xeps/xep_0077/helpers.dart';
import 'package:moxxmpp/src/xeps/xep_0077/internal.dart';

/// A function that handles an [InBandRegistrationForm] and returns the form to submit back to the server.
/// A client should use this in [InBandRegistrationNegotiator.setFormHandler] to show the registration form to the user and return the filled form.
typedef FormHandler<T extends InBandRegistrationForm> = Future<InBandRegistrationForm> Function(T form, {List<InBandRegistrationForm> alternatives, Object? lastError});

/// A marker to indicate that this negotiator is for XEP-0077 (In-Band Registration).
/// Mostly, this is a flag to tell [ClientToServerNegotiator] to accept incomplete authentication
/// during registration.
mixin InBandRegistrationNegotiatorInterface {
  bool get attemptRegistration;
}

// TODO: refactor the negotiator processing stuff to a mixin, and "with" that mixin to both this negotiator and a manager.
// That way, the common logic of processing the iq stanzas is shared. The differences to be accounted for include:
// - Triggering registration: the negotiator requires a flag & registered handlers, the manager will use a method & callbacks
// - How stanzas are received: negotiators use the `negotiate` method, while managers use the `incomingStanzaHandlers` list
// - How stanzas are sent: negotiators use non-awaitable `sendNonza`, while managers use awaitable `sendStanza`
// - Managers only need one incoming stanza handler, since they can await the server response
//
// The negotiator handles registering to an XMPP IM server, while the manager will handle registering to remote servers
// such as gateways.

/// A negotiator that implements XEP-0077 In-Band Registration for registering to an XMPP instant messaging server,
/// according to [XEP-0077 section 3.1](https://xmpp.org/extensions/xep-0077.html#usecases-register).
/// If the server does not support in-band registration, negotiation (and therefore the connection) will fail with an [InBandRegistrationSkippedError].
/// 
/// ## Usage
/// > [!IMPORTANT]
/// > You must start disconnected! This negotiator registers with a server. Connecting to a server without credentials won't work.
/// 1. Register InBandRegistrationNegotiator with the connection:
/// ```dart
/// final connection = XmppConnection(...);
/// await connection.registerFeatureNegotiators([InBandRegistrationNegotiator()]);
/// ```
/// You can keep the negotiator registered with the connection even if you don't want to register to a server at the moment.
/// 2. When you want to register, set the [attemptRegistration] property to `true`:
/// ```dart
/// connection.getInBandRegistrationNegotiator()?.attemptRegistration = true;
/// ```
/// 3. Configure your registration form handlers. Read the [setFormHandler] documentation for more information.
/// ```dart
/// connection.getInBandRegistrationNegotiator()?.setFormHandler<SimpleInBandRegistrationForm>(
///   (form, [alternatives]) {
///     // Show the form here, and return the filled form.
///     // You may offer the user the alternative forms in [alternatives] to choose from.
///     return form;
///   },
/// );
/// ```
/// 4. Set the JID in connection settings to the domain of the server you want to register with:
/// ```dart
/// connection.connectionSettings = ConnectionSettings(jid: JID.fromDomain('example.com'));
/// ```
/// 5. Connect to the server as normal:
/// ```dart
/// await connection.connect(waitUntilLogin: true);
/// ```
/// > [!WARNING]
/// > **Don't use a timeout on `.connect` when registering!** This will be awaited for however long registration takes.
/// > If this completes successfully, you will be signed in with the new credentials!
/// 
/// {@category Feature Negotiators}
class InBandRegistrationNegotiator extends XmppFeatureNegotiatorBase with InBandRegistrationNegotiatorInterface {
  InBandRegistrationNegotiator()
      : super(200, false, inBandRegistrationXmlns, inBandRegistrationNegotiator);

  final _logger = Logger('InBandRegistrationNegotiator');
  
  /// Whether or not to attempt registration.
  /// The client should set this before connecting to a server if it wants to register with it.
  @override
  bool attemptRegistration = false;
  bool _matched = false;

  final Map<Type, FormHandler> _formHandlers = <Type, FormHandler>{};

  /// Contains a list of transactions that are currently in progress (that is, waiting for a response from the server).
  /// Realistically, there should only be one... you are in uncharted territory if this gets any bigger.
  /// This is needed because moxxmpp currently doesn't await nonzas for us.
  final List<InBandRegistrationTransaction> _transactions = <InBandRegistrationTransaction>[];

  /// Set a form handler that will be called when the server sends a registration form.
  /// Only the most recently added handler of each type will be used. The type of handler will be picked
  /// based on the precedence order in XEP-0077 Section 6 (as of XEP version 2.4).
  /// 
  /// If [OutOfBandRegistrationForm] is returned, the connection will be closed without reconnecting,
  /// and the client MUST return to the login screen themselves.
  /// 
  /// For other return types, the [InBandRegistrationNegotiator] will submit the form. If it succeeds,
  /// the connection will be reset and the client will be logged in with the new credentials.
  /// The new credentials will be sent with an [InBandRegistrationSuccessEvent] so that the client can
  /// persist them however you like.
  void setFormHandler<T extends InBandRegistrationForm>(FormHandler<T> formHandler) {
    _formHandlers[T] = formHandler as FormHandler;
  }

  @override
  bool matchesFeature(List<XMLNode> features) {
    final matched = features.any(
      (feature) => (feature.xmlns == inBandRegistrationXmlns || feature.xmlns == 'http://jabber.org/features/iq-register') && feature.tag == 'register',
    );
    _matched = matched;
    if (!matched && attemptRegistration) {
      // The client requested registration, but the server does not support it.
      // Pretend the feature matched so that a better error can be shown.
      return true;
    }
    return matched;
  }

  Future<Result<NegotiatorState, NegotiatorError>> _handleFormResult(XMLNode query, [dynamic error]) async {
    final (dataForm, iqRegisterForm, oobForm) = parseRegistrationForm(query);
    // The "send result back" function
    Result<NegotiatorState, NegotiatorError> sendResult(InBandRegistrationForm result) {
      final id = attributes.getConnection().generateId();
      void send(XMLNode node) {
        attributes.sendNonza(Stanza.iq(
          to: attributes.getConnectionSettings().jid.domain,
          type: 'set',
          id: id,
          xmlns: 'jabber:client',
          children: [
            node,
          ],
        ),);
      }
      _transactions.add(InBandRegistrationTransaction(id, form: result));
      switch (result) {
        case SimpleInBandRegistrationForm _:
          _logger.fine('Sending filled iq:register form', result.toXml().toXml());
          send(result.toXml());
          return const Result(NegotiatorState.ready);
        case InBandRegistrationDataForm _:
          _logger.fine('Sending filled data form', result.toXml().toXml());
          send(XMLNode.xmlns(tag: 'query', xmlns: inBandRegistrationXmlns, children: [result.toXml()]));
          return const Result(NegotiatorState.ready);
        case OutOfBandRegistrationForm _:
          _logger.fine('OOB returned; disconnecting and cancelling', result.toXml().toXml());
          attributes.getConnection().disconnect();
          return const Result(NegotiatorState.skipRest);
      }
    }
    if (dataForm != null && _formHandlers.containsKey(InBandRegistrationDataForm)) {
      // Try data form 
      final result = await _formHandlers[InBandRegistrationDataForm]!(dataForm, alternatives: [
        iqRegisterForm, oobForm,
      ].whereType<InBandRegistrationForm>().toList(), lastError: error,);
      // Send the result back
      return sendResult(result);
    } else if ((iqRegisterForm.needed?.isNotEmpty ?? false) && _formHandlers.containsKey(SimpleInBandRegistrationForm)) {
      // Try iq:register form
      final result = await _formHandlers[SimpleInBandRegistrationForm]!(iqRegisterForm, alternatives: [
        dataForm, oobForm,
      ].whereType<InBandRegistrationForm>().toList(), lastError: error,);
      return sendResult(result);
    } else if ((iqRegisterForm.needed?.isNotEmpty ?? false) && _formHandlers.containsKey(InBandRegistrationDataForm)) {
      // Try iq:register form as data form
      final result = await _formHandlers[InBandRegistrationDataForm]!(InBandRegistrationDataForm.proxy(iqRegisterForm), alternatives: [
        dataForm, oobForm,
      ].whereType<InBandRegistrationForm>().toList(), lastError: error,);
      return sendResult(result);
    } else if (oobForm != null && _formHandlers.containsKey(OutOfBandRegistrationForm)) {
      // Try out-of-band registration
      final result = await _formHandlers[OutOfBandRegistrationForm]!(oobForm, alternatives: [
        dataForm, iqRegisterForm,
      ].whereType<InBandRegistrationForm>().toList(), lastError: error,);
      return sendResult(result);
    } else {
      return const Result(InBandRegistrationFailedError('No form handler available for registration form.'));
    }
  }

  Future<Result<NegotiatorState, NegotiatorError>> _handleSuccess(InBandRegistrationForm form) async {
    // TODO: set new credentials in ConnectionSettings (using the JID and password from the registration form)
    final newJid = JID(form.username??'', attributes.getFullJID().domain, '');
    attributes.getConnection().connectionSettings = ConnectionSettings(jid: newJid, password: form.password??'');
    attemptRegistration = false;
    _sendStreamHeaderWhenDone = true;
    unawaited(attributes.sendEvent(InBandRegistrationSuccessEvent(newJid, form.password??'')));
    return const Result(NegotiatorState.skipRest);
  }

  @override
  Future<Result<NegotiatorState, NegotiatorError>> negotiate(XMLNode nonza) async {
    if (!attemptRegistration) return const Result(NegotiatorState.done);
    if (!_matched) return Result(InBandRegistrationSkippedError());
    assert(_formHandlers.containsKey(InBandRegistrationDataForm), 'InBandRegistrationNegotiator must have a form handler for InBandRegistrationDataForm to work properly. '
        'You will not be able to register to many servers without it. '
        'If you did not intend to register, set attemptRegistration to false.');
    assert(_formHandlers.containsKey(OutOfBandRegistrationForm), 'InBandRegistrationNegotiator must have a form handler for OutOfBandRegistrationForm to work properly. '
        'You will not be able to register to many servers without it. '
        'If you did not intend to register, set attemptRegistration to false.');
    // TODO(halscode): I'm still not sure if "ready" or "retryLater" is the right state to return.
    // The intended behavior is that it will call this handler again on the next nonza.
    // Ready seems to do that, but if there are any other negotiators ready, it looks like it will skip them.
    // But retryLater ends up calling another handler _without this same nonza_, which is really odd behavior.
    if (!_transactions.any((tx) => tx.id == nonza.attributes['id'])) {
      // If we don't have an expected ID, this is not a response to our request
      return const Result(NegotiatorState.ready);
    }
    final transaction = _transactions.firstWhere((tx) => tx.id == nonza.attributes['id']);
    if (nonza case XMLNode(tag: 'iq', attributes: {'type': 'result' || 'error'})) {
      _transactions.removeWhere((tx) => tx.id == nonza.attributes['id']);
      if (nonza.firstTag('error') case final XMLNode error) {
        // The server returned an error
        if (error.attributes['type'] == 'modify') {
          if (nonza.firstTagByXmlns(inBandRegistrationXmlns) case final XMLNode query) {
            // Show the form again, but with the error
            return _handleFormResult(query, InBandRegistrationInvalidFormError.fromStanza(nonza));
          }
          // If the error is of type "modify", we can assume that the form is invalid (user input).
          // We don't have the form, 
          return Result(InBandRegistrationInvalidFormError.fromStanza(nonza));
        }
        // If the error is not of type "modify", we can assume that the registration failed
        // and will not succeed at this time.
        // If we got to this point we know the server supports IBR, so there's probably a reason
        _logger.severe('Registration failed with error: $error');
        if (error.firstTag('text') case final XMLNode text) {
          // If the error has a text, use it as the reason
          return Result(InBandRegistrationFailedError(text.text ?? 'Unknown error occurred during registration.'));
        }
        return Result(InBandRegistrationStanzaError(StanzaError.fromXMLNode(nonza) ?? UnknownStanzaError()));
      } else if (nonza.firstTag('query', xmlns: inBandRegistrationXmlns) case final XMLNode query) {
        if (nonza.firstTag('registered') != null) {
          // The server has registered the user successfully.
          _logger.fine('Already registered');
          // If there are credentials given, these should take precedence. It's entirely possible that the server
          // chooses to short-circuit registration and simply assign credentials, though in practice this will
          // probably never happen.
          // Technically this is unspecified behavior, but it's largely inferred from XEP-0077 Example 3.
          // A more likely scenario is that no credentials are given to us, the ones we used were accepted, and
          // this is the success message.
          final (dataForm, iqRegisterForm, _) = parseRegistrationForm(query);
          if (transaction.form == null && dataForm == null && (iqRegisterForm.username == null || iqRegisterForm.password == null)) {
            _logger.warning("No credentials found in registration form, but server says we're already registered. Proceeding as if we're already authenticated.");
            return const Result(NegotiatorState.skipRest);
          }
          var form = transaction.form ?? dataForm ?? iqRegisterForm;
          if (dataForm != null) {
            form = form.copyWith(
              username: dataForm.username,
              password: dataForm.password,
            );
          } else if (iqRegisterForm.username != null || iqRegisterForm.password != null) {
            form = form.copyWith(
              username: iqRegisterForm.username,
              password: iqRegisterForm.password,
            );
          }
          return _handleSuccess(form);
        }
        // Form(s) obtained; send it to the client and handle its response
        return _handleFormResult(query);
      } else if (nonza.children.isEmpty) {
        // An empty `<iq type="result"/>` stanza, using an ID corresponding to a registration request (already checked),
        // means that the server has registered the user successfully.
        _logger.fine('Empty iq:result received, assuming registration success');
        if (transaction.form == null) {
          return const Result(InBandRegistrationFailedError('No credentials, and empty result. XEP-0077 says to treat this as a success, but this is not very useful without credentials to sign in with.'));
        }
        return _handleSuccess(transaction.form!);
      } else {
        return const Result(NegotiatorState.ready);
      }
    } else if (_transactions.isEmpty) {
      // Get initial form or registration fields
      final id = attributes.getConnection().generateId();
      _transactions.add(InBandRegistrationTransaction(id));
      attributes.sendNonza(Stanza.iq(
        to: attributes.getConnectionSettings().jid.domain,
        type: 'get',
        id: id,
        xmlns: 'jabber:client',
        children: [
          XMLNode.xmlns(
            tag: 'query',
            xmlns: inBandRegistrationXmlns,
          ),
        ],
      ),);
      // This _should_ be called again on the next nonza...
      return const Result(NegotiatorState.ready);
    }
    return const Result(NegotiatorState.ready);
  }

  bool _sendStreamHeaderWhenDone = false;
  @override
  bool get sendStreamHeaderWhenDone => _sendStreamHeaderWhenDone;

  @override void reset() {
    _sendStreamHeaderWhenDone = false;
    attemptRegistration = false;
    super.reset();
  }
}

extension InBandRegistrationNegotiatorExtension on XmppConnection {
  /// Returns the [InBandRegistrationNegotiator] for this connection.
  InBandRegistrationNegotiator? getInBandRegistrationNegotiator() => getNegotiatorById<InBandRegistrationNegotiator>(inBandRegistrationNegotiator);
}
