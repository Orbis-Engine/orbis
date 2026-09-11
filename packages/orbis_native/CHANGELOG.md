# Changelog

## 0.2.0

- **Native scripts load and unload on Windows.** A script's library is opened
  with `LoadLibraryW` and its symbols found with `GetProcAddress`, because a
  DLL loaded after the fact is not visible through the process handle the way
  a shared object is on macOS and Linux. `FreeLibrary` on close matters as
  much: a still-mapped DLL cannot be deleted, so a rebuilt script would
  otherwise leave its first build stuck on disk. On Windows the compiler search
  tries `clang-cl`, then `clang++`, then MSVC's `cl`, and passes MSVC-style
  flags to the first and last. Checked by reading it against the Win32 and
  compiler documentation only — there is no Windows machine to run it on; the
  macOS and Linux paths are unchanged and still tested end to end.

## 0.1.1

- Scripts load on Linux. The dlopen flags were macOS's: RTLD_LOCAL is 4 there
  and 0 on glibc, where 4 means RTLD_NOLOAD — so every load asked for a handle
  to a library nobody had opened, got null, and reported "unknown", because
  nothing had actually gone wrong.

## 0.1.0

- First cut of `orbis_native`. Pre-alpha: everything is subject to change.
