# Total Storage Quota

## Confirmed Charging Rule

- Each user pays personal quota for each distinct entity they reference.
- The same user's references to the same entity count once, including references
  in multiple groups and the public drive. Other users each pay their own quota.
- Removing the last reference belonging to one user releases that user's charge.
- Physical deletion is independent: the existing File Object garbage collector
  may delete the entity only after all valid references are gone.
- Merely viewing/downloading a group file is not a new storage reference. Charge
  the uploader or the actor creating the reference, not every group member.
- A client-provided hash is not proof of ownership or server-verified identity.

## Units and Defaults

The 2026-09-29 consolidated request supersedes earlier defaults. Binary units:
level 1 is unlimited; levels 2-5 receive 10 GiB, 5 GiB, 2 GiB and 500 MiB.
Unlimited is an explicit boolean with null capacity, remaining and percentage,
not a fabricated large number. Level 1 ignores retained personal overrides;
those overrides apply again if the account is moved to a limited level.
New registrations default to level 2 through migration 083. Historical implicit
level-1 accounts are materialized without changing their effective level.
The quota draft uses level 2 for missing records; it still must not be deployed
until the registration migration and the accounting adapters are integrated.
Existing feature templates still require the independent level-1 highest-rights
audit; the quota kernel does not bypass feature freezes or grant feature access.
This draft is tested on a fresh local database, not an upgrade from an earlier
experimental draft schema. Production deployments of the earlier draft require
an explicit schema/data upgrade rather than rerunning this file.

## Implemented Kernel, Not a Deployable Feature

`supabase/drafts/202609290081_total_storage_quota.sql` contains:

- Server-side level settings and nullable per-user overrides.
- Per-user source/reference accounting with distinct charge-key aggregation.
- Separate permanent, temporary and reserved totals.
- 80/90/100 percent thresholds and positive-growth denial when over quota.
- Revision-protected, idempotent admin operations and audit history.
- Service-only administration and private trusted accounting functions.

`supabase/tests/total_storage_quota_test.mjs` verifies this kernel locally.
These are kernel tests, not tests of actual uploads or simultaneous transactions.

## Release Blockers

Do not move the draft into migrations or deploy its public snapshot RPC yet.
Without accounting adapters it would show incomplete/zero usage for old data.

1. Add trusted, transactional adapters for all actual storage writers, all
   database payloads and reservations, including legacy/Edge service-role paths.
2. Backfill current data without deleting it or failing for over-quota accounts.
3. Map public/group reference ownership separately from physical object owner.
   Follow canonicalization and removal without double-counting old paths.
4. Resolve the old `resource_user_limits.quota_bytes` and personal-drive quota
   checks so stale legacy limits cannot conflict with the new effective limit.
   Preserve existing daily/monthly upload and feature permissions.
5. Connect the existing admin APP to level defaults and user overrides; remove
   ambiguity with the existing total-capacity editor. Add reset and presets.
6. Add user usage/warning displays and friendly quota errors. Viewing,
   downloading and actual cleanup must remain available when over quota.
7. Verify server physical usage independently. Sum Storage entities once; do
   not sum user charges to report physical capacity. Database payload sizes are
   logical bytes, not exact per-user compressed/index/backup physical sizes.
8. Test actual migration chains, concurrent uploads/reservations, old clients,
   deduplication, canonicalization, multi-reference deletion and downgrade.

No production changes, APKs, Windows packages or cleanup jobs were run.
The P2P file assistant must not upload file bodies for quota accounting; a
direct-only transfer has zero server file-body usage. Do not introduce a
Storage fallback or a scheduled deletion rule as part of this accounting work.
