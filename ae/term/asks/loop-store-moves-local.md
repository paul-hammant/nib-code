# A local stored into a slice element inside a loop is moved by the first store

**For:** aether (compiler, last-use moves). **From:** nib-code's `ae/term`,
2026-11-12, Aether 0.909.0 on macOS arm64.

## Repro

```aether
struct Cell { g: string  w: int }
struct Grid { cells: Cell[] }
mk() -> Cell { return Cell { g: " ", w: 1 } }
fill(gr: *Grid, n: int) {
    cells = make([]Cell, n)
    blank = mk()
    for i in 0..n {
        cells[i] = blank
    }
    gr.cells = cells
}
main() {
    gr = heap.new(Grid)
    fill(gr, 3)
    println("[${gr.cells[0].g}][${gr.cells[1].g}][${gr.cells[2].g}]   (expected [ ][ ][ ])")
    names = make([]string, 3)
    x = "x"
    for i in 0..3 {
        names[i] = x
    }
    println("[${names[0]}][${names[1]}][${names[2]}]   (expected [x][x][x])")
}
```

prints

```
[ ][][]   (expected [ ][ ][ ])
[x][][]   (expected [x][x][x])
```

## Cause, as far as the generated C shows

The store is the local's last use *in the source*, so it is lowered as a
move: `(*_ae_ep) = _aether_move_Cell(&blank);`. Inside a loop body that use
runs once per iteration; the first iteration empties `blank` and every
later one stores the emptied value. The string case is the same with a
`string` local.

Not every variant shows it (a struct local stored in a loop, with the slice
left in a local, printed correctly in one try), so the move decision seems
to depend on what else the function does with the slice; the two cases
above reproduce every time.

## What `ae/term` does meanwhile

Every loop that fills cells builds a fresh value per iteration
(`cells[i] = blank_cell()`), with a comment pointing here.

## Ask

A last use inside a loop body is not a last use unless the loop cannot run
again after it (or the local is re-bound before the next iteration's use):
store a copy (retain) there, and add both repros to `tests/regression/`.
