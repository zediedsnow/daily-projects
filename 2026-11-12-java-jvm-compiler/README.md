# Jolt — a compiler that writes JVM bytecode by hand

**Jolt** is a small, statically typed language whose compiler emits real `.class` files
**byte by byte** — no ASM, no `javax.tools`, no generated Java source. The output is
loaded straight into the running JVM (or written to disk and run with plain `java`),
where HotSpot verifies it and JIT-compiles it to machine code like any other class.

It's ~1,500 lines of dependency-free Java 21: lexer, recursive-descent parser, type
checker/slot allocator, a class-file writer with a de-duplicating constant pool and
label back-patching, a bytecode generator, a reference tree-walking interpreter, and a
differential fuzzer that pits the two against each other.

```
fn fib(n: int): int {
    if n < 2 { return n; }
    return fib(n - 1) + fib(n - 2);
}
print("fib(32) =", fib(32));
```

```
$ ./jolt compile examples/fib.jolt -d out
wrote out/Fib.class (590 bytes, 2 methods)
$ java -cp out Fib                # plain java, no Jolt runtime needed
first 15: [0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377]
fib(32) = 2178309
```

## Why it's interesting

- **The class file format, from scratch.** Magic `0xCAFEBABE`, the constant pool (with
  its famous wart that `long` entries occupy *two* indices), method descriptors like
  `([J)J`, the `Code` attribute, max-stack computation, and 16-bit branch offsets that
  must be patched after the fact. All in [`ClassWriter.java`](src/ClassWriter.java).
- **It passes the JVM verifier.** Every generated class goes through HotSpot's bytecode
  verifier. Jolt targets class-file version 49, which uses the type-*inferring* verifier,
  so no `StackMapTable` frames are needed.
- **Two-slot longs.** Jolt integers are 64-bit, so every local is either 2 slots (`long`)
  or 1 slot (`long[]`); the checker allocates JVM slots, the generator tracks operand-stack
  depth in slots and asserts the stack is empty after every statement.
- **Conditions compile to jumps, not booleans.** `a < b && !(c == d)` becomes `lcmp` +
  `ifge`/`ifeq` chains with proper short-circuiting (`jumpIf` in
  [`Codegen.java`](src/Codegen.java)); a 0/1 value is only materialised when you store one.
- **Correctness is checked, not hoped for.** `jolt fuzz` generates random terminating
  programs (nested loops, break/continue, arrays, function calls, overflow, division by
  zero) and requires the compiled class and the interpreter to print exactly the same thing
  and fail with the same exception. 20,000 programs / 1.25 M lines: **0 mismatches**.
  Deliberately breaking one branch inversion in the code generator is caught within
  2,000 programs.

## Build and run

Needs a JDK 17+ (tested on OpenJDK 21). No other dependencies.

```sh
./jolt run examples/mandelbrot.jolt     # compile in memory, run (builds itself on first use)
./jolt interp examples/fib.jolt         # same program on the tree-walking interpreter
./jolt bench examples/fib.jolt          # compiled vs interpreted, checks outputs match
./jolt compile examples/fib.jolt -d out # write Fib.class; then: java -cp out Fib ; javap -c out/Fib.class
./jolt test                             # every example, both engines, against .expected files
./jolt fuzz 20000                       # differential fuzzing
```

Or by hand: `javac -d build src/*.java && java -cp build Jolt run examples/fib.jolt`.

## Sample output

`./jolt test`:

```
ok   ackermann.jolt         compiled    86.6 ms   interpreted   2790.1 ms
ok   collatz.jolt           compiled    56.1 ms   interpreted   1381.5 ms
ok   features.jolt          compiled     3.7 ms   interpreted      1.1 ms
ok   fib.jolt               compiled    22.7 ms   interpreted   1729.7 ms
ok   mandelbrot.jolt        compiled    18.3 ms   interpreted     92.2 ms
ok   nqueens.jolt           compiled     5.6 ms   interpreted     55.9 ms
ok   quicksort.jolt         compiled    62.7 ms   interpreted    840.6 ms
ok   sieve.jolt             compiled    31.0 ms   interpreted    410.5 ms
8/8 examples passed
```

`./jolt bench examples/fib.jolt` — same AST, two back ends:

```
codegen         22.17 ms   (590 bytes of class file)
compiled         14.3 ms
interpreted    1559.2 ms
speedup         108.9x    outputs identical
```

`./jolt run examples/mandelbrot.jolt` (integer fixed-point arithmetic; Jolt has no floats):

