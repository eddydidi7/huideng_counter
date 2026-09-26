# Chat profile and QR rollout (2026-09-18)

- Chat header: profile / 通讯录 / 红书 / 资料 / search / add. Add touch width 44 → 66 dp, height 48 dp, right inset 8 dp, cyan icon. Bottom navigation unchanged.
- Profile sheet: nickname, online/invisible, avatar, personal QR. Also accessible from Contacts profile icon.
- Plus: Scan QR; existing add friend, create group, start chat, stranger switch retained.
- Personal QR contains only app scheme, user UUID and version. Scan queries existing authenticated friend search, then confirmation and existing friend request RPC. Existing block/rate limits remain.
- Group settings: Group QR. After migration 021, owner generates a permanent invite; current members may view the current code. Owner can rotate to revoke the old QR. Scan preview exposes only group title; joining requires confirmation and a second server check.
- Removed/left users require owner invitation to return. Tokens are not directly readable through table APIs. No old messages or files are deleted.
- New migration: supabase/migrations/202609180020_chat_qr.sql. Requires existing 012 chat schema. Not executed on hosted Supabase by this change.
- Camera QR scanning Android/iOS, bundled Android ML Kit (no separate model download). Windows can paste copied QR contents. No arbitrary QR URL is launched. Camera permission requested only when scanner opens.
- QR can be shared as a screenshot or copied payload; gallery-image decoding is not part of this version.

## Verification
- Flutter tests: 320/360/412 dp widths in Chinese/English, profile action, add width/inset, existing menu actions, strict QR parsing.
- PGlite: owner/member/outsider access, private token table, preview without message access, repeat join, removal protection, rotation, expiry, blocked/banned/anonymous denial.
- Dart analyzer passes for changed Dart code.
- No APK built. Physical-phone camera permission, two-phone scan/add/join, curved-edge ergonomics await a requested APK build and migration deployment.
