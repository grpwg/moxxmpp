import 'package:moxxmpp/src/negotiators/negotiator.dart';

/// If registration was supposed to happen, but did not.
class InBandRegistrationSkippedError implements NegotiatorError {
  @override
  bool isRecoverable() => false;

  @override
  String toString() => 'InBandRegistrationSkippedError: Registration requested but not supported by server.';
}
