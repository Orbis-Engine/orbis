#!/usr/bin/env python3
"""header.py <OrbisRenderer.mm> <prelude> <declarations> <out header>"""
import re
import sys

MM, PRELUDE, DECLS, OUT = sys.argv[1:5]
lines = open(MM).read().split('\n')

# ---- the prelude, made fit for a header ----
prelude = open(PRELUDE).read()
prelude = prelude.replace('using namespace filament;\nusing namespace filament::math;\n', '')
prelude = prelude.replace('static uint64_t mortonOf(', 'inline uint64_t mortonOf(')
prelude = prelude.replace('  NSString *path;\n', '  std::string path;\n')
prelude = re.sub(
    r'static void readWholeFile\(Wanted &one\) \{.*?\n\}\n',
    'inline void readWholeFile(Wanted &one) {\n'
    '  orbis::readWholeFile(one.path, &one.bytes, &one.size);\n'
    '}\n', prelude, flags=re.S)
prelude = re.sub(
    r'struct Movie \{.*?\n\};\n',
    '''struct Movie {
  /// What decodes it, from the platform layer. Null while nothing is open,
  /// and always null where the platform has no decoder yet.
  std::unique_ptr<orbis::VideoDecoder> decoder;
  filament::Texture *texture = nullptr;

  std::string path;
  int32_t flags = -1;
  float rate = 1.0f;
  float volume = 1.0f;
  int32_t seekToken = -1;
  bool looping = false;
  uint64_t seen = 0;
};
''', prelude, flags=re.S)
prelude = prelude.replace('static constexpr float3 kDefaultAmbient', 'constexpr float3 kDefaultAmbient')
prelude = prelude.replace('static constexpr float kDefaultAmbientIntensity', 'constexpr float kDefaultAmbientIntensity')
prelude = prelude.replace('\nnamespace {\n', '\n')
prelude = prelude.replace('\n}  // namespace\n', '\n')

# ---- the ivar block, as members ----
s = next(i for i, l in enumerate(lines) if l.startswith('@implementation OrbisRenderer {'))
e = next(i for i in range(s, len(lines)) if lines[i] == '}')
members = []
for l in lines[s + 1:e]:
    t = l
    if not t.strip().startswith('//'):
        t = t.replace('NSMutableDictionary<NSString *, NSString *> *', 'Notes ')
        t = t.replace('NSString *_loadingName;', 'std::string _loadingName;')
        t = re.sub(r'NSLock \*(_\w+);', r'std::mutex \1;', t)
        t = re.sub(r'\bBOOL\b', 'bool', t)
        t = re.sub(r'\bNSUInteger\b', 'size_t', t)
        t = re.sub(r'\bNSInteger\b', 'int', t)
        t = re.sub(r'^(\s+)Renderer \*_renderer;', r'\1filament::Renderer *_renderer;', t)
        m = re.match(r'^(\s+)(\S.*?[\s*&])(_\w+)(\[[^\]]+\])?;\s*$', t)
        if m:
            indent, typ, name, arr = m.group(1), m.group(2), m.group(3), m.group(4) or ''
            init = '{}'
            if typ.strip() == 'float3' and not arr:
                init = '{0.0f, 0.0f, 0.0f}'
            if 'std::mutex' in typ:
                init = ''
            t = f'{indent}{typ}{name}{arr}{init};'
    members.append(t)

API = {'initWithWidth', 'renderAtTime', 'applyObjects', 'setBatching', 'batchedObjects',
       'batchGroups', 'applyMaterials', 'setPipeline', 'applyVideos', 'applyLights',
       'applyDecals', 'setFogEnabled', 'setPostProcess', 'applyProbes', 'applyField',
       'setEnvironmentRadiance', 'setRenderGraph', 'setGodRays', 'passTimings', 'gpuMilliseconds',
       'cpuMilliseconds', 'hasPopulations', 'applyPopulations', 'hasSplats', 'applySplats',
       'setSkyEnabled', 'setPrecipitationEnabled', 'notes', 'setSkyColour',
       'setCameraPosition', 'setExposure', 'setOutlineKeys', 'resizeToWidth',
       'copyPresentedBuffer', 'dispose', 'dealloc', 'restartIfLooping'}
private = []
for d in open(DECLS).read().split('\n'):
    m = re.match(r'\s+.*?[\s*&](\w+)\(', d)
    if not d.strip() or (m and m.group(1) in API):
        continue
    private.append(d)

header = open(OUT + '.in').read()
header = header.replace('@@PRELUDE@@', prelude.rstrip('\n'))
header = header.replace('@@PRIVATE@@', '\n'.join(private))
header = header.replace('@@MEMBERS@@', '\n'.join(members))
open(OUT, 'w').write(header)
print('private methods', len(private), 'member lines', len(members))
