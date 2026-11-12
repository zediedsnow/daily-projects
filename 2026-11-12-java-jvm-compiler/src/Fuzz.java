import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.lang.reflect.InvocationTargetException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;

/**
 * Differential fuzzer: generates random (terminating) Jolt programs, runs each one through
 * the bytecode compiler and the reference interpreter, and demands identical output and
 * identical failure (e.g. both throw ArithmeticException after printing the same lines).
 */
final class Fuzz {
    private final Random r;
    private final StringBuilder sb = new StringBuilder();
    private List<String> vars = new ArrayList<>();
    private final java.util.Set<String> readonly = new java.util.HashSet<>();   // for-loop counters
    private int fnCount, uniq, indent;

    private Fuzz(long seed) { r = new Random(seed); }

    static int run(int count, long seed0) throws Exception {
        int fails = 0, threw = 0;
        long lines = 0;
        for (int i = 0; i < count; i++) {
            long seed = seed0 + i;
            String src = new Fuzz(seed).program();
            lines += src.lines().count();
            Program prog = Parser.parse(src);
            Checker.check(prog);
            String cls = "Fuzz" + seed;
            String[] a = compiled(Codegen.compile(prog, cls), cls), b = interpreted(prog);
            if (!a[0].equals(b[0]) || !a[1].equals(b[1])) {
                fails++;
                System.out.println("MISMATCH for seed " + seed + "\n" + src);
                System.out.println("compiled:    " + a[1] + "\n" + a[0]);
                System.out.println("interpreted: " + b[1] + "\n" + b[0]);
                if (fails >= 3) break;
            }
            if (!a[1].isEmpty()) threw++;
        }
        System.out.printf("%d random programs (%d lines total), %d ended in a runtime exception; %d mismatches%n",
            count, lines, threw, fails);
        return fails == 0 ? 0 : 1;
    }

    private static String[] compiled(byte[] bytes, String cls) throws Exception {
        ByteArrayOutputStream bo = new ByteArrayOutputStream();
        PrintStream ps = new PrintStream(bo, true, StandardCharsets.UTF_8), saved = System.out;
        System.setOut(ps);
        String err = "";
        try {
            Class<?> k = new ClassLoader(Fuzz.class.getClassLoader()) {
                Class<?> load() { return defineClass(cls, bytes, 0, bytes.length); }
            }.load();
            k.getMethod("main", String[].class).invoke(null, (Object) new String[0]);
        } catch (InvocationTargetException e) {
            err = e.getCause().getClass().getSimpleName();
        } finally { ps.flush(); System.setOut(saved); }
        return new String[] {bo.toString(StandardCharsets.UTF_8), err};
    }

    private static String[] interpreted(Program prog) {
        ByteArrayOutputStream bo = new ByteArrayOutputStream();
        PrintStream ps = new PrintStream(bo, true, StandardCharsets.UTF_8);
        String err = "";
        try { Interpreter.run(prog, ps); } catch (RuntimeException e) { err = e.getClass().getSimpleName(); }
        ps.flush();
        return new String[] {bo.toString(StandardCharsets.UTF_8), err};
    }

