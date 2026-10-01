# Package fixes for FreeBSD/cross-compilation issues
final: prev: {
  # SQLite's doCheck runs the "devtest" target which executes tests via Tcl.
  # These tests fail on FreeBSD (test infrastructure issues) and also when
  # cross-compiling (can't run target binaries on build host).
  sqlite = prev.sqlite.overrideAttrs (old: {
    doCheck = false;
  });
}
