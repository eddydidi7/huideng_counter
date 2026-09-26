# Guest chat and permanent QR — release notes

## Behavior
- First network-connected app open without an account obtains a Supabase anonymous authenticated identity. No email/password form. Simultaneous initialization is coalesced; subsequent opens reuse the securely persisted Supabase session.
- Only manufacturer/model are used for initial guest nickname. No serial number, IMEI, user-assigned device name, or hardware identifier is collected. iOS uses modelName; unavailable model falls back to 手机学友. Users can rename through the existing profile menu.
- Registered users keep their identity/nickname. Anonymous chat does not activate account counter/notes synchronization or switch the local repository.
- Guest directory, direct/group chat, friend requests, QR joining, presence and privacy follow the same membership/block/ban/rate rules as registered users. Invisible status is reserved for registered accounts. Guest clients ignore cached invisible preferences and cannot enable invisible status; background/offline devices still naturally go offline. Guest accounts cannot download public resources or activate counter/notes sync. The profile menu has a compact guest-benefits entry; tapping it opens details without taking list space.
- Existing group QR token is retained; expires_at becomes NULL (permanent). Newly generated/rotated QR also has no expiry. Manual rotation still revokes the old token; a departed/removed member still needs owner invitation.
- Guest identity is local-session based: uninstalling/clearing app data or signing into another account may lose access to the prior guest identity. It is not an automatic cross-device account or guest-to-registered merge.

## Deployment, one step at a time
1. Execute `supabase/migrations/202609180021_guest_chat.sql` in the existing Supabase SQL Editor, after 020. This changes existing chat functions only, creates guest profiles, and preserves messages and chosen nicknames. The script fails transactionally if chat prerequisite functions are missing.
2. In hosted Supabase Authentication configuration enable Anonymous Sign-Ins. config.toml is only a local configuration; editing it does not turn on the hosted setting. Keep existing Auth rate limits; if CAPTCHA is enabled its challenge flow must be configured before guest signup can succeed.
3. Deploy the updated `voice-config` Edge Function for guest TURN credential access, if deploying voice configuration. It still verifies JWT with getUser and checks chat_voice_user_active. No TURN infrastructure is provisioned here.
4. Build/install only after user requests APK; validate on two real phones.

## Checks
- SQL PGlite: 021 rerun safety; existing/permanent/rotated QR; anonymous device-nickname profiles; discovery and exact-ID lookup; direct guest messages; stranger privacy; friend acceptance; online and invisible presence; group QR joining; outsider isolation; block/ban/unauthenticated denial.
- Flutter: device nickname normalization; single-flight guest initialization/session reuse; missing provider message/retry; existing QR/parser/presence/small-width topbar tests.
- Physical tests pending: first install, restart identity persistence, offline startup/reconnect, Xiaomi and iPhone model names, privacy toggles across two phones, camera scan with guest identities, preservation of existing local counter/notes on guest initialization and explicit account switching.
- Nothing has been deployed to hosted Supabase by these code edits. No APK generated.

Sources: https://supabase.com/docs/guides/auth/auth-anonymous ; https://pub.dev/packages/device_info_plus

## Follow-up UI
Settings web destinations removed. Notes Shared articles renamed 资料 / Resources. Notes grid uses two columns and four visible rows at normal phone text size; small-height/large-text layouts retain a readable minimum and scroll. No APK generated.
