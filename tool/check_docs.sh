#!/bin/bash
# Checks the Markdown that is now this repository's front door.
#
# Two things, both of which have actually happened here rather than being
# imagined: a link whose target was emptied by a bad search-and-replace, and a
# relative link to a file that is not there. Neither breaks a build, neither
# shows up in any test, and both are the first thing a stranger sees.
set -uo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PYTHON'
import pathlib
import re
import sys

# The repository's own Markdown. Anything vendored or generated is somebody
# else's to keep tidy.
SKIP = {'.git', 'node_modules', 'build', '.dart_tool', 'third_party', 'quickjs-ng'}

EMPTY = re.compile(r'\[[^\]]*\]\(\s*\)')
LINK = re.compile(r'\[[^\]]*\]\(([^)\s]+)\)')

problems = []
checked = 0
for path in sorted(pathlib.Path('.').rglob('*.md')):
    if SKIP & set(path.parts):
        continue
    checked += 1
    text = path.read_text(errors='replace')

    for match in EMPTY.finditer(text):
        line = text[:match.start()].count('\n') + 1
        problems.append(f'{path}:{line}  empty link: {match.group(0)}')

    for match in LINK.finditer(text):
        target = match.group(1)
        # Only relative links to files in the repository. A URL is somebody
        # else's uptime, and an anchor is a heading this does not parse.
        if target.startswith(('http://', 'https://', '#', 'mailto:')):
            continue
        target = target.split('#', 1)[0]
        if not target:
            continue
        if not (path.parent / target).exists():
            line = text[:match.start()].count('\n') + 1
            problems.append(f'{path}:{line}  no such file: {target}')

print(f'{checked} Markdown file(s) checked')
if not problems:
    print('every link resolves')
    sys.exit(0)
for problem in problems:
    print(f'  {problem}')
print(f'\n{len(problems)} broken link(s)')
sys.exit(1)
PYTHON
