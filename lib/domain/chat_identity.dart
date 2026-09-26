String personalNumberLabel(Map person, {bool english = false}) {
  final number = person['personal_number']?.toString();
  final valid = number != null && RegExp(r'^\d{4,}$').hasMatch(number);
  return '${english ? 'Personal number' : '个人号'}：${valid
      ? number
      : english
      ? 'Not set'
      : '未设置'}';
}
