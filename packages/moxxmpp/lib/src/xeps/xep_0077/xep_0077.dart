import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:moxlib/moxlib.dart';
import 'package:moxxmpp/moxxmpp.dart';

/// A function that handles an [InBandRegistrationForm] and returns the form to submit back to the server.
/// A client should use this in [InBandRegistrationNegotiator.setFormHandler] to show the registration form to the user and return the filled form.
typedef FormHandler<T extends InBandRegistrationForm> = Future<InBandRegistrationForm> Function(T form, {List<InBandRegistrationForm> alternatives, Object? lastError});

/// A marker to indicate that this negotiator is for XEP-0077 (In-Band Registration).
/// Mostly, this is a flag to tell [ClientToServerNegotiator] to accept incomplete authentication
/// during registration.
abstract class InBandRegistrationNegotiatorInterface {
  bool get attemptRegistration;
}

/// A mixin that implements the common functionality for [InBandRegistrationNegotiator] and [InBandRegistrationManager].
/// You probably don't want to use this mixin directly, but rather extend the [InBandRegistrationNegotiator] or [InBandRegistrationManager] classes.
@protected
mixin InBandRegistrationMixin {
  /// Nonzas will be sent and awaited with this.
  /// It must be able to track the ID of the stanza sent, so that it can match the response to the request.
  /// It is also responsible for adding the ID.
  @protected
  Future<XMLNode?> sendAwaitableNonza(XMLNode stanza);

  Logger get _logger;

  Future<Result<Set<InBandRegistrationForm>, XmppError>> requestForms(String domain) async {
    final form = await sendAwaitableNonza(
      Stanza.iq(
        to: domain,
        type: 'get',
        xmlns: 'jabber:client',
        children: [
          XMLNode.xmlns(
            tag: 'query',
            xmlns: inBandRegistrationXmlns,
          ),
        ],
      ),
    );
    final query = form?.firstTag('query', xmlns: inBandRegistrationXmlns) ?? form?.firstTag('query', xmlns: inBandRegistrationStreamFeatureXmlns);
    if (query == null) {
      // ignore: only_throw_errors
      throw const InBandRegistrationFailedError('No response from server when requesting registration form.');
    }
    // Handle the result
    final (dataForm, iqRegisterForm, oobForm) = parseRegistrationForm(query);
    return Result({dataForm, iqRegisterForm, oobForm}.whereType<InBandRegistrationForm>().toSet());
  }

  @protected
  /// Shows the form and submits the result.
  /// For the on[...]Form callbacks, the client should show the form to the user and return the filled form.
  /// Actually, you shouldn't call this method directly, but rather use [InBandRegistrationManager.registerWith]
  /// to register your existing account with remote services, or [InBandRegistrationNegotiator.attemptRegistration] 
  /// to start the registration process with a server you choose to connect to.
  Future<Result<bool, XmppError>> showForm({
    required Set<InBandRegistrationForm> forms,
    required String to,
    required FormHandler<InBandRegistrationDataForm> onDataForm,
    required FormHandler<OutOfBandRegistrationForm> onOobForm,
    FormHandler<SimpleInBandRegistrationForm>? onIqRegisterForm,
    bool Function()? shouldCancel,
    FutureOr<void> Function(InBandRegistrationForm form)? onSuccess,
  }) async {
    final allForms = TypedMap.fromList(forms.toList());
    final dataForm = allForms.get<InBandRegistrationDataForm>();
    final iqRegisterForm = allForms.get<SimpleInBandRegistrationForm>();
    final oobForm = allForms.get<OutOfBandRegistrationForm>();
    Object? submissionError;
    // ignore: literal_only_boolean_expressions
    do {
      late final Result<bool, InBandRegistrationError<XmppError>> submission;
      late final InBandRegistrationForm result;
      if (dataForm != null) {
        // Try data form
        result = await onDataForm(dataForm, alternatives: [
          iqRegisterForm, oobForm,
        ].whereType<InBandRegistrationForm>().toList(), lastError: submissionError,);
        // Send the result back
        submission = await submitForm(result, to);
      } else if ((iqRegisterForm?.needed?.isNotEmpty ?? false) && onIqRegisterForm != null) {
        // Try iq:register form
        result = await onIqRegisterForm(iqRegisterForm!, alternatives: [
          dataForm, oobForm,
        ].whereType<InBandRegistrationForm>().toList(), lastError: submissionError,);
        submission = await submitForm(result, to);
      } else if ((iqRegisterForm?.needed?.isNotEmpty ?? false) && dataForm != null) {
        // Try iq:register form as data form
        result = await onDataForm(InBandRegistrationDataForm.proxy(iqRegisterForm!), alternatives: [
          iqRegisterForm, dataForm, oobForm,
        ].whereType<InBandRegistrationForm>().toList(), lastError: submissionError,);
        if (result is InBandRegistrationDataForm) {
          // Proxy forms must be sent back as iq:register forms
          submission = await submitForm(result.toIqRegisterForm(), to);
        } else {
          submission = await submitForm(result, to);
        }
      } else if (oobForm != null) {
        // Try out-of-band registration
        result = await onOobForm(oobForm, alternatives: [
          dataForm, iqRegisterForm,
        ].whereType<InBandRegistrationForm>().toList(), lastError: submissionError,);
        submission = await submitForm(result, to);
      } else {
        return const Result(InBandRegistrationFailedError('No form handler available for registration form.'));
      }
      if (submission.isType<bool>()) {
        if (submission.get<bool>()) {
          // Registration was successful
          await onSuccess?.call(result);
          return const Result(true);
        } else {
          // Registration was cancelled
          cancelRegistration();
          return const Result(false);
        }
      } else {
        final error = submission.get<InBandRegistrationError<XmppError>>();
        if (error.isInputError) {
          // Show the form again with the error
          submissionError = error.error;
          continue; // retries the loop from "do"
        }
        // Registration failed with an error we can return
        return Result(error.error);
      }
    } while (shouldCancel?.call() == false);
    return const Result(false);
  }

  FutureOr<void> cancelRegistration();

  /// Result is false if the registration was cancelled, true if it was submitted successfully.
  /// Result is an InBandRegistrationError if the registration failed.
  /// If the form you filled out was an [InBandRegistrationDataForm], check the [InBandRegistrationDataForm.isProxy] flag to see if it was sent as an iq:register form.
  /// If it was, use the [InBandRegistrationDataForm.toIqRegisterForm] method to convert it back to an iq:register form.
  Future<Result<bool, InBandRegistrationError<XmppError>>> submitForm(InBandRegistrationForm form, String domain) async {
    late final Future<XMLNode?> responseFuture;
    Future<XMLNode?> send(XMLNode node) {
      return sendAwaitableNonza(Stanza.iq(
        to: domain,
        type: 'set',
        xmlns: 'jabber:client',
        children: [
          node,
        ],
      ),);
    }
    switch (form) {
      case SimpleInBandRegistrationForm _:
        _logger.fine('Sending filled iq:register form', form.toXml().toXml());
        responseFuture = send(form.toXml());
      case final InBandRegistrationDataForm form when form.isProxy:
        // NOTE: Usually this happens in the calling function, because the form handed back from UI may not preserve the isProxy flag.
        _logger.fine('Sending filled data form as iq:register form', form.toXml().toXml());
        responseFuture = send(form.toIqRegisterForm().toXml());
      case InBandRegistrationDataForm _:
        _logger.fine('Sending filled data form', form.toXml().toXml());
        responseFuture = send(XMLNode.xmlns(tag: 'query', xmlns: inBandRegistrationXmlns, children: [form.toXml()]));
      case OutOfBandRegistrationForm _:
        _logger.fine('OOB returned; disconnecting and cancelling', form.toXml().toXml());
        responseFuture = Future.value();
        await cancelRegistration();
        return const Result(false);
    }
    final response = await responseFuture;
    if (response == null) {
      return const Result(InBandRegistrationError(InBandRegistrationFailedError('No response from server when submitting registration form.')));
    }
    if (response.firstTag('error') case final XMLNode error) {
      if (error.firstTag('conflict', xmlns: 'urn:ietf:params:xml:ns:xmpp-stanzas') != null) {
        // The server said that the requested username is already in use.
        _logger.warning('Username already in use');
        return const Result(InBandRegistrationError(InBandRegistrationConflictError()));
      }
      if (error.attributes['type'] == 'modify' || error.firstTag('not-acceptable', xmlns: 'urn:ietf:params:xml:ns:xmpp-stanzas') != null) {
        // If the error is of type "modify" or has <not-acceptable>, we can assume that the form is invalid (user input).
        return Result(InBandRegistrationError(InBandRegistrationInvalidFormError.fromStanza(response)));
      }
      // The error didn't match any of the above conditions. 
      // We can assume that the registration failed and will not succeed at this time.
      // If we got to this point we know the server supports IBR, so there's probably a reason
      // it didn't work here (maybe because the server requires invite preauth).
      _logger.severe('Registration failed with error: $error');
      if (error.firstTag('text') case final XMLNode text when text.text != null) {
        // If the error has a text, use it as the reason
        return Result(InBandRegistrationError(InBandRegistrationFailedError(text.text!)));
      }
      return Result(InBandRegistrationError(InBandRegistrationStanzaError(StanzaError.fromXMLNode(response) ?? UnknownStanzaError())));
    }
    return const Result(true);
  }
}

