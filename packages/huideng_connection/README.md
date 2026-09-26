# 备用连接：已预留，尚未启用

## 当前状态
用户暂时没有域名和备用服务器。本次只修改代码和准备部署材料；未生成APK、未创建服务器、未发布域名、未生成生产密钥、未执行026迁移或部署新版admin-api。
默认配置为空，APP与Windows后台仍使用原Supabase地址。要让首次发行APK以后无需升级即可接收新地址，必须在该APK打包前落实并内置下面的配置入口和公钥。若现在空配置直接发行，将来启用仍需更新一次APK。

## 已完成
- 两端共用huideng_connection包。会话存储键、Supabase客户端、public key、auth.uid以及原项目均保持不变；只对该项目的HTTPS/WSS连接更换网关域名。
- Ed25519验签、绑定原项目URL、版本递增、同版本内容一致性、HTTPS来源约束、有效期校验（最长180天）。拒绝伪造、跨项目、过期和回滚配置。
- 已验签的配置及最近选择的入口缓存，重启后恢复。启动/回前台及每10分钟前台无关定时刷新；失败后触发独立源刷新，30秒内不重复拉取。
- GET/HEAD最多尝试两个入口。连接错误或502/503/504切换；401/403/429不切换。POST/PUT等写请求绝不在此层自动重发，保留上层原有UUID去重和重试机制。
- Realtime WebSocket建立连接时采用当前入口；切换关闭旧socket，由现有SDK重连并重新加入频道。并非无缝或不中断通话保证。
- Supabase文件下载/上传由SDK同一HTTP客户端路由；项目内网络图片使用同一路由。OSS、第三方URL、TURN节点不在此路由范围。
- APP网络请求不开跨域自动重定向以防凭证被转送；无禁用TLS校验，无长期服务器密钥进入客户端。
- Windows超级管理员“备用连接”页编辑入口、生成签名并导出JSON。签名保存在数据库后还必须将导出的同一文件上传到每个独立配置入口；此准备版未实现跨云自动发布。页面明确提示这一步。

## 启用前需要
1. 至少两个不同域名的HTTPS静态JSON配置入口，尽量不同服务商/网络，不能仅依赖原Supabase项目。配置入口无需用户登录，不携带用户凭证，不返回重定向。
2. 主网关/备用网关（最多4个），全部代理**同一个原Supabase项目**，覆盖Auth、REST、Functions、Storage和WebSocket。仅增加Supabase域名别名不等于有独立网络路径。deploy/gateway.nginx.example.conf仅为待填模板，需实际验证HTTPS证书、DNS、转发及容量。
3. 离线生成Ed25519签名密钥。私钥放服务器secret或安全离线介质；客户端只放32字节原始公钥的Base64。保管备份，丢失/更换公钥通常需要新APK。
4. 两端打包参数：CONNECTION_CONFIG_PUBLIC_KEY、CONNECTION_CONFIG_URLS（逗号分隔的完整HTTPS JSON地址）。主项目URL保持原值，不能用新项目替代。
5. 执行admin迁移202609180026_connection_config.sql，再部署admin-api目录（包括新增connection_signer.ts），设置后台secret CONNECTION_SIGNING_PRIVATE_KEY（Ed25519 PKCS8 DER的Base64，不是公钥）。不要在Flutter build defines里放该secret。
6. 在后台生成配置并导出，上传同一JSON到所有独立入口。原数据库只保存签名配置和审计；不能把数据库作为唯一配置获取源。
7. 运行 `node deploy/check-release.mjs DEFINES.json` 检查发布参数，随后再做下述真实线路演练。

## 签名工具
`node ../huideng_counter/tool_sign_connection_config.mjs keygen PRIVATE.pem`：私钥保存在明确指定的仓库外位置，屏幕仅输出公钥。文件已存在会拒绝覆盖。
`node ../huideng_counter/tool_sign_connection_config.mjs sign PRIVATE.pem INPUT.json OUTPUT.json`：紧急离线签署；INPUT包含schema=1、project为原项目完整URL、递增version、issued_at、expires_at、origins数组。
离线紧急发布后需对齐后台已使用的版本号，防止后台再次生成同号不同内容而被手机拒绝。旧签名不可编辑后继续使用。
配置到期会回退至APK内置地址并重连，必须在到期前续签发布。已发出的配置不能凭空覆盖所有离线手机，故域名/密钥应长期受控。

## 验证范围与待验收
本地：签名/版本/项目/过期/伪造拒绝、缓存重启、GET切换、写入不重放、401/403/429不切换、WebSocket握手失败后下一入口、发布SQL权限/审计/版本冲突、后台签名函数验签。
尚无真实域名/网关，未测试：大陆不同运营商、主入口断网后自动恢复、TLS与WebSocket反代、登录token刷新、发消息不重复、大文件、通话、Xiaomi14T切网以及镜像全部不可达。
发布前必须实际演练；所有入口同时不可达时只能使用本地功能，不能承诺始终在线。

参考实现依据：
- https://supabase.com/docs/guides/self-hosting/self-hosted-proxy-https
- https://pub.dev/packages/cryptography