    // ---------------- generator ----------------
    private static final long[] CONSTS = {0, 1, -1, 2, 3, 7, 10, 255, -128, 32767, 65536, 1L << 31,
        Long.MAX_VALUE, Long.MIN_VALUE, 1_000_000_007L, -9};
    private static final String[] BINOPS = {"+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">=", "&&", "||"};

    private String program() {
        int nf = r.nextInt(4);
        for (int i = 0; i < nf; i++) {
            vars = new ArrayList<>(List.of("a", "b"));
            line("fn f" + i + "(a: int, b: int, arr: int[]): int {");
            indent++;
            stmts(2 + r.nextInt(4), 0, false);
            line("return " + expr(3) + ";");
            indent--;
            line("}");
            fnCount++;
        }
        vars = new ArrayList<>();
        line("let arr = array(8);");
        for (int i = 0; i < 3; i++) { String v = "v" + uniq++; line("let " + v + " = " + expr(2) + ";"); vars.add(v); }
        stmts(4 + r.nextInt(6), 0, false);
        line("print(" + String.join(", ", vars) + ", arr);");
        return sb.toString();
    }

    private void line(String s) { sb.append("    ".repeat(indent)).append(s).append('\n'); }

    private String expr(int d) {
        if (d <= 0 || r.nextInt(10) < 3) {
            return switch (r.nextInt(5)) {
                case 0, 1 -> vars.isEmpty() ? "1" : vars.get(r.nextInt(vars.size()));
                case 2 -> "arr[" + index(d) + "]";
                case 3 -> "len(arr)";
                default -> { long c = CONSTS[r.nextInt(CONSTS.length)]; yield c == Long.MIN_VALUE ? "(-9223372036854775807 - 1)" : Long.toString(c); }
            };
        }
        return switch (r.nextInt(9)) {
            case 0 -> "-" + paren(d);
            case 1 -> "!" + paren(d);
            case 2 -> "abs(" + expr(d - 1) + ")";
            case 3 -> fnCount > 0 ? "f" + r.nextInt(fnCount) + "(" + expr(d - 1) + ", " + expr(d - 1) + ", arr)" : expr(d - 1);
            default -> {
                String op = BINOPS[r.nextInt(BINOPS.length)];
                // Mostly keep divisors non-zero so programs run to completion; sometimes allow /0.
                String rhs = (op.equals("/") || op.equals("%")) && r.nextInt(10) < 8
                    ? "(abs(" + expr(d - 1) + " % 5) + 1)" : expr(d - 1);
                yield "(" + expr(d - 1) + " " + op + " " + rhs + ")";
            }
        };
    }

    private String paren(int d) { return "(" + expr(d - 1) + ")"; }
    private String index(int d) { return "abs(" + expr(d - 1) + " % 8)"; }   // always in range 0..7

    private void stmts(int n, int depth, boolean inLoop) {
        for (int i = 0; i < n; i++) stmt(depth, inLoop);
    }

    private void block(int depth, boolean inLoop) {
        indent++;
        List<String> saved = new ArrayList<>(vars);
        stmts(1 + r.nextInt(3), depth + 1, inLoop);
        vars = saved;
        indent--;
    }

    private void stmt(int depth, boolean inLoop) {
        int k = r.nextInt(depth >= 2 ? 5 : 9);
        switch (k) {
            case 0 -> { String v = "v" + uniq++; line("let " + v + " = " + expr(3) + ";"); vars.add(v); }
            case 1 -> {
                List<String> w = vars.stream().filter(v -> !readonly.contains(v)).toList();
                if (w.isEmpty()) line("print(" + expr(2) + ");");
                else line(w.get(r.nextInt(w.size())) + " = " + expr(3) + ";");
            }
            case 2 -> line("arr[" + index(2) + "] = " + expr(3) + ";");
            case 3 -> line("print(" + expr(2) + ", \"|\", " + expr(2) + ");");
            case 4 -> {
                if (inLoop && r.nextBoolean()) line("if " + expr(2) + " { " + (r.nextBoolean() ? "break" : "continue") + "; }");
                else line("print(" + expr(3) + ");");
            }
            case 5, 6 -> {
                line("if " + expr(3) + " {");
                block(depth, inLoop);
                if (r.nextBoolean()) { line("} else {"); block(depth, inLoop); }
                line("}");
            }
            case 7 -> {
                String v = "i" + uniq++;
                line("for " + v + " in " + (r.nextInt(3) - 1) + ".." + r.nextInt(6) + " {");
                vars.add(v);
                readonly.add(v);
                block(depth, true);
                vars.remove(v);
                line("}");
            }
            default -> {   // bounded while loop
                String w = "w" + uniq++;
                line("let " + w + " = 0;");
                line("while " + w + " < " + r.nextInt(5) + " && " + expr(2) + " {");
                indent++;
                line(w + " = " + w + " + 1;");
                indent--;
                block(depth, false);   // no `continue` here: it would skip the counter
                line("}");
            }
        }
    }
}
