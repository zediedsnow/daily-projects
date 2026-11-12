import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.lang.reflect.InvocationTargetException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;

/** Command-line driver: jolt run|compile|interp|bench|test. */
public final class Jolt {
    static final String USAGE = """
        usage:
          jolt run     <file.jolt>             compile to bytecode in memory and execute it
          jolt compile <file.jolt> [-d dir]    write a standalone .class file (run it with plain `java`)
          jolt interp  <file.jolt>             run with the tree-walking reference interpreter
          jolt bench   <file.jolt>             compare compiled vs interpreted speed
          jolt test    [dir]                   run every example both ways and check outputs agree
          jolt fuzz    [count] [seed]          differential-test compiler vs interpreter on random programs
        """;

    public static void main(String[] args) throws Exception {
        if (args.length < 1) { System.err.print(USAGE); System.exit(2); }
        int code = onBigStack(() -> dispatch(args));
        System.out.flush();
        System.exit(code);
    }

    private static int dispatch(String[] args) throws Exception {
        String cmd = args[0];
        if (cmd.equals("fuzz")) return Fuzz.run(args.length > 1 ? Integer.parseInt(args[1]) : 2000, args.length > 2 ? Long.parseLong(args[2]) : 1);
        if (cmd.equals("test")) return test(Path.of(args.length > 1 ? args[1] : "examples"));
        if (args.length < 2) { System.err.print(USAGE); return 2; }
        Path file = Path.of(args[1]);
        String src = Files.readString(file);
        String cls = className(file);
        Program prog;
        try {
            prog = Parser.parse(src);
            Checker.check(prog);
        } catch (CompileError e) {
            System.err.println(file + ": " + e.getMessage());
            return 1;
        }
        switch (cmd) {
            case "run" -> { return runCompiled(Codegen.compile(prog, cls), cls, System.out); }
            case "interp" -> {
                try { Interpreter.run(prog, System.out); return 0; }
                catch (RuntimeException | StackOverflowError e) { System.out.flush(); System.err.println("runtime error: " + e); return 1; }
            }
            case "compile" -> {
                Path dir = Path.of(args.length > 3 && args[2].equals("-d") ? args[3] : ".");
                Files.createDirectories(dir);
                byte[] bytes = Codegen.compile(prog, cls);
                Path out = dir.resolve(cls + ".class");
                Files.write(out, bytes);
                System.out.println("wrote " + out + " (" + bytes.length + " bytes, " + prog.fns.size() + " methods)");
                return 0;
            }
            case "bench" -> { return bench(prog, cls); }
            default -> { System.err.print(USAGE); return 2; }
        }
    }

    /** "examples/n-queens.jolt" -> "NQueens" */
    static String className(Path file) {
        String stem = file.getFileName().toString().replaceFirst("\\.jolt$", "");
        StringBuilder sb = new StringBuilder();
        boolean up = true;
        for (char ch : stem.toCharArray()) {
            if (!Character.isLetterOrDigit(ch)) { up = true; continue; }
            sb.append(up ? Character.toUpperCase(ch) : ch);
            up = false;
        }
        if (sb.isEmpty() || !Character.isLetter(sb.charAt(0))) sb.insert(0, "J");
        return sb.toString();
    }

    /** Hand the raw class bytes to the JVM, then call the generated main(String[]). */
    static int runCompiled(byte[] bytes, String cls, PrintStream out) throws Exception {
        PrintStream saved = System.out;
        System.setOut(out);
        try {
            Class<?> k = new ClassLoader(Jolt.class.getClassLoader()) {
                Class<?> load() { return defineClass(cls, bytes, 0, bytes.length); }
            }.load();
            k.getMethod("main", String[].class).invoke(null, (Object) new String[0]);
            return 0;
        } catch (InvocationTargetException e) {
            out.flush();
            System.err.println("runtime error: " + e.getCause());
            return 1;
        } finally {
            out.flush();
            System.setOut(saved);
        }
    }

