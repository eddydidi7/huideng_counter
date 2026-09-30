# Public resource to group files

Historical 076-only instructions. For the current 077/078 lifecycle, independent
references, deletion permissions and cleanup worker, see `shared-file-lifecycle.md`.

Deploy `supabase/migrations/202609290076_public_resource_group_files.sql`
in Supabase SQL Editor after the existing public-resource and group migrations.
Then rebuild and install the client. No Edge Function changes are required.

The public-resource file menu now provides a group-file save action. The picker
lists joined groups where uploads are allowed. Saving creates a shared
`community_files` reference and a `chat_group_files` entry. It neither copies
Storage objects nor uploads file bytes. Duplicate saves in the same group are
idempotent; multiple groups share one reference. Referenced bytes are excluded
from the group upload quota.

Downloads recheck group access and the source publication status, then use the
existing public-resource download service (including its quotas and checksum
validation). Downloads still incur normal network egress. Removing the group
entry does not remove the source. Hiding or deleting the source disables group
downloads; this is a reference, not an independent backup.

Local verification:

```powershell
node supabase/tests/public_resource_group_files_test.mjs
flutter test test/public_resources_test.dart
```

The SQL test uses PGlite from `.dart_tool/group_resource_sql/node_modules`, or
the module URL in `PGLITE_MODULE`. It never connects to the production database.

After deployment, check on a device: save a document to a group, open it from
group files, repeat the save, save to another group, and verify that the Storage
object count does not increase. Test a group with uploads disabled and a source
that has been taken down as well.
