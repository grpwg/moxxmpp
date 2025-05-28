import 'package:meta/meta.dart';
import 'package:moxxmpp/moxxmpp.dart';

sealed class InBandRegistrationForm {
  @mustBeOverridden
  XMLNode toXml();
}

class SimpleInBandRegistrationForm extends InBandRegistrationForm {
  SimpleInBandRegistrationForm({
    this.data = const {},
    this.needed,
  });
  final Map<String, String> data;
  final List<String>? needed;

  bool isSatisfied() {
    if (needed == null || needed!.isEmpty) return true;
    for (final field in needed!) {
      if (!data.containsKey(field)) return false;
    }
    return true;
  }

  @override
  XMLNode toXml() {
    final children = <XMLNode>[];
    for (final entry in data.entries) {
      children.add(XMLNode(tag: entry.key, text: entry.value));
    }
    return XMLNode(tag: 'query', attributes: {'xmlns': 'jabber:iq:register'}, children: children);
  }
}

class InBandRegistrationDataForm extends InBandRegistrationForm {
  InBandRegistrationDataForm(this.form);

  final DataForm form;

  @override
  XMLNode toXml() => form.toXml();
}

class OutOfBandRegistrationForm extends InBandRegistrationForm {
  OutOfBandRegistrationForm(this.url);

  final String url;

  @override
  XMLNode toXml() => XMLNode(
        tag: 'x',
        attributes: {'xmlns': 'jabber:x:oob'},
        children: [
          XMLNode(tag: 'url', text: url),
        ],
      );
}
