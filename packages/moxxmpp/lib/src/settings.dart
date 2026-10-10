import 'package:moxxmpp/src/jid.dart';

class ConnectionSettings {
  ConnectionSettings({
    required this.jid,
    required this.password,
    this.host,
    this.port,
    this.register = false,
  });

  /// The JID to authenticate as.
  final JID jid;

  /// The password to use during authentication.
  final String password;

  /// The host to connect to. Skips DNS resolution if specified.
  final String? host;

  /// The port to connect to. Skips DNS resolution if specified.
  final int? port;

  /// When true, negotiate XEP-0077 in-band registration after TLS instead of
  /// SASL (Conversations `Account.OPTION_REGISTER`).
  final bool register;

  /// The JID of the server we're connected to.
  JID get serverJid => JID('', jid.domain, '');
}
