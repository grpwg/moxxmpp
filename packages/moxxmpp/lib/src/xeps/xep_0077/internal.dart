import 'package:meta/meta.dart';
import 'package:moxxmpp/src/xeps/xep_0077/helpers.dart';

@protected
class InBandRegistrationTransaction {
  InBandRegistrationTransaction(this.id, {this.form, this.originalForm});

  final InBandRegistrationForm? form;
  final InBandRegistrationForm? originalForm;
  final String id;
}
