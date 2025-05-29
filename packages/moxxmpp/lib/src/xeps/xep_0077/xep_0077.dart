import 'package:moxlib/moxlib.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:moxxmpp/src/xeps/xep_0077/errors.dart';
import 'package:moxxmpp/src/xeps/xep_0077/events.dart';
import 'package:moxxmpp/src/xeps/xep_0077/helpers.dart';

/// A function that handles an [InBandRegistrationForm] and returns the form to submit back to the server.
/// A client should use this in [InBandRegistrationNegotiator.setFormHandler] to show the registration form to the user and return the filled form.
typedef FormHandler = InBandRegistrationForm Function(InBandRegistrationForm form, {List<InBandRegistrationForm> alternatives, XmppError? lastError});

/// A marker to indicate that this negotiator is for XEP-0077 (In-Band Registration).
/// Mostly, this is a flag to tell [ClientToServerNegotiator] to accept incomplete authentication
/// during registration.
mixin InBandRegistrationNegotiatorInterface {
  bool get attemptRegistration;
}
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
  
  /// Whether or not to attempt registration.
  /// The client should set this before connecting to a server if it wants to register with it.
  @override
  bool attemptRegistration = false;
  bool _matched = false;

  final Map<Type, dynamic> _formHandlers = <Type, dynamic>{};

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
  void setFormHandler<T extends InBandRegistrationForm>(FormHandler formHandler) {
    _formHandlers[T] = formHandler;
  }

  @override
  bool matchesFeature(List<XMLNode> features) {
    final matched = features.any(
      (feature) => (feature.xmlns == inBandRegistrationXmlns || feature.xmlns == 'http://jabber.org/features/iq-register') && feature.tag == 'register',
    );
    _matched = matched;
    if (!matched && attemptRegistration) {
      return true;
    }
    return matched;
  }

  @override
  Future<Result<NegotiatorState, NegotiatorError>> negotiate(XMLNode nonza) async {
    if (attemptRegistration) {
      if (!_matched) {
        return Result(InBandRegistrationSkippedError());
      }
      // TODO: registration
      // Get initial form or registration fields, send it to the client to obtain the credentials
      return const Result(NegotiatorState.skipRest);
    } else {
      return const Result(NegotiatorState.done);
    }
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
