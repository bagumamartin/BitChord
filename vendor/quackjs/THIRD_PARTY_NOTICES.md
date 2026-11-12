# Third-party notices

QuackJS code is licensed under GPL-3.0-only. That grant does not replace the
licenses or copyright notices of independent third-party material.

## Player fixtures

The unmodified YouTube player files in `fixtures/` and the dependency extract in
`src/commonTest/kotlin/meow/nyx/quackjs/RealPlayerSlice.kt` are used for verification,
not shipped as runtime JavaScript. Download URLs and hashes are recorded in
[`fixtures/manifest.json`](fixtures/manifest.json).

The original player files retain these embedded notices:

- Copyright The Closure Library Authors. SPDX-License-Identifier: Apache-2.0
- Copyright Google LLC. SPDX-License-Identifier: Apache-2.0
- Copyright 2015-present Dan Abramov. SPDX-License-Identifier: MIT

The corresponding license texts are in [`licenses/Apache-2.0.txt`](licenses/Apache-2.0.txt)
and [`licenses/MIT-Dan-Abramov.txt`](licenses/MIT-Dan-Abramov.txt). These notices
identify the components marked in the upstream files; they are not a claim that
QuackJS owns or relicenses the entire upstream player.

## Gradle wrapper

The Gradle wrapper scripts and JAR come from Gradle, distributed under
[Apache-2.0](licenses/Apache-2.0.txt). Script copyright/license headers are retained.