    // ---------------- bench ----------------
    private static int bench(Program prog, String cls) throws Exception {
        long t0 = System.nanoTime();
        byte[] bytes = Codegen.compile(prog, cls);
        double compileMs = (System.nanoTime() - t0) / 1e6;

        ByteArrayOutputStream a = new ByteArrayOutputStream(), b = new ByteArrayOutputStream();
        t0 = System.nanoTime();
        runCompiled(bytes, cls, new PrintStream(a, false, StandardCharsets.UTF_8));
        double compiledMs = (System.nanoTime() - t0) / 1e6;
        t0 = System.nanoTime();
        PrintStream ps = new PrintStream(b, false, StandardCharsets.UTF_8);
        Interpreter.run(prog, ps);
        ps.flush();
        double interpMs = (System.nanoTime() - t0) / 1e6;

        boolean same = a.toString(StandardCharsets.UTF_8).equals(b.toString(StandardCharsets.UTF_8));
        System.out.printf("codegen      %8.2f ms   (%d bytes of class file)%n", compileMs, bytes.length);
        System.out.printf("compiled     %8.1f ms%n", compiledMs);
        System.out.printf("interpreted  %8.1f ms%n", interpMs);
        System.out.printf("speedup      %8.1fx    outputs %s%n", interpMs / compiledMs, same ? "identical" : "DIFFER");
        return same ? 0 : 1;
    }

    // ---------------- test ----------------
    private static int test(Path dir) throws Exception {
        List<Path> files = new ArrayList<>();
        try (var s = Files.list(dir)) { s.filter(p -> p.toString().endsWith(".jolt")).sorted().forEach(files::add); }
        int pass = 0;
        for (Path f : files) {
            String cls = className(f);
            Program prog = Parser.parse(Files.readString(f));
            Checker.check(prog);
            ByteArrayOutputStream a = new ByteArrayOutputStream(), b = new ByteArrayOutputStream();
            long t0 = System.nanoTime();
            runCompiled(Codegen.compile(prog, cls), cls, new PrintStream(a, false, StandardCharsets.UTF_8));
            long t1 = System.nanoTime();
            PrintStream ps = new PrintStream(b, false, StandardCharsets.UTF_8);
            Interpreter.run(prog, ps);
            ps.flush();
            long t2 = System.nanoTime();
            String compiled = a.toString(StandardCharsets.UTF_8), interp = b.toString(StandardCharsets.UTF_8);
            Path expFile = Path.of(f.toString().replaceFirst("\\.jolt$", ".expected"));
            String expected = Files.exists(expFile) ? Files.readString(expFile) : null;
            boolean ok = compiled.equals(interp) && (expected == null || expected.equals(compiled));
            if (ok) pass++;
            System.out.printf("%-4s %-22s compiled %7.1f ms   interpreted %8.1f ms%s%n", ok ? "ok" : "FAIL",
                f.getFileName(), (t1 - t0) / 1e6, (t2 - t1) / 1e6, expected == null ? "   (no .expected file)" : "");
            if (!ok) {
                System.out.println("--- compiled ---\n" + compiled + "--- interpreted ---\n" + interp
                    + (expected != null ? "--- expected ---\n" + expected : ""));
            }
        }
        System.out.println(pass + "/" + files.size() + " examples passed");
        return pass == files.size() ? 0 : 1;
    }

    // Deep recursion (e.g. Ackermann) needs more than the default 8 MB thread stack.
    private interface Task { int run() throws Exception; }
    private static int onBigStack(Task t) throws Exception {
        AtomicReference<Object> result = new AtomicReference<>();
        Thread th = new Thread(null, () -> {
            try { result.set(t.run()); } catch (Throwable e) { result.set(e); }
        }, "jolt", 1L << 30);
        th.start();
        th.join();
        Object r = result.get();
        if (r instanceof Exception e) throw e;
        if (r instanceof Error e) throw e;
        return (Integer) r;
    }
}
