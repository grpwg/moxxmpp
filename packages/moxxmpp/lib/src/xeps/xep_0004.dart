import 'package:collection/collection.dart';
import 'package:moxxmpp/src/namespaces.dart';
import 'package:moxxmpp/src/stringxml.dart';

class DataFormOption {
  const DataFormOption({required this.value, this.label});
  final String? label;
  final String value;

  XMLNode toXml() {
    return XMLNode(
      tag: 'option',
      attributes: {
        if (label != null) 'label': label,
      },
      children: [
        XMLNode(
          tag: 'value',
          text: value,
        ),
      ],
    );
  }
}

class DataFormField {
  const DataFormField({
    required this.options,
    required this.values,
    required this.isRequired,
    this.varAttr,
    this.type,
    this.description,
    this.label,
  });
  final String? description;
  final bool isRequired;
  final List<String> values;
  final List<DataFormOption> options;
  final String? type;
  final String? varAttr;
  final String? label;

  XMLNode toXml() {
    return XMLNode(
      tag: 'field',
      attributes: <String, dynamic>{
        if (varAttr != null) 'var': varAttr,
        if (type != null) 'type': type,
        if (label != null) 'label': label,
      },
      children: [
        if (description != null)
          XMLNode(
            tag: 'desc',
            text: description,
          ),
        if (isRequired)
          XMLNode(
            tag: 'required',
          ),
        ...values.map((value) => XMLNode(tag: 'value', text: value)),
        ...options.map((option) => option.toXml()),
      ],
    );
  }
}

class DataForm {
  const DataForm({
    required this.type,
    required this.instructions,
    required this.fields,
    required this.reported,
    required this.items,
    this.title,
  });

  /// A Data Form of type `form`, which has fields to fill out.
  /// Typically, these come from the server.
  const DataForm.form({
    required this.fields,
    required this.instructions,
    this.title,
  })  : type = 'form',
        reported = const [],
        items = const [];

  /// A Data Form of type `submit`, which has filled-out fields.
  /// Typically, these are sent to the server.
  const DataForm.submit({
    required this.fields,
  })  : type = 'submit',
        instructions = const [],
        reported = const [],
        items = const [],
        title = null;

  /// A Data Form of type `cancel`.
  /// 
  /// XEP-0004 describes this form type as:
  /// > The form-submitting entity has cancelled submission of data to the form-processing entity.
  /// 
  /// ...and nothing more.
  const DataForm.cancel()
      : type = 'cancel',
        instructions = const [],
        fields = const [],
        reported = const [],
        items = const [],
        title = null;

  /// A Data Form of type `result`, which contains the results of a form submission.
  /// Typically, these are received from the server after submitting a form.
  /// This type also contains `reported` and `items`. You'll want to read section 3.4
  /// of XEP-0004 for more information on how these are used.
  const DataForm.result({
    this.fields = const [],
    this.instructions = const [],
    this.reported = const [],
    this.items = const [],
    this.title,
  }) : type = 'result';

  final String type;
  final String? title;
  final List<String> instructions;
  final List<DataFormField> fields;
  final List<DataFormField> reported;
  final List<List<DataFormField>> items;

  DataFormField? getFieldByVar(String varAttr) {
    return fields.firstWhereOrNull((field) => field.varAttr == varAttr);
  }

  XMLNode toXml() {
    return XMLNode.xmlns(
      tag: 'x',
      xmlns: dataFormsXmlns,
      attributes: {'type': type},
      children: [
        ...instructions.map((i) => XMLNode(tag: 'instruction', text: i)),
        ...title != null ? [XMLNode(tag: 'title', text: title)] : [],
        ...fields.map((field) => field.toXml()),
        ...reported.map((report) => report.toXml()),
        ...items.map(
          (item) => XMLNode(
            tag: 'item',
            children: item.map((i) => i.toXml()).toList(),
          ),
        ),
      ],
    );
  }
}

DataFormOption _parseDataFormOption(XMLNode option) {
  return DataFormOption(
    label: option.attributes['label'] as String?,
    value: option.firstTag('value')!.innerText(),
  );
}

DataFormField _parseDataFormField(XMLNode field) {
  final desc = field.firstTag('desc')?.innerText();
  final isRequired = field.firstTag('required') != null;
  final values = field.findTags('value').map((i) => i.innerText()).toList();
  final options = field.findTags('option').map(_parseDataFormOption).toList();

  return DataFormField(
    varAttr: field.attributes['var'] as String?,
    type: field.attributes['type'] as String?,
    options: options,
    values: values,
    isRequired: isRequired,
    description: desc,
  );
}

/// Parse a Data Form declaration.
DataForm parseDataForm(XMLNode x) {
  assert(x.attributes['xmlns'] == dataFormsXmlns, 'Invalid element xmlns');
  assert(x.tag == 'x', 'Invalid element name');

  final type = x.attributes['type']! as String;
  final title = x.firstTag('title')?.innerText();
  final instructions =
      x.findTags('instructions').map((i) => i.innerText()).toList();
  final fields = x.findTags('field').map(_parseDataFormField).toList();
  final reported = x
          .firstTag('reported')
          ?.findTags('field')
          .map((i) => _parseDataFormField(i.firstTag('field')!))
          .toList() ??
      [];
  final items = x
      .findTags('item')
      .map((i) => i.findTags('field').map(_parseDataFormField).toList())
      .toList();

  return DataForm(
    type: type,
    instructions: instructions,
    fields: fields,
    reported: reported,
    items: items,
    title: title,
  );
}