```
                             ..................................
                         ......................:::::-==--::::......
                      .....................:::::::--==#+===-:::::.....
                   .....................:::::::::---==+***+=-::::::......
                 .....................:::::::::----=++####+==--::::::......
               ....................::::::::::---===+*%@@@%**==----::::.......
              ...................:::::::::--======++#@@@@@%*+====----::.......
            ...................:::::::---=+**#++*#***#@@@@***+%+===+*=-:......
           .................:::::------===+*%@%*%%@@@@@@@@@@@@@***#*#%--:.....
          ...............:::---------====++**@@@@@@@@@@@@@@@@@@@@@@%*==-::....
         ............::::=====----======+%%#@@@@@@@@@@@@@@@@@@@@@@@*+==--::...
         .......:::::---=+*+===+*+====++*#@@@@@@@@@@@@@@@@@@@@@@@@@@##@=-::...
        ....:::::::----==++*#***#%**+++*#@@@@@@@@@@@@@@@@@@@@@@@@@@@@*+=-:::..
        .::::::::-----===++*%@@@@@@@@***@@@@@@@@@@@@@@@@@@@@@@@@@@@@@%*=-:::..
       .:::::::----==+*++*#@@@@@@@@@@@%#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@#=--::::.
       :-----========+*###%@@@@@@@@@@@@%@@@@@@@@@@@@@@@@@@@@@@@@@@@@*==--::::.
       @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*++==--::::.
       ...  (mirror image)
```

What `fib` turns into (`javap -c out/Fib.class`) — note the comparison compiled to a single
`lcmp`/`ifge` and the default return the generator appends after the body:

```
public static long fib(long);
  Code:
     0: lload         0
     2: bipush        2
     4: i2l
     5: lcmp
     6: ifge          12
     9: lload         0
    11: lreturn
    12: lload         0
    14: lconst_1
    15: lsub
    16: invokestatic  #6                  // Method fib:(J)J
    19: lload         0
    21: bipush        2
    23: i2l
    24: lsub
    25: invokestatic  #6                  // Method fib:(J)J
    28: ladd
    29: lreturn
    30: lconst_0
    31: lreturn
```

Compile errors carry line numbers: `t.jolt: line 2: type mismatch: expected int but got int[]`;
runtime faults surface as the JVM's own exceptions (`ArrayIndexOutOfBoundsException`,
`ArithmeticException: / by zero`) after any output printed so far.

## The language

```
fn name(a: int, xs: int[]): int { ... }   // functions (any order, recursion OK); return type int or int[]
let x = 1_000_000;  let a: int[] = [1, 2, 3];  let b = array(n);   // locals, block-scoped, shadowable
x = x + 1;  a[i] = v;                      // assignment
if c { } else if d { } else { }   while c { }   for i in 0..n { }   break;  continue;  return e;
+ - * / %   == != < <= > >=   && || !      // 64-bit wrapping integers; comparisons yield 0/1
len(a)  array(n)  abs(x)  clock()  putc('#')  print("text", x, a)   // 'c' is a char code
```

Top-level statements form `main`. Everything is either `int` (JVM `long`) or `int[]`
(JVM `long[]`), so the type checker is small but real: it rejects `[1,2] + 1`, wrong
arity, unknown names, and `break` outside a loop.

## How it works

| Stage | File | Notes |
|---|---|---|
| Lex | [`Lexer.java`](src/Lexer.java) | numbers with `_`, char literals, string escapes, `//` comments |
| Parse | [`Parser.java`](src/Parser.java) | recursive descent with a precedence table; folds `-literal` |
| Check | [`Checker.java`](src/Checker.java) | resolves names to JVM local slots (2 per `long`), infers `let` types, checks calls |
| Generate | [`Codegen.java`](src/Codegen.java) | one `public static` method per function; rotated loops (test at bottom); short-circuit `jumpIf` |
| Emit | [`ClassWriter.java`](src/ClassWriter.java) | constant pool, method/`Code` attributes, label fix-ups, max-stack |
| Load | [`Jolt.java`](src/Jolt.java) | `ClassLoader.defineClass` on the raw bytes, then reflectively call `main` |
| Verify | [`Interpreter.java`](src/Interpreter.java), [`Fuzz.java`](src/Fuzz.java) | reference semantics + differential fuzzing |

A few details worth knowing:

- **Loops are rotated**: `while c { body }` becomes `goto test; body: …; test: if c goto body`,
  so each iteration costs one conditional branch.
- **`for i in a..b`** evaluates `b` once into a hidden local; `continue` jumps to the increment.
- **Stack depth** is tracked per opcode (`op(opcode, delta)`); where control flow merges
  (e.g. materialising `a < b` as 0/1) the generator restores the depth the other path
  arrives with. The resulting max is written as the method's `max_stack`.
- **Programs run on a 1 GB thread stack**, so deep recursion like `ack(3, 9)` works on both
  back ends.
