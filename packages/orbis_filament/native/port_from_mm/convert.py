#!/usr/bin/env python3
"""convert.py <OrbisRenderer.mm> <methods out> <declarations out> <prelude out>

Turns the Objective-C implementation into orbis::Renderer member functions,
in the same order and with the same comments:

  - (T)foo:(A)a bar:(B)b {     ->   T Renderer::foo(A a, B b) {
  [self foo:x bar:y]           ->   foo(x, y)
  [NSString stringWithFormat:] ->   orbis::format(...)
  [self](...) captures         ->   [this](...)
  BOOL/YES/NO/nil/NSUInteger/NSInteger/MAX/CFAbsoluteTimeGetCurrent

What it cannot do mechanically (NSLog's %@, dictionaries, NSData, video) is
left for hand-editing, and the compiler finds it.
"""
import re
import sys

MM, OUT, DECLS, PRELUDE = sys.argv[1:5]
text = open(MM).read()
lines = text.split('\n')

start = next(i for i, l in enumerate(lines)
             if l.startswith('- (nullable instancetype)initWithWidth'))
end = max(i for i, l in enumerate(lines) if l.strip() == '@end')
# The prelude: structs, constants, helpers, up to the class extension.
prelude_from = next(i for i, l in enumerate(lines) if l.startswith('using namespace filament;'))
prelude_to = next(i for i, l in enumerate(lines) if l.startswith('@interface OrbisRenderer ()'))

TYPE_MAP = [
    (r'NSArray<NSString \*> \*', 'const std::vector<std::string> &'),
    (r'NSMutableDictionary<NSString \*, NSString \*> \*', 'Notes &'),
    (r'NSString \*', 'const std::string &'),
    (r'\bBOOL\b', 'bool'),
    (r'\bNSUInteger\b', 'size_t'),
]


def ctype(t):
    t = t.strip()
    for a, b in TYPE_MAP:
        t = re.sub(a, b, t)
    return t


def typed(t, n):
    t = ctype(t)
    return f'{t}{n}' if t.endswith(('*', '&')) else f'{t} {n}'


def skip_string(s, j):
    quote = s[j]
    j += 1
    while j < len(s) and s[j] != quote:
        if s[j] == '\\':
            j += 1
        j += 1
    return j


def matching(s, i):
    depth = 0
    j = i
    while j < len(s):
        c = s[j]
        if c in '"\'':
            j = skip_string(s, j)
        elif c in '[({':
            depth += 1
        elif c in '])}':
            depth -= 1
            if depth == 0:
                return j
        j += 1
    raise ValueError('unbalanced at %d: %r' % (i, s[i:i + 80]))


def labels(body):
    starts = []
    depth = 0
    i = 0
    n = len(body)
    while i < n:
        c = body[i]
        if c in '"\'':
            i = skip_string(body, i) + 1
            continue
        if c in '[({':
            depth += 1
        elif c in '])}':
            depth -= 1
        elif depth == 0 and (c.isalpha() or c == '_') and (i == 0 or body[i - 1] in ' \t\n'):
            m = re.match(r'[A-Za-z_]\w*', body[i:])
            ident = m.group(0)
            k = i + len(ident)
            if k < n and body[k] == ':' and (k + 1 >= n or body[k + 1] != ':'):
                starts.append((i, ident, k + 1))
            i = k
            continue
        i += 1
    if not starts:
        return body.strip(), None
    args = []
    for idx, (pos, ident, arg_from) in enumerate(starts):
        arg_to = starts[idx + 1][0] if idx + 1 < len(starts) else n
        args.append(body[arg_from:arg_to].strip())
    return starts[0][1], args


def convert_sends(s):
    patterns = ['[self ', '[NSString stringWithFormat:']
    while True:
        hits = [(s.rfind(p), p) for p in patterns]
        pos, pat = max(hits)
        if pos < 0:
            return s
        close = matching(s, pos)
        inner = s[pos + len(pat):close]
        if pat == '[self ':
            name, args = labels(inner)
            replacement = f'{name}()' if args is None else f'{name}({", ".join(args)})'
        else:
            replacement = f'orbis::format({inner.strip()})'
        s = s[:pos] + replacement + s[close + 1:]


def keywords(s):
    s = re.sub(r'\[self\]\(', '[this](', s)
    s = re.sub(r'\[(_\w+Lock) (lock|unlock)\]', r'\1.\2()', s)
    s = re.sub(r'\bCFAbsoluteTimeGetCurrent\(\)', 'orbis::now()', s)
    s = re.sub(r'\bCFAbsoluteTime\b', 'double', s)
    s = re.sub(r'\bBOOL\b', 'bool', s)
    s = re.sub(r'\bYES\b', 'true', s)
    s = re.sub(r'\bNO\b', 'false', s)
    s = re.sub(r'\bnil\b', 'nullptr', s)
    s = re.sub(r'\bNSUInteger\b', 'size_t', s)
    s = re.sub(r'\bNSInteger\b', 'int', s)
    s = re.sub(r'\bMAX\(', 'std::max(', s)
    s = re.sub(r'\bNSLog\(@"', 'orbis::log("', s)
    s = re.sub(r'(?<![\w@])@"', '"', s)
    return s


region = '\n'.join(lines[start:end])
out = []
decls = []
i = 0
header_re = re.compile(r'^- \(', re.M)
pos = 0
while True:
    m = header_re.search(region, pos)
    if m is None:
        out.append(region[pos:])
        break
    out.append(region[pos:m.start()])
    brace = region.index('{', m.start())
    head = region[m.start():brace]
    hm = re.match(r'-\s*\(([^)]*)\)\s*(.*)$', head.strip(), re.S)
    ret, rest = hm.group(1), hm.group(2)
    parts = re.findall(r'(\w+)\s*:\s*\(([^)]*)\)\s*(\w+)', rest)
    if parts:
        name = parts[0][0]
        params = [typed(t, n) for (_, t, n) in parts]
    else:
        name = rest.strip()
        params = []
    r = ctype(ret)
    sep = '' if r.endswith(('*', '&')) else ' '
    out.append(f'{r}{sep}Renderer::{name}({", ".join(params)}) ')
    decls.append(f'  {r}{sep}{name}({", ".join(params)});')
    pos = brace

body = ''.join(out)
body = convert_sends(body)
body = keywords(body)
open(OUT, 'w').write(body + '\n')
open(DECLS, 'w').write('\n'.join(decls) + '\n')
open(PRELUDE, 'w').write(keywords('\n'.join(lines[prelude_from:prelude_to])) + '\n')
print(f'methods {len(decls)}; body {len(body.splitlines())} lines')
