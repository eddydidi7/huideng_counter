# 语音消息与一对一通话：1.0.37+38

## 本次范围
仅聊天语音及必要的应用级来电入口、权限、依赖。计数、笔记、藏历数据表不变。SQLite 沿用原聊天缓存和发送队列，不删库，不清理用户文件。

## 实现
- 对话输入区麦克风/键盘切换；长按录音、松开发送、上滑取消，500ms～60s。
- 首次授权期间松手不自动录音/发送；页面退出、应用进入后台、来电取消当前录音。
- Android 支持时录制 Opus/Ogg，其他平台或不支持的设备使用 AAC/M4A，避免 iOS CAF/Opus 跨平台不兼容。
- 文件先保存到应用私有目录，消息与文件使用固定 UUID，入原 SQLite outbox。失败保留文件和队列，沿用重试机制。
- 私有 Supabase Storage `chat-voice`，最大10MiB。数据库只存对象引用、时长、大小、格式等元数据。
- 点击播放、时长、未播放点、本机播放状态保存，自动连续播放当前已加载消息中下一条未播放的收到语音。只播放本会话，切后台/来电停止。旧消息未加载时需先加载历史。
- 单聊顶部电话入口，前台来电覆盖页，接听/拒绝/挂断、静音、扬声器、连接后计时。
- WebRTC 音频、Opus优先/FEC协商请求、回声消除/降噪/自动增益请求。平台是否真正启用和通话音质仍需真机检查。
- 私有 Realtime 变更通知唤醒 RPC；2秒轮询补偿丢失通知；音频不存数据库。
- 网络状态来自 RTP 丢包、抖动和候选对 RTT；弱网请求降低音频码率，受原生平台支持限制。
- 断连后有界 ICE 重试，最长60秒；无 TURN 且直连失败明确提示，不显示成功。
- 同一来电单设备接听、忙线保护、成员校验、拉黑保护、信令UUID幂等。

## 当前边界
- OSS/COS/R2 均未接入本次语音路径；当前真实文件路径只有 Supabase Storage。中国大陆连通质量需实测。
- 没有 TURN 服务器。已实现 `voice-config` 短期 coturn REST 凭证签发代码和 ICE 配置接入；函数尚未部署，不能称为 TURN 已工作。
- 函数支持 CN/GLOBAL 两组节点，区域缺省根据可用边缘国家头排序，否则提供两组由 ICE 选择。没有验证大陆节点或地理识别质量。
- 首版只保证前台实现路径；系统 Push、锁屏来电、Android前台通话服务/iOS CallKit/PushKit 未实现。
- 未实施云端录音、视频通话、多人语音。
- 尚未建立历史信令自动清理作业、孤立未提交语音对象清理作业；不擅自删除任何对象。

## 修改文件
- `pubspec.yaml`, `pubspec.lock`: record 7.1.1、audioplayers 6.8.1，版本1.0.37+38；平台插件注册文件由 Flutter 生成。
- `lib/main.dart`: 应用级来电容器。
- `lib/presentation/chat_room_page.dart`: 录音输入、语音气泡、电话入口。
- `lib/data/repositories/chat_repository.dart`: 发送队列语音分支。
- `android/app/src/main/AndroidManifest.xml`: RECORD_AUDIO、MODIFY_AUDIO_SETTINGS。
- `ios/Runner/Info.plist`: 麦克风用途说明，iOS未编译实测。
- `supabase/config.toml`: voice-config JWT由函数内 Auth getUser验证。

## 新增文件
- `lib/services/chat_voice_storage.dart`
- `lib/services/chat_audio_focus.dart`
- `lib/services/voice_call_service.dart`
- `lib/domain/voice_sdp.dart`
- `lib/presentation/chat_voice_widgets.dart`
- `lib/presentation/voice_call_host.dart`
- `supabase/migrations/202609170019_chat_voice.sql`
- `supabase/functions/voice-config/index.ts`
- `supabase/functions/voice-config/turn.ts`
- `test/voice_sdp_test.dart`
- `test/voice_recording_test.dart`
- 工作区 `work/admin-sql-tests/chat-voice.mjs`、`voice-turn.mjs`

## Supabase
019新增：chat_voice_files、chat_calls、chat_call_signals。
chat_messages新增 voice_file_id、voice_duration_ms、voice_file_size、voice_storage_provider。
函数：chat_voice_user_active、chat_voice_v1、chat_call_member、chat_call_v1。
RLS：仅成员读取语音/通话；语音撤回后下载不可用；写入走验证身份的 RPC；未登录不能调用。
存储：chat-voice 私有桶，audio/ogg、audio/mp4，10MiB。
Realtime：已有 supabase_realtime publication 时脚本加入 chat_calls/chat_call_signals。
用户已回复“019成功”；实际云端未登录调用 chat_call_v1 返回42501权限拒绝，证明接口已存在且匿名禁止调用。这不等于已登录端到端测试。

