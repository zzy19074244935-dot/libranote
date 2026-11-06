# Third-party notices

This repository contains application code, adapted dependencies and bundled browser-reader assets. Third-party components retain their own licenses; public repository access does not change those terms.

| Component | Location | License / notice |
|---|---|---|
| foliate-js, John Factotum | `assets/reader/` reader engine | MIT; `third_party/licenses/foliate-js-MIT.txt` |
| PDF.js 5.7.284, Mozilla contributors | `assets/reader/vendor/pdfjs/` | Apache-2.0; `third_party/licenses/pdfjs-5.7.284-Apache-2.0.txt`; existing font/CMap notices are retained |
| Noto Sans SC | `assets/fonts/NotoSansSC.ttf`, `serverless/fonts/` | SIL OFL 1.1; `third_party/licenses/NotoSansSC-OFL.txt` |
| fflate, Arjun Barrett | `assets/reader/vendor/fflate.js` | MIT; `third_party/licenses/fflate-MIT.txt` |
| zip.js, Gildas Lormeau | `assets/reader/vendor/zip.js` | BSD-3-Clause; `third_party/licenses/zipjs-LICENSE.txt` |
| construct-style-sheets-polyfill, Caleb Williams and contributors | `assets/reader/vendor/construct-style-sheets-polyfill.js` | MIT; `third_party/licenses/construct-style-sheets-polyfill-MIT.txt` |
| image 3.3.0 | `third_party/image-3.3.0/` | MIT and bundled format notices; see that directory's `LICENSE` and `LICENSE-other.md` |
| pdfrx_engine 0.4.4 | `third_party/pdfrx_engine-0.4.4/` | See that directory's `LICENSE` |

The reader includes local WebView integration and reader adaptations. The adapted upstream files keep the upstream license. The original upstream revision of the pre-existing foliate-js snapshot was not recorded; `assets/reader/package.json` identifies its origin. This repository does not claim those engine files as original work.

The two path dependencies preserve the project's pre-existing image API compatibility setup. In particular, pdfrx_engine's image conversion code uses the image 3.x API. Its `resolution: workspace` package setting has been removed so it can resolve from a standalone checkout. See [third_party/README.md](third_party/README.md).

Other Flutter/Dart dependencies are declared and locked in `pubspec.yaml` and `pubspec.lock`; their notices are included through Flutter's license system. Native PDFium/ML Kit and platform dependencies retain their upstream terms. The bundled browser reader and export-font notices are registered in the app's About → Licenses view.

Projects consulted during development include [foliate-js](https://github.com/johnfactotum/foliate-js), [Anx Reader](https://github.com/Anxcye/anx-reader), [Readest](https://github.com/readest/readest) and [Xournal++](https://github.com/xournalpp/xournalpp). This is not an official client of or an affiliation with those projects. Their repository checkouts are not bundled here. The portfolio edition uses a Flutter canvas and does not bundle the tldraw SDK.

License texts restored during the portfolio preparation were obtained from their upstream repositories. Existing license headers and notices are preserved. Refer to each component's terms when reusing or distributing it.
