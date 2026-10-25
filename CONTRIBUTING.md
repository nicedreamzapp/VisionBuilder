# Contributing

Thanks for taking a look. Vision Builder is a work in progress, so rough edges are expected, and
a report about one is useful even if you never send code.

## Reporting a problem

Open an [issue](https://github.com/nicedreamzapp/VisionBuilder/issues/new/choose). The things
that make it quick to fix:

- your iPhone model and iOS version, and your Xcode version
- which models were bundled (the committed ones, or ones you made with `scripts/convert_models.sh`)
- roughly how many photos are in the library you scanned
- which tab or screen you were on and what you tapped
- any console output from Xcode when it went wrong

## Running it locally

Needs Xcode 26 or later and an iPhone on iOS 26 or later. A real device is best, since the
Simulator has no Neural Engine and is slow.

```bash
git clone https://github.com/nicedreamzapp/VisionBuilder.git
cd VisionBuilder

# Optional: generate the larger models (needs an Apple Silicon Mac and Python 3.12)
bash scripts/convert_models.sh all

open "Vision Builder.xcodeproj"
```

The generated `.mlpackage` files are gitignored. Drag them into Xcode and add them to the
Vision Builder target. Source files live at the repo root, and `CLAUDE.md` has a map of which
file does what.

## Tests

There are no real automated tests yet. `Vision BuilderUITests/` only holds Xcode's default
launch test. Before sending a change, check by hand on a device: scan the photo library, name a
cluster in the Name tab, and export a dataset from My Things.

## Pull requests

Small and focused is easiest to review. For big changes, open an issue first so we can talk it
through. Say which iPhone you tested on. Keep everything on device: please do not add a cloud or
network dependency for inference.

Please follow the [code of conduct](CODE_OF_CONDUCT.md).
