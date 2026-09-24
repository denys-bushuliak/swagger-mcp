# Fuzzing (EPIC: AFL++)

Two fuzzing lanes:

1. **Native (zig-only)** — `zig build test --fuzz[=N]` is *blocked on Zig
   0.16.0* (`compiler/test_runner.zig` fails to compile with `-ffuzz`;
   upstream bug). Plain `zig build test` still replays `src/fuzz_corpus/`
   seeds once per fuzz test, so corpus regressions are caught in CI.

2. **AFL++ QEMU mode (verified, needs Docker on macOS / any Linux)** — AFL++
   clang instrumentation cannot see Zig code, so we fuzz the static harness
   binary with `afl-fuzz -Q`:

   ```sh
   zig build fuzz-target -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
   docker run --rm -e AFL_SKIP_CPUFREQ=1 -e AFL_NO_AFFINITY=1 \
     -e AFL_TMPDIR=/ramdisk --mount type=tmpfs,destination=/ramdisk \
     -v "$PWD":/work aflplusplus/aflplusplus bash -c \
     'cd /work && afl-fuzz -Q -i src/fuzz_corpus -x fuzz/dictionaries/swagger.dict \
      -m 512 -o fuzz/out -- ./zig-out/bin/swagger-mcp-fuzz @@'
   ```

   On x86_64 build with `-Dtarget=x86_64-linux-musl` instead. Drop the `-V 90`
   (visible in scripts) for an open-ended campaign; Ctrl-C to stop, restart
   with the same command.

Crashes land in `fuzz/out/default/crashes/`. Minimize with `afl-cmin`/`afl-tmin`,
then reproduce with `zig-out/bin/swagger-mcp-fuzz <crash-file>` and add the file
to `src/fuzz_corpus/` as a regression seed.
