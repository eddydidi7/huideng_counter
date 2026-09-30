import 'package:flutter_test/flutter_test.dart';
import 'package:huideng_counter/domain/email_suggest.dart';

void main() {
  test('no suggestions before an @ is typed', () {
    expect(emailDomainSuggestions('someone'), isEmpty);
  });

  test('suggests common domains once @ is typed with nothing after', () {
    final s = emailDomainSuggestions('someone@');
    expect(s, contains('someone@qq.com'));
    expect(s, contains('someone@gmail.com'));
    expect(s.length, lessThanOrEqualTo(6));
  });

  test('narrows suggestions as the domain is typed', () {
    expect(emailDomainSuggestions('a@q'), ['a@qq.com']);
    expect(emailDomainSuggestions('a@g'), ['a@gmail.com']);
    expect(emailDomainSuggestions('a@1'), ['a@163.com', 'a@126.com']);
  });

  test('does not suggest a domain the user already typed exactly', () {
    expect(emailDomainSuggestions('a@qq.com'), isEmpty);
  });

  test('flags common domain typos without auto-changing the input', () {
    expect(emailTypoSuggestion('a@gmail.con'), 'a@gmail.com');
    expect(emailTypoSuggestion('a@gmial.com'), 'a@gmail.com');
    expect(emailTypoSuggestion('a@hotmai.com'), 'a@hotmail.com');
    expect(emailTypoSuggestion('a@qq.com'), isNull);
    expect(emailTypoSuggestion('a@mycompany.com'), isNull);
  });

  test('normalizeEmail trims and lower-cases only the domain', () {
    expect(normalizeEmail('  MyName@Example.COM '), 'MyName@example.com');
  });

  test('sameEmail ignores surrounding whitespace and domain case', () {
    expect(sameEmail('a@Example.com', ' a@example.COM '), isTrue);
    expect(sameEmail('a@example.com', 'b@example.com'), isFalse);
    expect(sameEmail('A@example.com', 'a@example.com'), isFalse);
  });
}
