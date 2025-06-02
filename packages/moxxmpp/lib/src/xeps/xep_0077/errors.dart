import 'package:moxxmpp/src/negotiators/negotiator.dart';
import 'package:moxxmpp/src/stanza.dart';
import 'package:moxxmpp/src/stringxml.dart';

/// If registration was supposed to happen, but did not.
class InBandRegistrationSkippedError implements NegotiatorError {
  @override
  bool isRecoverable() => false;

  @override
  String toString() => 'InBandRegistrationSkippedError: Registration requested but not supported by server.';
}

class InBandRegistrationFailedError implements NegotiatorError {
  const InBandRegistrationFailedError(this.reason);

  /// The reason why the registration failed.
  final String reason;

  @override
  bool isRecoverable() => false;

  @override
  String toString() => 'InBandRegistrationFailedError: $reason';
}

class InBandRegistrationInvalidFormError implements NegotiatorError {
  const InBandRegistrationInvalidFormError([this.reason]);

  /// For pre-checked errors of type "modify".
  factory InBandRegistrationInvalidFormError.fromStanza(XMLNode stanza) {
    final error = stanza.tag == "error" ? stanza : stanza.firstTag("error")!;
    if (error.firstTag('text') case final XMLNode text) {
      return InBandRegistrationInvalidFormError(text.text);
    } else {
      return const InBandRegistrationInvalidFormError();
    }
  }

  /// The reason why the form is invalid.
  final String? reason;

  @override
  bool isRecoverable() => false;

  @override
  String toString() => 'InBandRegistrationInvalidFormError${reason != null ? ': $reason' : ''}';
}

class InBandRegistrationStanzaError implements NegotiatorError {
  const InBandRegistrationStanzaError(this.error);

  final StanzaError error;

  @override
  bool isRecoverable() => false;

  @override
  String toString() => 'InBandRegistrationStanzaError: $error';
}

/// The server said that the requested username is already in use.
class InBandRegistrationConflictError implements NegotiatorError {
  const InBandRegistrationConflictError();

  @override
  bool isRecoverable() => false;

  @override
  String toString() => 'InBandRegistrationConflictError: Username already in use.';
}