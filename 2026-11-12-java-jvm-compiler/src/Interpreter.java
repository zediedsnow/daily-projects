import java.util.Arrays;
import java.util.List;

/**
 * Reference tree-walking interpreter over the same checked AST. It exists to (1) cross-check
 * the compiler's output on every example and (2) show what compiling to bytecode buys you.
 */
final class Interpreter {
    private static final class ReturnSignal extends RuntimeException {
        Object value;
        ReturnSignal() { super(null, null, false, false); }   // no stack trace: it's control flow
    }
    private static final class BreakSignal extends RuntimeException {
        static final BreakSignal I = new BreakSignal();
        BreakSignal() { super(null, null, false, false); }
    }
    private static final class ContinueSignal extends RuntimeException {
        static final ContinueSignal I = new ContinueSignal();
        ContinueSignal() { super(null, null, false, false); }
    }

    private final StringBuilder outBuf = new StringBuilder();
    private final java.io.PrintStream out;

    Interpreter(java.io.PrintStream out) { this.out = out; }

    static void run(Program prog, java.io.PrintStream out) {
        Interpreter in = new Interpreter(out);
        try { in.invoke(prog.main, new Object[0]); }
        finally { in.flush(); }
    }

    private void flush() { out.print(outBuf); outBuf.setLength(0); }

    private Object invoke(Fn f, Object[] args) {
        Object[] frame = new Object[Math.max(f.maxSlots, 1)];
        for (int i = 0; i < args.length; i++) frame[f.params.get(i).slot] = args[i];
        try {
            block(f.body, frame);
            return f.ret == Ty.INT ? (Object) 0L : null;
        } catch (ReturnSignal r) {
            return r.value != null || f.ret == Ty.ARR ? r.value : (Object) 0L;
        }
    }

    private void block(Ast.Block b, Object[] fr) { for (Ast.Stmt s : b.stmts) stmt(s, fr); }

    private void stmt(Ast.Stmt s, Object[] fr) {
        switch (s) {
            case Ast.Block b -> block(b, fr);
            case Ast.Let let -> fr[let.local.slot] = eval(let.init, fr);
            case Ast.Assign a -> fr[a.target.local.slot] = eval(a.value, fr);
            case Ast.IndexAssign ia -> {
                long[] arr = (long[]) eval(ia.arr, fr);
                int i = (int) num(ia.idx, fr);
                arr[i] = num(ia.value, fr);
            }
            case Ast.If i -> {
                if (num(i.cond, fr) != 0) block(i.then, fr);
                else if (i.otherwise != null) stmt(i.otherwise, fr);
            }
            case Ast.While w -> {
                while (num(w.cond, fr) != 0) {
                    try { block(w.body, fr); }
                    catch (BreakSignal x) { break; }
                    catch (ContinueSignal x) { /* next iteration */ }
                }
            }
            case Ast.For f -> {
                fr[f.var.slot] = num(f.from, fr);
                fr[f.end.slot] = num(f.to, fr);
                while ((Long) fr[f.var.slot] < (Long) fr[f.end.slot]) {
                    try { block(f.body, fr); }
                    catch (BreakSignal x) { break; }
                    catch (ContinueSignal x) { /* fall through to step */ }
                    fr[f.var.slot] = (Long) fr[f.var.slot] + 1;
                }
            }
            case Ast.Return r -> {
                ReturnSignal sig = new ReturnSignal();
                sig.value = r.value == null ? null : eval(r.value, fr);
                throw sig;
            }
            case Ast.Print p -> {
                List<Object> items = p.items;
                for (int i = 0; i < items.size(); i++) {
                    if (i > 0) outBuf.append(' ');
                    Object it = items.get(i);
                    if (it instanceof String str) outBuf.append(str);
                    else {
                        Object v = eval((Ast.Expr) it, fr);
                        outBuf.append(v instanceof long[] a ? Arrays.toString(a) : String.valueOf(v));
                    }
                }
                outBuf.append('\n');
                if (outBuf.length() > 8192) flush();
            }
            case Ast.ExprStmt es -> eval(es.e, fr);
            case Ast.Break b -> throw BreakSignal.I;
            case Ast.Continue k -> throw ContinueSignal.I;
            default -> throw new IllegalStateException(s.getClass().toString());
        }
    }

    private long num(Ast.Expr e, Object[] fr) { return (Long) eval(e, fr); }

    private Object eval(Ast.Expr e, Object[] fr) {
        switch (e) {
            case Ast.Num n: return n.v;
            case Ast.Var v: return fr[v.local.slot];
            case Ast.Un u: {
                long x = num(u.e, fr);
                return u.op.equals("-") ? -x : (x == 0 ? 1L : 0L);
            }
            case Ast.Bin b: {
                if (b.op.equals("&&")) return num(b.l, fr) != 0 && num(b.r, fr) != 0 ? 1L : 0L;
                if (b.op.equals("||")) return num(b.l, fr) != 0 || num(b.r, fr) != 0 ? 1L : 0L;
                long l = num(b.l, fr), r = num(b.r, fr);
                return switch (b.op) {
                    case "+" -> l + r; case "-" -> l - r; case "*" -> l * r;
                    case "/" -> l / r; case "%" -> l % r;
                    case "==" -> l == r ? 1L : 0L; case "!=" -> l != r ? 1L : 0L;
                    case "<" -> l < r ? 1L : 0L; case "<=" -> l <= r ? 1L : 0L;
                    case ">" -> l > r ? 1L : 0L; case ">=" -> l >= r ? 1L : 0L;
                    default -> throw new IllegalStateException(b.op);
                };
            }
            case Ast.Index ix: return ((long[]) eval(ix.arr, fr))[(int) num(ix.idx, fr)];
            case Ast.ArrLit a: {
                long[] arr = new long[a.elems.size()];
                for (int i = 0; i < arr.length; i++) arr[i] = num(a.elems.get(i), fr);
                return arr;
            }
            case Ast.Call c: {
                if (c.builtin != null) {
                    return switch (c.builtin) {
                        case "len" -> (long) ((long[]) eval(c.args.get(0), fr)).length;
                        case "array" -> new long[(int) num(c.args.get(0), fr)];
                        case "clock" -> System.currentTimeMillis();
                        case "putc" -> { outBuf.append((char) num(c.args.get(0), fr)); yield 0L; }
                        case "abs" -> Math.abs(num(c.args.get(0), fr));
                        default -> throw new IllegalStateException(c.builtin);
                    };
                }
                Object[] args = new Object[c.args.size()];
                for (int i = 0; i < args.length; i++) args[i] = eval(c.args.get(i), fr);
                return invoke(c.target, args);
            }
            default: throw new IllegalStateException(e.getClass().toString());
        }
    }
}
