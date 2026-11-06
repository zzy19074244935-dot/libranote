# Explicit compatibility dependencies

`image-3.3.0/` and `pdfrx_engine-0.4.4/` preserve the dependency source used by the existing application. They are selected through `dependency_overrides` in the root pubspec, so a checkout does not depend on undocumented edits to a developer's global Pub cache.

- image stays at 3.3.0 to remain compatible with the application's existing PDF/export dependency graph.
- pdfrx_engine 0.4.4 uses the image 3.x conversion API in `lib/src/pdfrx_dart.dart`. The local adaptation predates the portfolio export; it is included as adapted upstream code, not claimed as original engine implementation.
- The pdfrx_engine package's `resolution: workspace` entry was removed to allow it to resolve outside its upstream monorepo.
- Only runtime library sources, package metadata and license/readme/changelog files are included. Upstream examples, development fixtures and caches are omitted.
- The license files in each directory remain authoritative for those components.

A future dependency upgrade should replace these overrides after verifying PDF rendering, edited-document export, image conversion and EPUB cover extraction together.

PDFium's native binaries are downloaded by `pdfium_dart` during the first build. An environment that cannot reach GitHub Releases will need network access to that official download. The portfolio validation on the development machine reused its existing PDFium cache; native binaries and build caches are not committed here.
