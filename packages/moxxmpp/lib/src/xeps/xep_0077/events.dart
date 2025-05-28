import 'package:moxxmpp/moxxmpp.dart';
import 'package:moxxmpp/src/events.dart';

class InBandRegistrationSuccessEvent extends XmppEvent {
  /// Creates an event that indicates that in-band registration was successful.
  InBandRegistrationSuccessEvent(this.jid, this.password);

  /// The JID used for registration.
  final JID jid;

  /// The password used for registration.
  final String password;

  @override
  String toString() => 'InBandRegistrationSuccessEvent(jid: $jid)';
}
