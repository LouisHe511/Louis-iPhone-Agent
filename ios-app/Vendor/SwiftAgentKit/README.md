# SwiftAgentKit iOS compatibility snapshot

Source: https://github.com/ayman3000/SwiftAgentKit
Revision: `84ddf324fd2a223834323537eb3f8746d669753b` (MIT; see LICENSE).

This local package includes the unmodified core and macro sources from the pinned
revision, except for three compatibility patches in `defaultStore(named:)`:
`FileAgentSkillStore`, `FileAgentGoalStore`, and `FileAgentMemoryStore` now use
the app's Application Support directory on mobile platforms. macOS/Linux retain
the original home-directory behavior. `homeDirectoryForCurrentUser` is unavailable
on iOS, even when the app does not call these convenience methods.

The package manifest exposes only the core product consumed by PhoneAgent and its
unchanged compile-time macro. Unused MCP, desktop/simulator control, examples,
documentation plugins and upstream tests are not included. ProviderCore (local) and
SwiftSyntax retain their previously resolved versions. No package cache is edited.

`UPSTREAM.json` records original source hashes and the patched file list. The
checked-in Xcode project and both project generators use this directory directly.
PhoneAgentTests includes an iOS regression test for the three default stores.

Provider migration: the six model/context seams now depend on ProviderCore,
with native terminal snapshots, no text-to-tool inference, and no automatic
regeneration on stall/incomplete streams. Agent scheduling, permissions and
serial device dispatch remain intact. See ../../ProviderKit/README.md.
