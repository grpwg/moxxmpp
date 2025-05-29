import 'package:meta/meta.dart';
import 'package:moxxmpp/moxxmpp.dart';

sealed class InBandRegistrationForm {
  @mustBeOverridden
  XMLNode toXml();

  @mustBeOverridden
  InBandRegistrationForm copyWith({
    String? username,
    String? password,
  });

  @mustBeOverridden
  String? get username;
  @mustBeOverridden
  String? get password;
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

  @override
  SimpleInBandRegistrationForm copyWith({String? username, String? password}) {
    return SimpleInBandRegistrationForm(
      data: {...data,
        if (username != null) 'username': username,
        if (password != null) 'password': password,
      },
      needed: needed,
    );
  }

  @override
  String? get username => data['username'];
  @override
  String? get password => data['password'];
}

class InBandRegistrationDataForm extends InBandRegistrationForm {
  InBandRegistrationDataForm(this.form);

  final DataForm form;

  @override
  XMLNode toXml() => form.toXml();
  
  @override
  InBandRegistrationDataForm copyWith({String? username, String? password}) {
    final newForm = parseDataForm(form.toXml());
    if (username != null) {
      newForm.fields.removeWhere((field) => field.varAttr == 'username');
      newForm.fields.add(DataFormField(varAttr: 'username', values: [username], isRequired: false, options: []));
    }
    if (password != null) {
      newForm.fields.removeWhere((field) => field.varAttr == 'password');
      newForm.fields.add(DataFormField(varAttr: 'password', values: [password], isRequired: false, options: []));
    }
    return InBandRegistrationDataForm(newForm);
  }
  
  @override
  String? get password => form.getFieldByVar('password')?.values.first;

  @override
  String? get username => form.getFieldByVar('username')?.values.first;
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
  
  @override
  OutOfBandRegistrationForm copyWith({String? username, String? password}) {
    return OutOfBandRegistrationForm(url);
  }

  @override
  String? get username => null;
  @override
  String? get password => null;
}

(InBandRegistrationDataForm?, SimpleInBandRegistrationForm, OutOfBandRegistrationForm?) parseRegistrationForm(XMLNode node) {
  // Compose data form
  final dataFormTag = node.firstTag('x', xmlns: dataFormsXmlns) ?? (node.tag == 'x' && node.xmlns == dataFormsXmlns
      ? node
      : null);
  final dataForm = dataFormTag != null
      ? parseDataForm(dataFormTag)
      : null;
  // Compose out-of-band registration data
  final oobFormTag = node.firstTag('x', xmlns: oobDataXmlns) ?? (node.tag == 'x' && node.xmlns == oobDataXmlns
      ? node
      : null);
  final oobData = oobFormTag?.firstTag('url')?.innerText();
  // Compose iq:register form
  final neededFields = <String>[];
  final prefilledFields = <String, String>{};
  for (final field in node.children) {
    if (field.xmlns case null || inBandRegistrationXmlns) {
      neededFields.add(field.tag);
      if (field.innerText().isNotEmpty) {
        // If the field has a value, prefill it
        prefilledFields[field.tag] = field.innerText();
      }
    }
  }
  final iqRegisterForm = SimpleInBandRegistrationForm(
    data: prefilledFields,
    needed: neededFields,
  );
  final dataFormForm = dataForm != null
      ? InBandRegistrationDataForm(dataForm)
      : null;
  final oobDataForm = oobData != null
      ? OutOfBandRegistrationForm(oobData)
      : null;
  return (dataFormForm, iqRegisterForm, oobDataForm);
}