/// A negotiator that implements XEP-0077 In-Band Registration for registering to an XMPP instant messaging server,
/// according to [XEP-0077 section 3.1](https://xmpp.org/extensions/xep-0077.html#usecases-register).
/// If the server does not support in-band registration, negotiation (and therefore the connection) will fail with an [InBandRegistrationSkippedError].
/// 
/// If you want to register with a remote service using an account you are already connected to, use [InBandRegistrationManager] instead.
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
/// > **Don't use a timeout on `.connect` or XmppConnection when registering!** This will be awaited for however long registration takes.
/// > If this completes successfully, you will be signed in with the new credentials!
/// 
/// {@category Feature Negotiators}
class InBandRegistrationNegotiator extends XmppFeatureNegotiatorBase with InBandRegistrationMixin implements InBandRegistrationNegotiatorInterface {
  InBandRegistrationNegotiator()
      : super(200, false, inBandRegistrationXmlns, inBandRegistrationNegotiator);

  @override
  final _logger = Logger('InBandRegistrationNegotiator');
  
  /// Whether or not to attempt registration.
  /// The client should set this before connecting to a server if it wants to register with it.
  @override
  bool attemptRegistration = false;
  bool _matched = false;
  bool _inProgress = false;
  bool _waitingForSecure = false;

