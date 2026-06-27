# Shelf

Shelf is a native macOS menu bar app for temporarily holding files, links, text, and images in a floating drag-and-drop shelf.

It is designed for moments when you need a place to park something briefly while moving between apps, windows, or folders.

## What Shelf is for

Use Shelf when you want to:

- hold a file while navigating somewhere else in Finder
- stash a link or snippet of text before dropping it into another app
- keep an image handy for a quick drag-and-drop
- preview a file or image with Quick Look before using it

Shelf is intentionally lightweight: one floating shelf, one current set of items, and fast drag-and-drop.

## Requirements

- macOS 14 or later
- Apple Silicon Mac

## Install

Download the latest DMG from the repository's **Releases** page, then:

1. Open the DMG
2. Drag **Shelf.app** into **Applications**
3. Launch Shelf

Shelf runs as a **menu bar app**, so you will see its icon in the menu bar instead of the Dock.

## How to use Shelf

### 1. Show the shelf

Open Shelf in either of these ways:

- click the **Shelf** menu bar icon
- press **⌘⇧Space**

The shelf opens near your cursor.

### 2. Add items

Drag content onto the shelf.

Shelf accepts:

- **Files**
- **Web links** (`http` and `https`)
- **Plain text**
- **Images**

If you drag in the same file again, Shelf skips duplicates.

### 3. Browse your items

Shelf has two display modes:

- **Collapsed view**: a compact stack for quick access
- **Expanded view**: a larger grid that shows individual items more clearly

Click the pill/expand control to open the expanded view, and use the collapse button to shrink it again.

### 4. Drag items back out

Drag an item from Shelf into another app, window, or Finder location.

Typical uses include:

- dropping a file into Finder or another app
- dropping a link into a browser, chat, or notes app
- dropping text into an editor
- dropping an image where you need it

After a successful drag-out, the item is removed from Shelf.

### 5. Hide or clear the shelf

- Press **Esc** to close the panel **without clearing** its contents
- Click the **X** button to **clear the shelf and close it**

This distinction is important:

- **Esc** = hide for later
- **X** = empty the shelf

## Quick Look and selection

When Shelf is focused:

- Press **Space** to open **Quick Look** for previewable items
- Quick Look works for **files** and **images**
- In expanded view, you can select multiple items:
  - click to select
  - **Cmd-click** to toggle selection
  - **Shift-click** to select a range

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Show Shelf | `⌘⇧Space` |
| Close shelf panel | `Esc` |
| Quick Look selected item(s) | `Space` |
| Remove selected items (expanded view) | `Delete` / `Forward Delete` |
| Quit Shelf | `⌘Q` |

## Building from source

```sh
xcodegen generate
open Shelf.xcodeproj
```

Then build and run the **Shelf** scheme in Xcode.

Debug builds are unsigned for faster local iteration.

## Releasing

Maintainers cut signed and notarized DMGs with:

```sh
./scripts/release.sh
```

See the script header for setup details.
