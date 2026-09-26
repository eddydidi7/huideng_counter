# 藏历殊胜日与传统历俗（1.0.34 / 35）

## 本次内容

- 日期详情显示每月初八药师佛日、初十莲师荟供日、十五阿弥陀佛日、十八观世音菩萨日、二十一地藏菩萨日、二十五空行母荟供日、三十释迦牟尼佛日。
- 年度节日：正月十五神变节、四月初七佛诞、四月十五成道与涅槃、六月初四初转法轮、九月二十二天降日。
- 新增每日理发原文、洗头好/不好、年度理发特别说明、十一月初六/初七传统提醒。月历下方有当天说明卡和可展开的30天对照表。
- 用户提供的头发处理与咒语转写保留在完整对照表中，明确标为所供原文；未声称经过原典校勘。
- 本包也包含上一轮“后台发布”改名“共享文章”。

## 来源和区别

每月日期以藏历为准，不混用汉传农历纪念日。

- [Pathgate 宁玛传统修持日程](https://pathgate.org/index.php/17-schedules)：药师佛、莲师、阿弥陀佛、空行母、释迦牟尼佛等每月修持日。
- [慧灯禅修问答：挂经旗](https://huidengchanxiu.net/q%26a/999答疑专题/挂经旗/)：每月药师佛、莲师、阿弥陀佛、观世音、空行、释迦牟尼佛等纪念名。没有把不同说法中的功德倍数当成统一计算规则。
- [汉文百年藏历](https://zangli.yunser.com/)：二十一地藏菩萨日的历书标注；界面明确标为汉文藏历常见纪念名，不宣称所有藏传传承一致。
- [索达吉堪布《地藏经》英文讲记](https://khenposodargye.org/content/uploads/2023/07/Original-Vows-of-Ksitigarbha-Bodhisattva-Sutra-chapter4-lecture7-9-20230720.pdf)：四大佛教节日的藏历日期。
- [FPMT 所载喇嘛梭巴仁波切说明](https://fpmt.org/mandala/archives/older/mandala-issues-1990/april/creating-the-causes/)及[Sakya Centre 日程](https://www.glorioussakya.org/schedule/lunar-calendar/)明确列藏历四月初七佛诞。界面注明传统差异，没有称为所有宁玛寺院统一日期。
- [Chagdud Gonpa Odsal Ling](https://www.odsalling.org/en/eventos/saga-dawa-duchen-2025-en/)说明萨嘎达瓦合纪传统；该中心2025年佛诞活动为6月3日，但本 App 原日期表该日为四月初八，因此没有把这个活动公历日期作为四月初七换算锚点，也没有改写原日期表。
- 理发、洗头、年度吉凶、附咒：本次用户提供的全部文字。提供者归于《白琉璃论》及上师解释；尚未核对该书版本、原文页码或咒语音译。界面标为传统历俗，不当作医学或命运预测。

十二月二十五日“增长智慧”与每月二十五日通则不同，两个条目并列呈现，不擅自删除或调和。

## 日期处理

- 沿用现有2025—2026离线日期表，不修改公历/藏历换算，不扩大未经核验年份。
- 每月纪念日及每日理发、洗头说明在重日的两天均显示。
- 年度节日沿用现有逻辑：非闰月、重日第二次显示；没有公历对应日期的缺日不造日期、不自动迁移节日。
- 年度理发特别说明只用于普通月，闰月不推断；每月通则仍按该日的藏历日数显示。

## 文件与测试

新增 `lib/domain/calendar_observances.dart`（统一中英文资料）、`lib/presentation/calendar_traditions_panel.dart`、`test/calendar_observances_test.dart`、本文档。

修改 `lib/data/local/tibetan_calendar.dart`（增加佛诞标识）、`lib/presentation/tibetan_calendar_page.dart`（具体纪念名及说明面板）、`pubspec.yaml`（版本）。没有新增 package、SQLite 表、Supabase SQL 或云端配置。

6 项自动测试通过：30天完整性与洗头集合、年度例外、月/年节日与重日/闰月、原730天数据回归、小屏360×640与大屏412×915布局。静态分析无 error/warning，1条字符串插值括号简化 info。Android debug 构建成功，已覆盖安装 Xiaomi 14T；未把模拟布局测试当成手机日历逐日实点验收。

安装包：`releases/huideng-counter-v1.0.34-35-calendar-observances.apk`。没有卸载或清除用户数据。
