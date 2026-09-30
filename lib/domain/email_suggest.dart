/// Email domain quick-pick and typo-correction for the registration form.
/// Pure logic, no Flutter dependency, so it's cheap to unit test.
library;

const commonEmailDomains = [
  // China-first, per product requirement.
  'qq.com',
  '163.com',
  '126.com',
  'sina.com',
  'sohu.com',
  'aliyun.com',
  'gmail.com',
  'outlook.com',
  'hotmail.com',
  'icloud.com',
  'yahoo.com',
];

const _domainTypoFixes = {
  'gmial.com': 'gmail.com',
  'gmai.com': 'gmail.com',
  'gmail.con': 'gmail.com',
  'gamil.com': 'gmail.com',
  'gmail.comm': 'gmail.com',
  'gmall.com': 'gmail.com',
  'hotmai.com': 'hotmail.com',
  'hotmial.com': 'hotmail.com',
  'hotmail.con': 'hotmail.com',
  'hotmali.com': 'hotmail.com',
  'outlok.com': 'outlook.com',
  'outllok.com': 'outlook.com',
  'outlook.con': 'outlook.com',
  'qq.con': 'qq.com',
  'qq.cm': 'qq.com',
  'qq.comm': 'qq.com',
  '163.con': '163.com',
  '163.cm': '163.com',
  '126.con': '126.com',
  '126.cm': '126.com',
  'icloud.con': 'icloud.com',
  'iclound.com': 'icloud.com',
  'yaho.com': 'yahoo.com',
  'yahoo.con': 'yahoo.com',
  'aliyun.con': 'aliyun.com',
  'sohu.con': 'sohu.com',
  'sina.con': 'sina.com',
};

/// Up to 6 full-address suggestions for the dropdown below the email field,
/// filtered by whatever the user has typed after '@' so far. Returns nothing
/// until the user has typed a local part and an '@', so the list never shows
/// before it's useful.
List<String> emailDomainSuggestions(String input) {
  final at = input.indexOf('@');
  if (at <= 0) return const [];
  final local = input.substring(0, at);
  final typed = input.substring(at + 1).trim().toLowerCase();
  final matches = commonEmailDomains
      .where((d) => typed.isEmpty || d.startsWith(typed))
      .where((d) => d != typed)
      .toList();
  return matches.take(6).map((d) => '$local@$d').toList();
}

/// A suggested fix for a likely-misspelled domain, or null. Callers must
/// only ever offer this as a tap-to-accept suggestion, never auto-apply it.
String? emailTypoSuggestion(String input) {
  final at = input.indexOf('@');
  if (at <= 0) return null;
  final local = input.substring(0, at);
  final domain = input.substring(at + 1).trim().toLowerCase();
  final fix = _domainTypoFixes[domain];
  if (fix == null || fix == domain) return null;
  return '$local@$fix';
}

/// Normalizes an address for storage/comparison: trims surrounding
/// whitespace and lower-cases only the domain (the local part is left as
/// typed, matching normal mail semantics where the local part may be
/// case-sensitive in principle even though most providers ignore case).
String normalizeEmail(String input) {
  final trimmed = input.trim();
  final at = trimmed.indexOf('@');
  if (at < 0) return trimmed;
  return '${trimmed.substring(0, at)}@${trimmed.substring(at + 1).toLowerCase()}';
}

/// True when two addresses should be treated as "the same", per
/// [normalizeEmail]'s rules.
bool sameEmail(String a, String b) => normalizeEmail(a) == normalizeEmail(b);
