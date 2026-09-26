# 农历日期显示

日历网格下方显示所选公历日期对应的农历，独立于藏历日期。文字使用与藏历标题一致的 titleMedium、蓝色 #64B5F6、w600。

离线数据：assets/calendar/chinese_lunar_2025_2026.json，覆盖2025—2026年，与现有藏历范围一致。
由 .NET System.Globalization.ChineseLunisolarCalendar 生成；GetLeapMonth 返回顺序月份，遇到闰月及其后月份须减一以获得显示月份。
来源说明：https://learn.microsoft.com/en-us/dotnet/api/system.globalization.chineselunisolarcalendar
对照资料：https://www.hko.gov.hk/en/gts/time/conversion.htm

已验证2025-01-29、2026-02-17春节，2025-07-25闰六月初一与2025-08-23七月初一。
2026-09-19为农历丙午马年八月初九，藏历为火马年八月初八，不能共用日期标签。

此版本农历采用内置离线数据；扩展年份需同时扩展数据覆盖范围。没有承诺日期算法通过后台更新。

## 当日介绍

农历下方按所选公历日期显示节日、节气。无内容时不占行；同一天多项内容合并。
二十四节气日期核对香港天文台对照表（2025、2026各24项）：
https://www.hko.gov.hk/tc/gts/time/calendar/text/files/T2025c.txt
https://www.hko.gov.hk/tc/gts/time/calendar/text/files/T2026c.txt
节日按公历固定日期或非闰月农历日期匹配；除夕用农历春节前一天，兼容腊月29天。
这里只标节日，不代表国务院公布的放假、补班日期。

后台入口：藏历内容管理 → 农历下方：节日、节气与当天介绍。按日期编辑中文/英文，保存并发布。清空该日文字即可隐藏。
数据在 calendar_traditions.chinese_events 中，沿用 links.save、版本冲突检查、审计和手机离线缓存。
首次启用新客户端后，介绍文字可通过后台继续更新。日期计算和2025—2026覆盖范围保持不变。
034脚本只增加可选字段校验，不覆盖现有内容。
