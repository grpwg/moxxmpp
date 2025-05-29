import 'package:meta/meta.dart';
import 'package:moxxmpp/src/xeps/xep_0077/helpers.dart';

@protected
class InBandRegistrationTransaction {
  InBandRegistrationTransaction(this.id, {this.form});

  final InBandRegistrationForm? form;
  final String id;
}
