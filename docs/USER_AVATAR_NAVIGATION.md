# User avatar navigation

All user-avatar surfaces must use `ChatAvatar` (or `forumAuthorAvatar`, which
delegates to it). `app` is required so a new avatar cannot silently omit its
profile destination. Do not implement another avatar tap callback for chat,
selection, image preview, or editing. Keep those actions on the row or an
explicit control.

## Shared behavior

- `ChatAvatar` owns only the tap gesture; parent long presses remain available.
- `openUserProfile` pushes `PublicProfilePage`. It does not replace the source
  route, clear searches, reload lists, or reset scroll controllers.
- The current user's UUID uses the same route and shows "My profile" with the
  existing own-profile controls. Avatar editing has a separate toolbar button.
- Tapping the avatar of the profile already being displayed is a no-op, avoiding
  recursive copies of the same page.
- Pass `groupId` when entering from a group member/message surface. This preserves
  the group friend-request permission context; server enforcement is unchanged.
- A direct-room avatar with no explicit `userId` resolves the sole other member.
  Missing or ambiguous identity shows feedback instead of guessing a user.
- Group avatars, the mention-everyone symbol, and generic menu icons are not user
  avatars and retain their existing actions. Deleted/unknown forum authors cannot
  be assigned an invented profile; their avatar gives unavailable-user feedback.
- Above-Navigator call overlays temporarily yield to the pushed profile and
  return when it closes. The call service is neither disposed nor hung up.
- Public `/u/` links use `PublicProfilePage.publicLink`; this mode still uses only
  the existing public RPC and does not acquire private or relationship data.

## Audited locations

| Surface | Shared entry |
| --- | --- |
| Chat list, grid and list layouts | ChatAvatar, with direct-room peer resolution |
| Direct/group messages, including self | ChatAvatar |
| Chat information member preview | ChatAvatar with group context |
| Group members and mention picker | ChatAvatar with group context |
| Group invitation selection | ChatAvatar; checkbox remains independent |
| Contacts, user search and contact action sheet | ChatAvatar |
| Forum/redbook cards and detail author | forumAuthorAvatar |
| Forum/redbook comments, replies and likes list | forumAuthorAvatar |
| Followers/following list | forumAuthorAvatar |
| Voice call identity | ChatAvatar with peer resolution |
| Personal profile and avatar editor | ChatAvatar |
| Public profile links | Same profile component, restricted public mode |

Other in-app notifications currently do not render user avatars. Existing forum
and follow wrappers inherit the component behavior without separate routing.
Any future notification containing a user avatar must use the same component.

## Verification

`test/avatar_navigation_test.dart` covers nested tap priority, long press,
independent checkboxes, preserved search/scroll, self/friend/stranger controls,
group context, peer resolution, group-avatar exclusion, public-only RPCs, duplicate
profile prevention, and above-Navigator overlay restoration.

Related existing coverage: `forum_avatar_test.dart`, `group_admin_ui_test.dart`,
forum layout/card/social tests. No database migration is required for this change.
