# Vendored Swift dependencies

These directories contain the complete tracked source trees for the exact upstream commits listed in [`manifest.json`](manifest.json). The snapshots came from the versions previously resolved for this app. Git metadata, build output, and untracked checkout files are not included. Upstream license and notice files are kept with each package.

`Package.swift` points the app's three direct dependencies at these local directories. Nested runtime dependencies in the vendored manifests also point to sibling directories. Local manifest and packaging-metadata edits are recorded per package in `manifest.json`; dependency source files are unchanged. SwiftSoup's package and Example `.gitignore` files have precise exceptions for two tracked Xcode workspace metadata files that upstream ignore rules would otherwise hide from a clean Git export.

Some full upstream snapshots retain declarations used only by upstream documentation, optional features, or test targets. These include the Swift SDK's older `Package@swift-6.0.swift` compatibility manifest, optional EventSource `AsyncHTTPClient` support, and snapshot-testing or DocC references. The Still app target does not enable those dependencies. Building Still and its app tests uses only local package paths; running an upstream dependency's own documentation or test suite may require those additional tools and packages.

## Updating a snapshot

1. Resolve the intended upstream release and record its exact Git commit and version.
2. Replace that package directory from `git archive <commit>` so no `.git` data is copied.
3. Reapply only the local path changes needed by the app's runtime graph and packaging-metadata exceptions needed for a complete Git-visible snapshot; record them in `manifest.json`.
4. Update the root and nested package paths, preserve all upstream license/notice files, then verify the resolved app graph uses only `Vendor/` paths in a clean scratch build.
