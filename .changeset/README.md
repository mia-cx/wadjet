# Changesets

Every user-visible change to the macOS app gets a changeset: run `pnpm changeset`, pick `@wadjet/macos`, and write one short user-facing summary sentence.

The release workflow keeps a `chore(release): version app` PR open on main; merging it builds the DMG and publishes the GitHub release.

Channels: alpha pre-releases for now. To switch, run `pnpm changeset pre exit` for production releases, or `pre exit` then `pre enter beta`, in a normal PR.