## TURN 部署（有服务器后）
1. 部署 coturn，域名与TLS证书、UDP/TCP3478、TLS5349、限定的中继UDP端口范围和防火墙同步配置；拒绝私网、回环和元数据目标，设置带宽/并发限制与监控。
2. 启用 use-auth-secret、static-auth-secret、realm，生成至少32字符随机共享密钥，仅存服务器和 Edge Function secrets。
3. Edge secrets：CN_TURN_URLS/CN_TURN_SECRET、GLOBAL_TURN_URLS/GLOBAL_TURN_SECRET。URL逗号分隔，例如 turn:域名:3478?transport=udp,turns:域名:5349?transport=tcp。
4. 在项目目录部署 `supabase functions deploy voice-config --project-ref duakhsuncmbabxomynkr`。函数内使用 Auth getUser 验证 token 和019的活跃用户检查，禁止改成免登录发凭证。
5. 只返回15分钟有效的用户名/签名，长期共享密钥不进APK。没有服务器配置时返回 turnConfigured=false。
6. 强制 relay 的专用测试构建验证实际 candidateType=relay，再验证恢复正常 ICE 策略。不要仅用“能接通”推断TURN成功。

## 已完成的自动验证
- 录音权限交互：2项通过，授权弹窗中先松手，再允许/拒绝权限，均不会开始录音或发送。测试替身原先启动了登录刷新定时器导致测试清理等待，改为隔离替身后通过。
- 原聊天回归+Opus SDP：8项通过（队列、UUID重试、账号隔离、缓存升级、草稿、排序、图片压缩、Opus协商）。
- 本地 PostgreSQL兼容执行（PGlite）：原聊天/好友/隐私回归，以及语音所有权、私有读取、撤回下载拒绝、重复UUID、通话忙线、单设备接听、信令幂等、非法offer方向、结束通话、拉黑、匿名拒绝通过。
- TURN签名：HMAC-SHA1与独立实现一致、用户/过期时间绑定、不返回长期密钥、无效配置拒绝通过。这不是TURN联网测试。
- Deno check：voice-config类型检查通过。

## 两台手机测试步骤与未完成项
两机都安装1.0.37+38，登录不同账号，在前台打开聊天，先同一Wi-Fi：
1. 互相发短语音，确认时长、播放、未播放标记、下一条自动播放；上滑取消后对方没有收到语音。
2. 断网录音，恢复网络重试，确认只有一条；重启后待发消息仍在。
3. 甲呼叫乙，乙先拒绝，再接听；双方确认声音、静音、扬声器、挂断。
4. 切换网络并记录恢复时间；当前无TURN，直连可能失败，应显示真实失败。

以下均需真实设备/地区网络实测，不填虚假数据：
| 场景 | 接通 | 接通秒数 | 卡顿/断线 | TURN | 状态 |
|---|---|---|---|---|---|
| Wi-Fi ↔ Wi-Fi | — | — | — | 未配置 | 待双机测试 |
| Wi-Fi ↔ 4G/5G | — | — | — | 未配置 | 待双机测试 |
| 4G/5G ↔ 4G/5G | — | — | — | 未配置 | 待双机测试 |
| 中国大陆两机 | — | — | — | 未配置 | 待双机测试 |
| 中国大陆 ↔ 海外 | — | — | — | 未配置 | 待异地设备 |
| 弱网 | — | — | — | 未配置 | 待实测 |
| 网络切换 | — | — | — | 未配置 | 待实测 |


## 最终构建与设备核对
- 最终 Android debug 构建成功（235.3秒）。
- APK：`releases/huideng-counter-v1.0.37-38-voice.apk`
- SHA-256：F43E3D1211A155AD6810903BDA59E44433B7F14095C6EF9ED535803287A5DC2F
- Xiaomi 14T 覆盖安装成功；adb确认 versionName=1.0.37、versionCode=38；未卸载、未清空数据。
- 冷启动 Status=ok，约3.0秒；检查的启动日志窗口未发现致命异常。
- 上述设备检查只证明安装/启动，不能代替双机语音消息收发、实际音质和通话连通测试。
- 静态检查无error/warning，剩余1处大括号风格info；10项客户端针对性测试通过。
