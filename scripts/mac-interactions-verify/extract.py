"""Compile the production interaction views, without unrelated app frameworks.

These are exact source slices, not copies of the behavior under test. The only
stub is the playback controller, whose transport actions are counted by the probe.
"""

from pathlib import Path
import sys

repo, output = map(Path, sys.argv[1:])
common = (repo / "AppleApp/Sources/UI/Common.swift").read_text()
shell = (repo / "AppleApp/Sources/UI/MacShell.swift").read_text()
search = (repo / "AppleApp/Sources/UI/SearchView.swift").read_text()

def between(source, start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]

pieces = [
    "import AppKit\nimport SwiftUI\nimport Observation\n",
    between(common, "@Observable\nfinal class RowSelection", "/// A queue row:"),
    between(common, "private struct MacRowInteraction", "/// Which lyric line").strip().removesuffix("#endif"),
    common[common.index("/// The page half of keyboard navigation:"):],
    between(shell, "struct MacTransportKeys:", "// MARK: - Inspector"),
    between(search, "private struct MacToolbarSearchField:", "\n#else"),
    (repo / "scripts/mac-interactions-verify/Probe.swift").read_text(),
]
helper = repo / "AppleApp/Sources/UI/MacKeyboardInput.swift"
if helper.exists():
    pieces.insert(1, helper.read_text())
output.write_text("\n".join(pieces))
