# Stage 1 — Fight the registers until they make sense

Four small, heavily-commented programs. No SDL2, no game logic — just
the raw mechanics you need before any of that is possible. Each file
ends with a "try this in gdb" section and a few questions meant to be
answered by experimenting, not by re-reading the comments.

## Build everything

```bash
make            # builds every .asm into build/
make clean      # removes build/
```

Each binary is built with `-g -F dwarf`, so gdb can show you source
lines, not just raw addresses.

## Suggested order

1. **`01_registers_arithmetic.asm`** — `mov`, `add`/`sub`/`imul`/`idiv`,
   bitwise ops. No I/O — step through it in gdb and watch registers
   change. Do this one slowly; everything else builds on it.
2. **`02_stack_basics.asm`** — `push`/`pop`, manual scratch space with
   `sub rsp` / `add rsp`. Watch `rsp` move in gdb with `x/1gx $rsp`.
3. **`03_cmp_jumps_sum.asm`** — `cmp` + conditional jumps as a loop,
   plus the standard "convert an integer to a decimal string by hand"
   trick. This one prints real output.
4. **`04_calling_convention.asm`** — `call`/`ret`, the System V
   argument registers, caller-saved vs callee-saved, stack alignment,
   and a proper `rbp`-based local stack frame. This is the exact
   pattern you'll use to call `SDL_Init` etc. in Stage 2 — it's not a
   toy rule specific to this exercise.

## Running under gdb

```bash
gdb ./build/01_registers_arithmetic
(gdb) break _start
(gdb) run
(gdb) stepi                          # one instruction at a time
(gdb) info registers rax rbx rcx rdx
```

Useful gdb commands you'll want across all four files:

- `stepi` / `si` — step one machine instruction
- `nexti` / `ni` — like stepi, but steps OVER a `call` instead of into it
- `info registers` (or a specific subset, e.g. `info registers rax rdi`)
- `x/4gx $rsp` — examine memory at rsp: 4 "giant" (8-byte) values, in hex
- `display rax` — auto-print a register after every step (repeat for others)
- `break <label>` — breakpoint on a label (e.g. `break factorial`)
- `continue` — run until the next breakpoint hit
- `finish` — run until the current function returns, show the return value

## What's deliberately not here yet

- No error handling on the syscalls (Stage 1 assumes they succeed —
  real error checking shows up once it actually matters, in Stage 2+).
- No reusable "print an integer" library function shared across files
  — `03` and `04` each roll their own on purpose, so you see the same
  logic twice in two different contexts (flat `.bss` buffer vs. a
  proper stack frame) before you'd bother factoring it out.
