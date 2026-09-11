#!/usr/bin/env python3
"""fix.py <OrbisRendererCore.cpp> <replacements.cpp> — the hand conversions."""
import re
import sys

CPP, REPL = sys.argv[1:3]
src = open(CPP).read()


def sub(old, new, count=1):
    global src
    found = src.count(old)
    if found != count:
        print(f'EXPECTED {count} x, FOUND {found}: {old[:70]!r}')
        if found == 0:
            return
    src = src.replace(old, new)


def resub(pattern, new, flags=0):
    global src
    src, n = re.subn(pattern, new, src, flags=flags)
    if n == 0:
        print(f'NO MATCH: {pattern[:70]!r}')


# ---- targeted substitutions (before the whole-function replacements) ----
sub('  _presentLock = [[NSLock alloc] init];\n  _aimLock = [[NSLock alloc] init];\n', '')
sub('  _assetNotes = [NSMutableDictionary dictionary];\n'
    '  _objectNotes = [NSMutableDictionary dictionary];\n'
    '  _lightNotes = [NSMutableDictionary dictionary];\n'
    '  _decalNotes = [NSMutableDictionary dictionary];\n', '')
sub('noWeights, @[], 1);', 'noWeights, {}, 1);')
sub('''  Engine::Builder builder;
  builder.backend(Engine::Backend::METAL);
  _engine = builder.build();
  ASSERT_PRECONDITION(_engine != nullptr, "Metal is unavailable.");
''', '''  //
  // Which backend is the platform's, or the host's if it named one: see
  // OrbisBackend.cpp. Tried in turn where there is something to fall back to
  // — Vulkan then OpenGL off Apple — because a machine with no Vulkan driver
  // should still draw rather than refuse to start. On Apple there is one
  // candidate, Metal, exactly as before.
  Engine::Builder builder;
  const std::vector<OrbisBackend> candidates =
      orbis::backendCandidates(_backendAsked);
  for (OrbisBackend candidate : candidates) {
    // A backend whose driver is not installed is passed over rather than
    // tried: Filament loads the driver on its own thread, and a missing
    // Vulkan loader is a panic there that no try here can catch.
    if (!orbis::backendLoadable(candidate)) {
      orbis::log("[orbis] %s has no driver on this machine.",
                 orbis::backendName(candidate));
      continue;
    }
    builder.backend(orbis::filamentBackend(candidate));
    try {
      _engine = builder.build();
    } catch (const std::exception &error) {
      orbis::log("[orbis] %s would not start: %s",
                 orbis::backendName(candidate), error.what());
      _engine = nullptr;
    }
    if (_engine != nullptr) {
      _backend = candidate;
      break;
    }
  }
  ASSERT_PRECONDITION(_engine != nullptr, "%s is unavailable.",
                      orbis::backendName(candidates.front()));
''')
sub('  NSMutableDictionary<NSString *, NSString *> *notes =\n'
    '      [NSMutableDictionary dictionary];', '  Notes notes;', count=3)
resub(r'\b(paths|texturePaths|names)\.count\b', r'\1.size()')
resub(r'(\b\w+(?:\[\w+\])?)\.UTF8String', r'\1')
sub('  if (_splatNotes == nullptr) _splatNotes = [NSMutableDictionary dictionary];\n'
    '  [_splatNotes removeAllObjects];', '  _splatNotes.clear();')
sub('    _splatNotes[@(note.first.c_str())] = @(note.second.c_str());',
    '    _splatNotes[note.first] = note.second;')
sub('      fromPass = [texturePaths[index] hasPrefix:@(kTargetScheme)];',
    '      fromPass = orbis::hasPrefix(texturePaths[index], kTargetScheme);')
sub('  for (NSString *name in names) targetNames.emplace_back(name);',
    '  for (const std::string &name : names) targetNames.emplace_back(name);')
sub('    NSString *native = [NSString stringWithUTF8String:it->first.c_str()];\n'
    '    [_assetNotes removeObjectForKey:native];', '    _assetNotes.erase(it->first);')
sub('  _fieldFrom = from != nullptr ? from : "";', '  _fieldFrom = from;')
sub('  [_assetNotes removeObjectForKey:"field"];', '  _assetNotes.erase("field");')
resub(r'"\[orbis\] %@: %zu files decoded in %\.0f ms",(\s*)_loadingName\.lastPathComponent,',
      r'"[orbis] %s: %zu files decoded in %.0f ms",\1orbis::lastPathComponent(_loadingName).c_str(),')
