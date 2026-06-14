# Shelf

Shelf is a native macOS app for temporarily holding files, links, text, and images in floating drag-and-drop shelves.

## Building (development)

```sh
xcodegen generate
open Shelf.xcodeproj
```

Debug builds are unsigned for fast local iteration.

## Releasing

Maintainers cut signed + notarized DMGs with `./scripts/release.sh`. Setup
and usage are documented in the header of that script.
