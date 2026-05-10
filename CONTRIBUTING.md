# Contributing to Shelf

Thanks for your interest in contributing. v0.1.0 is currently in active development. PRs are welcome after v0.1.0 ships.

## Code style

* Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
* 4-space indentation, no tabs
* Prefer `final class` for concrete types that aren't intended to be subclassed
* Avoid protocols for single-implementation types (per project convention)
* No `import SwiftUI` or `import AppKit` inside `Modules/ShelfCore/`. Core stays pure Swift.
* Use `OSLog` for diagnostics with subsystem `dev.rod.shelf` and category-appropriate logger (`core`, `drag`, `panel`, `hotkey`, `persist`, `intent`)

## Commit format

Use [Conventional Commits](https://www.conventionalcommits.org/):

* `feat:` new user-visible feature
* `fix:` bug fix
* `chore:` tooling, deps, build config
* `test:` test-only changes
* `docs:` documentation only
* `refactor:` code change that neither fixes a bug nor adds a feature

Keep commits atomic. One logical change per commit. Write commit messages that explain the why, not just the what.

## PR process

1. Branch from `main` (e.g., `feat/quick-look-preview`)
2. Make atomic commits as described above
3. Ensure all CI checks pass green before requesting review
4. Open a PR against `main` with a clear description of the change and any user-facing impact
5. Address review feedback in additional commits (don't force-push during review)
6. A maintainer will squash-or-merge once approved

## File organization

* `Shelf/` — app target source (AppKit + SwiftUI hybrid). All UI, panel management, drag detection, hotkey, intents live here.
* `Modules/ShelfCore/` — pure-Swift Swift Package. **No `AppKit`, `SwiftUI`, or `AppIntents` imports.** Core types, models, and platform-agnostic logic.
* `project.yml` — [xcodegen](https://github.com/yonaskolb/XcodeGen) spec. Single source of truth for the Xcode project. Re-run `xcodegen generate` after edits to `project.yml`.
* `Shelf.xcodeproj/` — generated, but committed. Do not hand-edit `project.pbxproj`. Edit `project.yml` and regenerate.
* `Shelf/Info.plist` — hand-written, also referenced by `project.yml`. Keep both in sync.
* `Shelf/Assets.xcassets/` — app icon and other assets.

## Pure-core rule

`Modules/ShelfCore/` must remain importable from any Swift context (CLI tools, tests, future iOS port). If you find yourself wanting to `import AppKit` there, the type belongs in `Shelf/` instead.
