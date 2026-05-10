# Shelf

An open-source native macOS app providing Dropover-style floating drag-and-drop shelves.

**Status**: v0.1.0-alpha, unsigned local build

## Features

* Floating shelf invoked by shake gesture, hotkey, or menu bar click
* Multi-shelf support (up to 5 most recent shelves persisted)
* Drag IN files, URLs, text, and images from any app
* Drag OUT to other apps via `NSFilePromiseProvider`
* Quick Look preview for any item on a shelf (press space)
* Items persist across launches via security-scoped bookmarks
* `AddToShelfIntent` for Shortcuts.app integration (where available)

## Requirements

* macOS 14 Sonoma or newer
* Xcode 15 or newer to build from source
* [xcodegen](https://github.com/yonaskolb/XcodeGen) (install via `brew install xcodegen`) for project regeneration

## Build instructions

```bash
git clone https://github.com/Rod2003/shelf.git
cd shelf
xcodegen generate   # regenerate Shelf.xcodeproj from project.yml (only if you change project.yml)
xcodebuild -scheme Shelf -destination 'platform=macOS,arch=arm64' build
open ~/Library/Developer/Xcode/DerivedData/Shelf-*/Build/Products/Debug/Shelf.app
```

`Shelf.xcodeproj` is checked in and can be opened directly. Re-run `xcodegen generate` only if you edit `project.yml`.

## Run instructions and first-launch Gatekeeper note

Since v0.1.0 is unsigned, macOS Gatekeeper will block the first launch with a "Shelf cannot be opened because the developer cannot be verified" dialog.

**Workaround**:

1. Locate `Shelf.app` in Finder
2. Right-click (or Control-click) the app, choose **Open**
3. Confirm **Open** in the dialog that appears

After this one-time confirmation, future launches work normally without prompts.

## How to use

Shelf has three activation methods:

1. **Shake during drag**: Start dragging a file in Finder, then shake the cursor mid-drag. A new shelf appears under the cursor and accepts the drop.
2. **Hotkey ⌘⇧Space**: Press the global hotkey to create a new empty shelf at the cursor position.
3. **Menu bar icon**: Click the Shelf icon in the menu bar, then choose **New Shelf**.

## Known conflicts

`⌘⇧Space` is the macOS default for **Show Emoji & Symbols**. To use it as the Shelf hotkey, disable the system shortcut:

1. Open **System Settings → Keyboard → Keyboard Shortcuts**
2. Select **Input Sources** in the sidebar
3. Uncheck **Show Emoji & Symbols** (or reassign it)

If you skip this step, the system shortcut will win and Shelf's hotkey will not fire.

## Drop sources supported

Shelf accepts drops from:

* **Finder**: files and folders
* **Safari**: URLs and image promises (drag an image off a webpage)
* **TextEdit and any app**: text selections
* **Generic apps**: anything writing `fileURL`, `URL`, or `string` types to `NSPasteboard`

## Drop targets supported

You can drag items off a shelf to:

* **Finder**: any folder
* **Mail.app**: as email attachments
* **Pages and Keynote**: insert as document content
* **Generic apps**: anything reading `NSFilePromiseProvider`

## Roadmap and out-of-scope for v1

The following are intentionally deferred and **not** part of v0.1.0:

* Cloud uploads (iCloud, Dropbox, S3, etc.)
* Custom user-defined actions
* Watched folders
* Widgets
* Modifier-key activation
* Notch drop zone
* Mac App Store distribution
* Code signing and notarization
* Sparkle auto-update

These may appear in future versions, but no timeline is committed.

## License

Shelf is released under the MIT License. See [LICENSE](./LICENSE) for the full text.

## Contributing

Contributions are welcome once v0.1.0 ships. See [CONTRIBUTING.md](./CONTRIBUTING.md) for code style, commit conventions, and the PR process.

## Acknowledgments

**Author**: Rod2003

Inspired by [Dropover](https://dropoverapp.com/), a commercial macOS app. Shelf is an independent open-source clone and is not affiliated with, endorsed by, or derived from Dropover's source code.

## App icon contribution welcome

The current app icon is a placeholder: a `#5E81F4` blue square with a white "S". A designed icon contribution from the community is welcome. Open a PR with your `Assets.xcassets/AppIcon.appiconset/` replacement and a brief design rationale.