  final Map<Type, dynamic> _formHandlers = <Type, dynamic>{};

  final Map<String, Completer<XMLNode?>> _awaitedNonzas = <String, Completer<XMLNode?>>{};
  Completer<Result<NegotiatorState, NegotiatorError>> _currentCompleter = Completer();

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
    _formHandlers[T] = formHandler;
  }
  FormHandler<T>? _getFormHandler<T extends InBandRegistrationForm>() {
    return _formHandlers[T] as FormHandler<T>?;
  }
  void unsetFormHandlers() {
    _formHandlers.clear();
  }

  @override
  bool matchesFeature(List<XMLNode> features) {
    if (_waitingForSecure) {
      _waitingForSecure = false;
      state = NegotiatorState.ready;
    }
    if (features.isEmpty || !attributes.getSocket().isSecure()) {
      return false;
    }
    final matched = features.any(
      (feature) => (feature.xmlns == inBandRegistrationXmlns || feature.xmlns == inBandRegistrationStreamFeatureXmlns) && feature.tag == 'register',
    );
    _matched = matched;
    return attemptRegistration;
  }

  @override
  FutureOr<void> cancelRegistration() {
    state = NegotiatorState.done;
    _inProgress = false;
    _formHandlers.clear();
    attributes.getConnection().disconnect();
  }

  @override
  @protected
  /// You shouldn't call this on the negotiator. Set [attemptRegistration] to true before connecting to the server instead.
  /// See [InBandRegistrationNegotiator] for more information.
  Future<Result<Set<InBandRegistrationForm>, XmppError>> requestForms(String domain) {
    return super.requestForms(domain);
  }

  @override
  @protected
  /// You shouldn't call this on the negotiator. Use [setFormHandler] to set a form handler instead, and return the filled form.
  /// See [InBandRegistrationNegotiator] for more information.
  Future<Result<bool, InBandRegistrationError<XmppError>>> submitForm(InBandRegistrationForm form, String domain) {
    return super.submitForm(form, domain);
  }

  @override
  @protected
  Future<XMLNode?> sendAwaitableNonza(XMLNode stanza) {
    final id = attributes.getConnection().generateId();
    stanza.attributes['id'] = id;
    _awaitedNonzas[id] = Completer<XMLNode?>();
    _resetCompleter(); // returns ready state from negotiate() so it can be called again when the next nonza comes in
    attributes.sendNonza(stanza);
    return _awaitedNonzas[id]!.future;
  }

  Future<Result<NegotiatorState, NegotiatorError>> _handleSuccess(InBandRegistrationForm form) async {
    final newJid = JID(form.username??'', attributes.getConnectionSettings().jid.domain, '');
    attributes.getConnection().connectionSettings = ConnectionSettings(jid: newJid, password: form.password??'');
    attemptRegistration = false;
    _inProgress = false;
    _formHandlers.clear();
    unawaited(attributes.sendEvent(InBandRegistrationSuccessEvent(newJid, form.password??'')));
    // Force reconnect so that the new credentials can be used.
    //_sendStreamHeaderWhenDone = true;
    //await attributes.getConnection().reconnectionPolicy.performReconnect?.call();
    return const Result(NegotiatorState.done);
  }

  void _resetCompleter() {
    if (!_currentCompleter.isCompleted) _currentCompleter.complete(const Result(NegotiatorState.ready));
    _currentCompleter = Completer<Result<NegotiatorState, NegotiatorError>>();
  }

  @override
  Future<Result<NegotiatorState, NegotiatorError>> negotiate(XMLNode nonza) async {
    /// Call this before every await to make sure the result can be received.
    if (_awaitedNonzas.isNotEmpty && _awaitedNonzas.containsKey(nonza.attributes['id'])) {
      _resetCompleter();
      // If we have an awaited nonza with this ID, complete it
      _awaitedNonzas[nonza.attributes['id']]!.complete(nonza);
      _awaitedNonzas.remove(nonza.attributes['id']);
      return _currentCompleter.future;
    }
    if (!attemptRegistration) return const Result(NegotiatorState.done);
    if (!_matched && attributes.getSocket().isSecure()) {
      _logger.severe('In-band registration was requested, but is not supported by the server!');
      return const Result(InBandRegistrationSkippedError());
    } else if (!_matched && !_waitingForSecure) {
      // If we are not matched, we can't register
      _logger.warning('The server is not secure and does not claim support for in-band registration. Waiting for server to become secure, then trying again.');
      _waitingForSecure = true;
      return const Result(NegotiatorState.retryLater);
    } else if (!_matched) {
      _logger.severe('Server insecure and does not support in-band registration, cannot register.');
      return const Result(InBandRegistrationSkippedError());
    }
    assert(_formHandlers.containsKey(InBandRegistrationDataForm), 'InBandRegistrationNegotiator must have a form handler for InBandRegistrationDataForm to work properly. '
        'You will not be able to register to many servers without it. '
        'If you did not intend to register, set attemptRegistration to false.');
    assert(_formHandlers.containsKey(OutOfBandRegistrationForm), 'InBandRegistrationNegotiator must have a form handler for OutOfBandRegistrationForm to work properly. '
        'You will not be able to register to many servers without it. '
        'If you did not intend to register, set attemptRegistration to false.');
    if (_inProgress) {
      // If we are already in progress, we should not start a new registration.
      // This is to prevent multiple registrations from being started at the same time.
      _logger.warning('In-band registration is already in progress, ignoring this request.');
      return const Result(NegotiatorState.ready);
    }
    _inProgress = true;
    unawaited((() async {
      // Start registration if we don't have any transactions in progress
      // Get registration forms
      final forms = await requestForms(attributes.getConnectionSettings().jid.domain);
      // Present the forms to the user
      if (forms.isType<XmppError>()) {
        // No forms available, so we can't register
        _logger.warning('Error when requesting registration forms', forms.get<XmppError>().toString());
        return _currentCompleter.complete(const Result(InBandRegistrationFailedError('No registration forms available from server.')));
      }
      final domain = attributes.getConnectionSettings().jid.domain;
      final result = await showForm(
        to: domain,
        forms: forms.get<Set<InBandRegistrationForm>>(),
        onDataForm: _getFormHandler<InBandRegistrationDataForm>()!,
        onOobForm: _getFormHandler<OutOfBandRegistrationForm>()!,
        onIqRegisterForm: _getFormHandler<SimpleInBandRegistrationForm>(),
        shouldCancel: () => !_inProgress || !attemptRegistration,
        onSuccess: (form) async {
          // If the form was successfully submitted, we can reset the connection and return done
          return _currentCompleter.complete(await _handleSuccess(form));
        },
      );
      // The negotiator post-processes this differently.
      // On success, we have to mark it as done.
      // We also have to handle error types if any occur.
      // The completer also has to be completed with the result,
      // otherwise it will lock up.
      if (result.isType<bool>() && !result.get<bool>()) {
        // Registration was cancelled
        _inProgress = false;
        return _currentCompleter.complete(const Result(NegotiatorState.done));
      } else if (result.isType<InBandRegistrationError<NegotiatorError>>()) {
        // Registration failed with an error
        final error = result.get<InBandRegistrationError<NegotiatorError>>();
        _logger.severe('Registration failed with error: $error');
        return _currentCompleter.complete(Result(error.error));
      } else {
        if (result.isType<bool>() && result.get<bool>()) {
          return; // onSuccess already completed the completer
        }
        if (result.get<dynamic>() case final Object error) {
          // Registration failed with an error that is not an InBandRegistrationError
          _logger.severe('Registration failed with error: $error');
          return _currentCompleter.completeError(error);
        }
      }
      _resetCompleter(); // this should be dead code
    })(),);
    return const Result(NegotiatorState.ready);
  }

  bool _sendStreamHeaderWhenDone = false;
  @override
  bool get sendStreamHeaderWhenDone => _sendStreamHeaderWhenDone;

  @override void reset() {
    _sendStreamHeaderWhenDone = false;
    _awaitedNonzas.clear();
    _inProgress = false;
    //attemptRegistration = false;
    super.reset();
  }
}

