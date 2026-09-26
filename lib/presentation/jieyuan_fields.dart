import 'package:flutter/material.dart';

Map<String, dynamic> newJieyuan() => {
  'type': 'free',
  'status': 'available',
  'quantity': 1,
  'condition': 'used',
  'delivery': 'both',
  'postage': 'discuss',
  'currency': 'CNY',
  'country': '',
  'region': '',
};
const jieyuanTypes = {'free': '免费结缘', 'paid': '有偿转让', 'wanted': '求结缘'};
const jieyuanStates = {
  'available': '可结缘',
  'reserved': '已预留',
  'completed': '已结缘',
};
String jieyuanSummary(Map j) =>
    '${j['type'] == 'paid' ? '${j['currency']} ${j['price']}' : jieyuanTypes[j['type']] ?? ''} · ${jieyuanStates[j['status']] ?? ''}';

class JieyuanFields extends StatelessWidget {
  const JieyuanFields({
    super.key,
    required this.value,
    required this.onChanged,
    this.editing = false,
    this.enabled = true,
    this.currencies = const ['CNY', 'NZD', 'AUD', 'USD'],
  });
  final Map<String, dynamic> value;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final bool editing;
  final bool enabled;
  final List<String> currencies;
  @override
  Widget build(BuildContext context) {
    void set(String key, dynamic v) => onChanged({...value, key: v});
    Widget choice(String key, String label, Map<String, String> options) =>
        DropdownButtonFormField<String>(
          key: ValueKey(key),
          initialValue: options.containsKey(value[key])
              ? value[key]
              : options.keys.first,
          decoration: InputDecoration(labelText: label),
          isExpanded: true,
          items: options.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: (v) => set(key, v),
        );
    Widget text(String key, String label, {bool number = false}) =>
        TextFormField(
          key: ValueKey(key),
          initialValue: '${value[key] ?? ''}',
          decoration: InputDecoration(labelText: label),
          keyboardType: number
              ? const TextInputType.numberWithOptions(decimal: true)
              : TextInputType.text,
          maxLength: number ? 12 : 80,
          onChanged: (v) => set(key, key == 'quantity' ? int.tryParse(v) : v),
        );
    return AbsorbPointer(
      absorbing: !enabled,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          choice('type', '结缘类型', jieyuanTypes),
          if (editing) choice('status', '状态', jieyuanStates),
          if (value['type'] == 'paid')
            Row(
              children: [
                Expanded(child: text('price', '价格', number: true)),
                const SizedBox(width: 12),
                Expanded(
                  child: choice('currency', '币种', {
                    for (final c in currencies) c: c,
                  }),
                ),
              ],
            ),
          Row(
            children: [
              Expanded(
                child: choice('condition', '新旧', const {
                  'new': '全新',
                  'like_new': '近新',
                  'used': '使用过',
                }),
              ),
              const SizedBox(width: 12),
              Expanded(child: text('quantity', '数量', number: true)),
            ],
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('地区与交付'),
            children: [
              text('country', '国家'),
              text('region', '城市/地区（不填家庭地址）'),
              choice('delivery', '交付方式', const {
                'meet': '当面结缘',
                'post': '可以邮寄',
                'both': '都可以',
              }),
              choice('postage', '邮费', const {
                'included': '包邮',
                'extra': '邮费另计',
                'discuss': '双方协商',
              }),
            ],
          ),
          const Text(
            '优先通过 App 私聊联系。仅发布有权分享的物品和资料。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}
