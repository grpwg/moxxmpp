import 'package:moxlib/moxlib.dart';
import 'package:moxxmpp/moxxmpp.dart';
import 'package:moxxmpp/src/xeps/xep_0077/errors.dart';
import 'package:moxxmpp/src/xeps/xep_0077/events.dart';
import 'package:moxxmpp/src/xeps/xep_0077/helpers.dart';

/// A function that handles an [InBandRegistrationForm] and returns the form to submit back to the server.
/// A client should use this 
typedef FormHandler = InBandRegistrationForm Function(InBandRegistrationForm form, [List<InBandRegistrationForm> alternatives]);

/// A marker to indicate that this negotiator is for XEP-0077 (In-Band Registration).
/// Mostly, this is a flag to tell [ClientToServerNegotiator] to accept incomplete authentication
/// during registration.
mixin InBandRegistrationNegotiatorInterface {
  bool get attemptRegistration;
}
/// A negotiator that implements XEP-0077 In-Band Registration for registering to an XMPP instant messaging server,
/// according to [XEP-0077 section 3.1](https://xmpp.org/extensions/xep-0077.html#usecases-register).
/// Set [attemptRegistration] to `true` before connecting to a server to switch to registration behaviors. 
/// If the server does not support in-band registration, negotiation (and therefore the connection) will fail with an [InBandRegistrationSkippedError].
class InBandRegistrationNegotiator extends XmppFeatureNegotiatorBase with InBandRegistrationNegotiatorInterface {
  InBandRegistrationNegotiator()
      : super(200, false, inBandRegistrationXmlns, inBandRegistrationNegotiator);
  
  /// Whether or not to attempt registration.
  /// The client should set this before connecting to a server if it wants to register with it.
  @override
  bool attemptRegistration = false;
  bool _matched = false;

  final Map<Type, dynamic> _formHandlers = <Type, dynamic>{};

  /// Register a form handler that will be called when the server sends a registration form.
  /// Only the most recent handler of each type will be used. The type of handler will be picked
  /// based on the precedence order in XEP-0077 Section 6 (as of XEP version 2.4).
  /// 
  /// If [OutOfBandRegistrationForm] is returned, the connection will be closed without reconnecting,
  /// and the client MUST return to the login screen themselves.
  /// 
  /// For other return types, the [InBandRegistrationNegotiator] will submit the form. If it succeeds,
  /// the connection will be reset and the client will be logged in with the new credentials.
  /// The new credentials will be sent with an [InBandRegistrationSuccessEvent] so that the client can
  /// persist them however you like.
  void registerFormHandler<T extends InBandRegistrationForm>(FormHandler formHandler) {
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
