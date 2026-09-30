# Shared files deployment

Status: local implementation and automated tests only. No production migration,
function deployment, scheduled task, or APK release has been performed.

## Deployment order

1. Apply `202609290076_public_resource_group_files.sql` if not already installed.
2. Apply `202609290077_shared_file_lifecycle.sql` and then
   `202609290078_shared_file_transfers.sql`, followed by
   `202609290082_resource_delete_capabilities.sql`.
3. Deploy `public-resources`, `resource-web`, and the new `shared-file-cleanup`
   Edge Function. Dashboard single-file bundles are under `docs/deployment`.
   Regenerate them with `node scripts/bundle_resource_functions.mjs`.
4. Enable pg_cron and pg_net. Add the project URL and service-role key to Vault
   under `shared_file_project_url` and `shared_file_service_key`. Run
   `docs/deployment/shared-file-cleanup-schedule.sql` to schedule cleanup every
   five minutes. Keep keys server-side; never distribute them in the app.
5. Rebuild and install the updated client. Older clients do not understand all
   cross-bucket shared references.

Both settings default to true and are returned in `admin.list.config`:

- `uploader_delete_enabled`: allow uploaders to delete their own public entry.
- `group_transfer_enabled`: allow public/group transfers in both directions.

The existing `admin.settings` service-role RPC accepts the two booleans alongside
the existing full settings payload and optimistic `version`. Omitted booleans
retain their values. Its existing administrator/super-administrator checks and
audit records remain in effect. The existing administrator APP now includes
both switches. Old servers without these fields show a migration notice instead
of pretending the settings have been saved. The Edge response also retains
server-issued delete capabilities and returns explicit FORBIDDEN failures.

## Behavior

Public menus provide deletion (when server-authorized) and multi-group saving.
Group-file menus provide publication to a selected public category. Publishing
a private group file requires confirmation that it becomes publicly readable.
The immutable object retains its original owner; each publication/group entry
has its own author/uploader and access checks.

`file_objects` identifies physical objects. `file_references` tracks active
public and group entries, with transactional reference counts. Deleting one
entry does not delete another. Public deletion retains a tombstone and removes
only that entry's reference. Groups continue downloading independently, even
after the original public entry is deleted. This supersedes 076's earlier
source-publication-dependent download behavior.

The cleanup worker claims only zero-reference objects. Claims and new references
lock the same row; a claimed object cannot gain a new reference. The worker
removes the Storage object through the Storage API, then acknowledges the job.
Failures remain retryable. Existing upload leases/TUS capability lifetimes
delay cleanup (up to the existing 26-hour protection period). A database deletion
guard additionally blocks removal of registered, still-referenced objects.

SHA-256 reuse requires a server-verified matching object and existing download
access. Otherwise the client uploads, the service verifies its bytes in bounded
chunks, and identical verified objects are consolidated. Concurrent uploads or
private objects not already readable by the uploader can therefore temporarily
create duplicates; they are cleaned after validation and lease expiry. A hash
alone never grants access to another user's private file.

Public and group uploads now share this mechanism. Ordinary chat attachments,
personal drives, and other buckets have NOT been migrated. Historical public
objects retain their existing server verification; old group objects require
verification before reuse/publication. No blanket historical file deletion is
performed by the migrations. Normal download traffic and server verification
traffic still consume bandwidth.

The schema permits public objects up to 5 GiB; current administrator upload and
daily quotas remain authoritative. Existing direct group upload limits are
retained. The object/reference design does not multiply storage by group count.

## Verification

```powershell
node supabase/tests/shared_file_lifecycle_test.mjs
node supabase/tests/shared_file_handler_test.mjs
flutter test test/public_resources_test.dart
```

The SQL test uses PGlite in `.dart_tool/group_resource_sql/node_modules`, or a
module URL supplied through `PGLITE_MODULE`. Tests use local data and mocked
Storage; they do not substitute for a production/staging device test.

After deployment, verify two accounts, multiple groups, both settings disabled,
an ordinary upload, a repeated upload, deletion of one and then the final
reference, delayed cleanup/retry, browser shares, and group-to-public downloads.
Check the actual Storage object count and cleanup job logs as well as app lists.
