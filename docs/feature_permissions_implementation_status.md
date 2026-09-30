# User Feature Restrictions: Implementation Status

Status: partial implementation, not ready for production deployment.

## Implemented

- `supabase/migrations/202609290079_user_feature_restrictions.sql`: extensible
  25-action catalog, private restrictions, server-time expiration, default allow,
  administrator validation, revision checks, idempotent writes and audit history.
- `supabase/tests/user_feature_restrictions_test.mjs`: local PostgreSQL-compatible
  tests for default permissions, guests, expiry, partial/all restore, privileges,
  preset durations, custom expiry, audit and batch state lookup.
- Existing admin project under
  `C:/Users/eddyd/Documents/Codex/2026-09-15/flutter-android-iphone-windows-android-ios/outputs/huideng_admin`:
  user-list status, user permission page, timed/multiple/all freeze and restore,
  reasons, recent audit display and authenticated Edge routing.

## Deployment Hold

Do not deploy the admin freeze UI or migration 079 independently as a finished
restriction system. The catalog stores restrictions, but storage alone does not
enforce existing application operations.

The proposed enforcement migration is intentionally outside the executable
migration directory at `supabase/drafts/202609290080_feature_server_guards.sql`.
It is an unverified draft, not a deployment instruction.

## Required Before Release

- Audit all real RPC signatures and action names, including legacy aliases.
- Validate direct SELECT/INSERT/UPDATE/DELETE restrictions and Storage policies.
- Avoid cross-module freezes through nested RPC calls; test private/group
  chat isolation, download vs upload isolation and anonymous compatibility.
- Pass restrictions through Edge errors and show friendly user-facing messages.
- Connect the new client to local-function permission snapshots and refresh.
- Add integration tests against actual migration chains and old-client entry
  points; test admin UI expiry, custom dates, restore, errors and concurrency.
- Complete admin audit details/pagination and preserve existing user metadata.
- Only then assign the enforcement migration to the migrations directory,
  deploy database and Edge changes together, and release tested clients.

## Accepted Boundary

Server interfaces must reject restricted operations using server time. New
clients synchronize restrictions for local functions. Offline clients and old
clients cannot be remotely prevented from reading previously downloaded data.
Existing public objects, already-issued signed URLs and established P2P channels
also require explicit lifecycle analysis; do not claim retroactive revocation.
No APK or production deployment has been performed for this work.