/// A manager that implements XEP-0077 In-Band Registration for registering to remote services,
/// such as gateways or other XMPP services that support in-band registration.
/// The entrypoint to using this manager is [registerWith].
/// 
/// > [!IMPORTANT]
/// > If you want to register with an XMPP IM server, use [InBandRegistrationNegotiator] instead.
/// > Read the documentation for `InBandRegistrationNegotiator` carefully to understand how it works.
class InBandRegistrationManager extends XmppManagerBase with InBandRegistrationMixin {
  InBandRegistrationManager()
      : super(inBandRegistrationManager);

  @override
  final _logger = Logger('InBandRegistrationManager');

  @override
  Future<XMLNode?> sendAwaitableNonza(XMLNode stanza) {
    return getAttributes().sendStanza(StanzaDetails(
      Stanza.fromXMLNode(stanza),
    ),);
  }
  
  @override
  FutureOr<void> cancelRegistration() {
    _cancelled = true;
    // No special process needed for managers; just stop retrying registration
  }

  bool _cancelled = false;

  /// An implementation of XEP-0077 In-Band Registration for registering to remote services,
  /// such as gateways or other XMPP services that support in-band registration.
  /// Result is true if the registration was successful, false if it was cancelled,
  /// or an [XmppError] if the registration failed.
  /// Pass the [jid] of the service to register with,
  /// and the [onDataForm], [onOobForm], and [onIqRegisterForm] callbacks to handle the registration forms.
  /// The callbacks should show the forms to the user and return the filled form.
  /// 
  /// > [!IMPORTANT]
  /// > If the service does not support in-band registration, the result will be an [InBandRegistrationSkippedError].
  Future<Result<bool, XmppError>> registerWith(JID jid, {
    /// Show the UI to handle data forms.
    required FormHandler<InBandRegistrationDataForm> onDataForm,
    /// Show the UI to handle out-of-band registration instructions.
    required FormHandler<OutOfBandRegistrationForm> onOobForm,
    /// Show the UI to handle iq:register forms.
    FormHandler<SimpleInBandRegistrationForm>? onIqRegisterForm,
  }) async {
    if (jid.domain.isEmpty) {
      return const Result(InBandRegistrationFailedError('JID domain cannot be empty for in-band registration.'));
    }
    if (!await isSupported()) {
      return const Result(InBandRegistrationSkippedError());
    }
    final forms = await requestForms(jid.toString());
    if (forms.isType<XmppError>()) {
      return Result(InBandRegistrationError(forms.get<XmppError>()));
    }
    return showForm(
      to: jid.toString(),
      forms: forms.get<Set<InBandRegistrationForm>>(),
      onDataForm: onDataForm,
      onOobForm: onOobForm,
      onIqRegisterForm: onIqRegisterForm,
      shouldCancel: () => _cancelled,
    );
  }
  
  @override
  Future<bool> isSupported() => getAttributes().getConnection().getDiscoManager()?.isFeatureSupported(inBandRegistrationXmlns) ?? Future.value(false);
}

extension InBandRegistrationExtension on XmppConnection {
  /// Returns the [InBandRegistrationNegotiator] for this connection.
  InBandRegistrationNegotiator? getInBandRegistrationNegotiator() => getNegotiatorById<InBandRegistrationNegotiator>(inBandRegistrationNegotiator);

  /// Returns the [InBandRegistrationManager] for this connection.
  InBandRegistrationManager? getInBandRegistrationManager() => getManagerById<InBandRegistrationManager>(inBandRegistrationManager);
}
