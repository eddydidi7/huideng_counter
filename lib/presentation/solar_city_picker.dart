import 'package:flutter/material.dart';
import '../domain/solar_cities.dart';

class SolarCityPicker extends StatefulWidget {
  const SolarCityPicker({super.key, required this.english});
  final bool english;
  @override
  State<SolarCityPicker> createState() => _SolarCityPickerState();
}

class _SolarCityPickerState extends State<SolarCityPicker> {
  String query = '';
  String? country;
  String tr(String zh, String en) => widget.english ? en : zh;
  @override
  Widget build(BuildContext context) {
    final cities = findSolarCities(query, country: country);
    final countries = {for (final c in solarCities) c.country: c.countryZh};
    return Scaffold(
      appBar: AppBar(title: Text(tr('选择地区', 'Choose region'))),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  TextField(
                    key: const ValueKey('solar-city-search'),
                    decoration: InputDecoration(
                      labelText: tr('搜索城市/地区', 'Search city or region'),
                      prefixIcon: const Icon(Icons.search),
                    ),
                    onChanged: (v) => setState(() {
                      query = v;
                      country = null;
                    }),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey(country),
                    initialValue: country ?? '',
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: tr('国家/地区', 'Country or region'),
                    ),
                    items: [
                      DropdownMenuItem(value: '', child: Text(tr('全部', 'All'))),
                      for (final c in countries.entries)
                        DropdownMenuItem(
                          value: c.key,
                          child: Text(widget.english ? c.key : c.value),
                        ),
                    ],
                    onChanged: (v) =>
                        setState(() => country = v == '' ? null : v),
                  ),
                ],
              ),
            ),
            Expanded(
              child: cities.isEmpty
                  ? Center(
                      child: Text(
                        tr(
                          '未找到该地区，可返回手动填写经纬度。',
                          'No match. Use coordinates on the previous page.',
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: cities.length,
                      itemBuilder: (ctx, i) {
                        final city = cities[i];
                        return ListTile(
                          title: Text(city.label(widget.english)),
                          subtitle: Text('${city.name} · ${city.timezone}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.pop(context, city),
                        );
                      },
                    ),
            ),
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'GeoNames · CC BY 4.0',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
