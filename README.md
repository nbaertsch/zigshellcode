# zigshellcode

Small Zig project for generating Windows shellcode from an exported function range (`go` -> `goEnd`) and testing it with a simple loader.

## Requirements

- Zig `>= 0.15.2` (from `build.zig.zon`)
- Linux/WSL or Windows environment that can cross-build Windows targets
- Optional (for export inspection): `x86_64-w64-mingw32-objdump`

## What the project builds

- `zig build` (default): test executables (`test-x86`, `test-x86_64`, `test-aarch64`)
- `zig build sc`: shellcode pipeline
  - builds Windows DLL carrier artifacts (`sc-*.dll`)
  - carves bytes between exported `go` and `goEnd`
  - writes shellcode files to `zig-out/bin/`:
    - `x86.sc`
    - `x86_64.sc`
    - `aarch64.sc`
- `zig build loader`: shellcode loader executables (`loader-*.exe`)

List steps:

```bash
zig build -l
```

## End-to-end quick start

### 1) Build shellcode

```bash
zig build sc
```

Expected outputs in `zig-out/bin/`:

- `sc-x86.dll`, `sc-x86_64.dll`, `sc-aarch64.dll`
- `x86.sc`, `x86_64.sc`, `aarch64.sc`

### 2) Build loader

```bash
zig build loader
```

### 3) Run loader with generated shellcode

```bash
./zig-out/bin/loader-x86_64.exe ./zig-out/bin/x86_64.sc
```

You can also pass Linux/WSL-style absolute paths; loader path handling includes WSL conversion fallbacks.

## DLL exports used by carving

The carving step expects these exported symbols from `src/main.zig`:

- `go`
- `goEnd`

`DllMain` is also exported and currently calls `go()` on `DLL_PROCESS_ATTACH` for DLL-load testing.

## Useful checks

Inspect DLL exports:

```bash
x86_64-w64-mingw32-objdump -p zig-out/bin/sc-x86_64.dll | sed -n '/\[Ordinal\/Name Pointer\] Table/,+20p'
```

Check artifact timestamps/sizes:

```bash
ls -l zig-out/bin/sc-x86_64.dll zig-out/bin/x86_64.sc
```

## Project structure

- `build.zig` — build graph + shellcode generation step
- `src/main.zig` — DLL payload logic (`DllMain`, `go`, `goEnd`)
- `src/loader.zig` — executable shellcode loader
- `src/win32.zig` — Windows structures/constants used for PE parsing
