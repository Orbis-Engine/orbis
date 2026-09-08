# Changelog

## 0.1.1

- Scripts load on Linux. The dlopen flags were macOS's: RTLD_LOCAL is 4 there
  and 0 on glibc, where 4 means RTLD_NOLOAD — so every load asked for a handle
  to a library nobody had opened, got null, and reported "unknown", because
  nothing had actually gone wrong.

## 0.1.0

- First cut of `orbis_native`. Pre-alpha: everything is subject to change.
