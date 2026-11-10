# RC-Scheme

A simple scheme written as an exercise for the recurse center.

## Quick Start

Requires _zig 0.17_

```
zig build
./zig-out/bin/scm < example1.scm
```

OR

```
zig build run < example1.scm
```

This will parse the contents of `example1.scm` and echo it back out to console.

- expression evaluation is not yet implemented
- `scm` reads from stdin
