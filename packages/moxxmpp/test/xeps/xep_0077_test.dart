import 'dart:convert';

import 'package:moxxmpp/moxxmpp.dart';
import 'package:test/test.dart';

void main() {
  test('simple registration (username + password children)', () {
    final query = XMLNode.fromString('''
<query xmlns='jabber:iq:register'>
  <username/><password/>
  <instructions>Choose a username and password</instructions>
</query>''');
    expect(parseRegistrationQuery(query), isA<SimpleRegistration>());
  });

  test('redirect via OOB https URL', () {
    final query = XMLNode.fromString('''
<query xmlns='jabber:iq:register'>
  <instructions>Visit the website</instructions>
  <x xmlns='jabber:x:oob'>
    <url>https://example.org/register</url>
  </x>
</query>''');
    final challenge = parseRegistrationQuery(query);
    expect(challenge, isA<RedirectRegistration>());
    expect(
      (challenge as RedirectRegistration).url.toString(),
      'https://example.org/register',
    );
  });

  test('extended registration with BOB captcha', () {
    final png = base64.encode([0x89, 0x50, 0x4e, 0x47]);
    final query = XMLNode.fromString('''
<query xmlns='jabber:iq:register'>
  <x xmlns='jabber:x:data' type='form'>
    <field var='FORM_TYPE' type='hidden'>
      <value>jabber:iq:register</value>
    </field>
    <field var='username' type='text-single'/>
    <field var='password' type='text-private'/>
    <field var='ocr' label='Enter the text'>
      <media xmlns='urn:xmpp:media-element'>
        <uri type='image/png'>cid:sha1+abc@bob.xmpp.org</uri>
      </media>
    </field>
  </x>
  <data xmlns='urn:xmpp:bob' cid='sha1+abc@bob.xmpp.org' type='image/png'>
    $png
  </data>
</query>''');
    final challenge = parseRegistrationQuery(query);
    expect(challenge, isA<ExtendedRegistration>());
    final ext = challenge as ExtendedRegistration;
    expect(ext.captchaBytes, [0x89, 0x50, 0x4e, 0x47]);
    expect(ext.form.getFieldByVar('ocr'), isNotNull);
  });

  test('submitRegistrationForm overrides username/password/ocr', () {
    final form = parseDataForm(
      XMLNode.fromString('''
<x xmlns='jabber:x:data' type='form'>
  <field var='FORM_TYPE' type='hidden'><value>jabber:iq:register</value></field>
  <field var='username' type='text-single'><value/></field>
  <field var='password' type='text-private'/>
  <field var='ocr' type='text-single'/>
  <field var='challenge' type='hidden'><value>tok</value></field>
</x>'''),
    );
    final submitted = submitRegistrationForm(form, {
      'username': 'alice',
      'password': 's3cret',
      'ocr': 'AB12',
    });
    expect(submitted.type, 'submit');
    expect(submitted.getFieldByVar('username')!.values, ['alice']);
    expect(submitted.getFieldByVar('password')!.values, ['s3cret']);
    expect(submitted.getFieldByVar('ocr')!.values, ['AB12']);
    expect(submitted.getFieldByVar('challenge')!.values, ['tok']);
    final xml = submitted.toSubmitXml().toXml();
    expect(xml, contains("type='submit'"));
    expect(xml, isNot(contains('text-single')));
  });

  test('registrationErrorFromIq maps conflict', () {
    final iq = XMLNode.fromString('''
<iq type='error' id='1'>
  <error type='cancel'>
    <conflict xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>
  </error>
</iq>''');
    final err = registrationErrorFromIq(iq);
    expect(err.conflict, isTrue);
  });
}