sub('''  drawOutline();
  _renderer->endFrame();
''', '''  drawOutline();
  // Read back for a host that asked to see the frame. Inside the frame, and
  // it has to be: Filament reads a swap chain between the passes and
  // endFrame, and nowhere else.
  readBackIfAsked();
  _renderer->endFrame();
''')
sub('''  // Flutter may sample the moment this returns, so the frame has to be on the
  // surface before it is advertised as presented.
  _engine->flushAndWait();
''', '''  // Flutter may sample the moment this returns, so the frame has to be on the
  // surface before it is advertised as presented.
  _engine->flushAndWait();

  // A frame read back arrives through Filament's callback queue, which is
  // only drained when somebody asks. Asking here makes it ready with the
  // frame rather than a frame later.
  bool pumping = false;
  {
    std::lock_guard<std::mutex> lock(_captureLock);
    pumping = _captureInFlight;
  }
  if (pumping) _engine->pumpMessageQueues();
''')
sub('''void Renderer::dispose() {
  if (_disposed) return;
  _disposed = true;
''', '''void Renderer::dispose() {
  if (_disposed) return;
  _disposed = true;
  // A renderer whose engine never started has nothing of Filament's to give
  // back, and the teardown below would reach for what was never made.
  if (_engine == nullptr) return;
''')
sub('''  delete _surface;
  _surface = nullptr;
}''', '''  {
    // Under the lock, because the thread that samples frames asks the
    // surface for one without going through the engine's queue.
    std::lock_guard<std::mutex> lock(_presentLock);
    delete _surface;
    _surface = nullptr;
  }
}''')
sub('''// The arithmetic — sorting, the budget, the matrix into each box — is in
// OrbisDecals.cpp, which has nothing Apple in it. What is here is the part
// that is this platform's: turning an image file into pixels, and handing
// textures to Filament.''', '''// The arithmetic — sorting, the budget, the matrix into each box — is in
// OrbisDecals.cpp. What is here is handing textures to Filament; turning an
// image file into pixels is the platform layer's orbis::readPicture, which is
// ImageIO on Apple and stb_image everywhere else.''')
sub('''/// The pixel format is asked for explicitly: Filament's external images take
/// 32-bit BGRA or biplanar YUV and nothing else, and a decoder left to choose
/// will happily hand back something neither of them.''', '''/// The decoder is the platform's: AVFoundation on Apple, where the pixel
/// format Filament's external images need is asked for, and nothing yet
/// elsewhere, which the notes then say.''')


# [NSString stringWithFormat:...] spread over lines, which convert.py missed.
def matching(s, i):
    depth = 0
    j = i
    while j < len(s):
        c = s[j]
        if c == '"':
            j += 1
            while s[j] != '"':
                if s[j] == '\\':
                    j += 1
                j += 1
        elif c in '[({':
            depth += 1
        elif c in '])}':
            depth -= 1
            if depth == 0:
                return j
        j += 1
    raise ValueError(s[i:i + 80])


while True:
    m = re.search(r'\[NSString\s+stringWithFormat:', src)
    if not m:
        break
    close = matching(src, m.start())
    inner = src[m.end():close].strip()
    src = src[:m.start()] + 'orbis::format(' + inner + ')' + src[close + 1:]

# ---- whole functions ----
for block in re.split(r'^@@', open(REPL).read(), flags=re.M):
    if not block.strip():
        continue
    head, _, body = block.partition('\n')
    kind, _, prefix = head.partition(' ')
    if kind == 'APPEND':
        end = '}  // namespace orbis'
        stripped = src.rstrip()
        assert stripped.endswith(end)
        src = stripped[:-len(end)] + body.rstrip('\n') + '\n\n' + end + '\n'
        continue
    lines = src.split('\n')
    start = next((i for i, l in enumerate(lines) if l.startswith(prefix)), None)
    if start is None:
        print('NOT FOUND', prefix)
        continue
    stop = next(i for i in range(start, len(lines)) if lines[i] == '}')
    if kind == 'DELETE':
        s = start
        while s > 0 and lines[s - 1].startswith('///'):
            s -= 1
        e = stop + 1
        if e < len(lines) and lines[e].strip() == '':
            e += 1
        del lines[s:e]
    else:
        lines[start:stop + 1] = body.rstrip('\n').split('\n')
    src = '\n'.join(lines)

open(CPP, 'w').write(src)
print('fixed')
