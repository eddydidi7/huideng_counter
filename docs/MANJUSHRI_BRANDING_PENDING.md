# 文殊计数器品牌更新（待打包）

中文：文殊计数器。英文：Manjushri Counter。

## 图稿
- assets/branding/manjushri-icon-master.png：image_gen正式纯图标原稿，1:1。
- assets/branding/manjushri-icon-1024.png：正式图标1024像素版本。
- assets/branding/manjushri-preview.png：图标加中文名称展示稿。
- MANJUSHRI_ICON_PROMPTS.json：使用内置image_gen的两条完整提示词。
- generate-brand-icons.ps1：仅做平台尺寸及文件格式转换，可重复运行。

## 接入
Android五组mipmap启动图标及中英文app_name；iOS AppIcon清单所需全部图标及Info.plist显示名；Windows app_icon.ico（16/24/32/48/64/128/256）及窗口/产品显示名。
Flutter主页、关于、设置、系统标题、分享文本、提醒App名称同步修改。
独立后台的中文页面标题、窗口标题、安装程序显示名同步修改；不修改其AppId/安装位置/程序文件名。

## 兼容性
保留org.huideng.huideng_counter安装包标识、huideng URL回调、Dart项目名、Windows二进制名、数据库/文件目录、Supabase配置。未做数据库迁移或删除数据。

## 验证
Flutter修改文件静态分析通过。Android/iOS清单图标逐项检查尺寸与iOS不透明背景；Windows ICO包含7个尺寸；XML可解析。
未生成APK、EXE或iOS安装包；手机桌面最终显示及系统图标缓存待统一打包升级后检查。
