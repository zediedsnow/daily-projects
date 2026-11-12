import java.util.ArrayDeque;
import java.util.Deque;

/** Walks the checked AST and emits JVM bytecode, one static method per Jolt function. */
final class Codegen {
    // A handful of the ~200 JVM opcodes is all a small language needs.
    static final int ACONST_NULL = 0x01, ICONST_0 = 0x03, LCONST_0 = 0x09, LCONST_1 = 0x0a, BIPUSH = 0x10,
        SIPUSH = 0x11, LDC = 0x12, LDC_W = 0x13, LDC2_W = 0x14, LLOAD = 0x16, ALOAD = 0x19, LALOAD = 0x2f,
        LSTORE = 0x37, ASTORE = 0x3a, LASTORE = 0x50, POP = 0x57, POP2 = 0x58, DUP = 0x59, LADD = 0x61,
        LSUB = 0x65, LMUL = 0x69, LDIV = 0x6d, LREM = 0x71, LNEG = 0x75, I2L = 0x85, L2I = 0x88, I2C = 0x92, LCMP = 0x94,
        IFEQ = 0x99, IFNE = 0x9a, IFLT = 0x9b, IFGE = 0x9c, IFGT = 0x9d, IFLE = 0x9e, GOTO = 0xa7,
        LRETURN = 0xad, ARETURN = 0xb0, RETURN = 0xb1, GETSTATIC = 0xb2, INVOKEVIRTUAL = 0xb6,
        INVOKESTATIC = 0xb8, NEWARRAY = 0xbc, ARRAYLENGTH = 0xbe, T_LONG = 11;

    private static final String PS = "java/io/PrintStream";

    private final ClassWriter cw;
    private ClassWriter.Code c;
    private Fn fn;
    private final Deque<ClassWriter.Code.Label[]> loops = new ArrayDeque<>();   // {continue, break}

    private Codegen(String className) { cw = new ClassWriter(className); }

    static byte[] compile(Program prog, String className) {
        Codegen g = new Codegen(className);
        for (Fn f : prog.fns) g.function(f);
        return g.cw.toBytes();
    }

    private void function(Fn f) {
        fn = f;
        c = new ClassWriter.Code();
        block(f.body);
        // Fall-off-the-end return. Harmless (and never verified) if unreachable.
        if (f.isMain) c.op(RETURN, 0);
        else if (f.ret == Ty.INT) { c.op(LCONST_0, 2); c.op(LRETURN, -2); }
        else { c.op(ACONST_NULL, 1); c.op(ARETURN, -1); }
        cw.addMethod(f.name, f.descriptor(), c, Math.max(f.maxSlots, 1));
    }

    // ---------------- statements ----------------
    private void block(Ast.Block b) { for (Ast.Stmt s : b.stmts) stmt(s); }

    private void stmt(Ast.Stmt s) {
        switch (s) {
            case Ast.Block b -> block(b);
            case Ast.Let let -> { expr(let.init); store(let.local); }
            case Ast.Assign a -> { expr(a.value); store(a.target.local); }
            case Ast.IndexAssign ia -> {
                expr(ia.arr); expr(ia.idx); c.op(L2I, -1); expr(ia.value); c.op(LASTORE, -4);
            }
            case Ast.If i -> {
                var elseL = c.label(); var end = c.label();
                jumpIf(i.cond, elseL, false);
                block(i.then);
                if (i.otherwise != null) {
                    c.jump(GOTO, end, 0);
                    c.bind(elseL);
                    stmt(i.otherwise);
                } else c.bind(elseL);
                c.bind(end);
            }
            case Ast.While w -> {
                // Rotated loop: test at the bottom, one branch per iteration.
                var body = c.label(); var test = c.label(); var end = c.label();
                c.jump(GOTO, test, 0);
                c.bind(body);
                loops.push(new ClassWriter.Code.Label[] {test, end});
                block(w.body);
                loops.pop();
                c.bind(test);
                jumpIf(w.cond, body, true);
                c.bind(end);
            }
            case Ast.For f -> {
                var body = c.label(); var step = c.label(); var test = c.label(); var end = c.label();
                expr(f.from); store(f.var);
                expr(f.to); store(f.end);
                c.jump(GOTO, test, 0);
                c.bind(body);
                loops.push(new ClassWriter.Code.Label[] {step, end});
                block(f.body);
                loops.pop();
                c.bind(step);
                load(f.var); c.op(LCONST_1, 2); c.op(LADD, -2); store(f.var);
                c.bind(test);
                load(f.var); load(f.end); c.op(LCMP, -3); c.jump(IFLT, body, -1);
                c.bind(end);
            }
            case Ast.Return r -> {
                if (fn.isMain) c.op(RETURN, 0);
                else if (r.value != null) { expr(r.value); c.op(fn.ret == Ty.INT ? LRETURN : ARETURN, -fn.ret.slots()); }
                else if (fn.ret == Ty.INT) { c.op(LCONST_0, 2); c.op(LRETURN, -2); }
                else { c.op(ACONST_NULL, 1); c.op(ARETURN, -1); }
            }
            case Ast.Print p -> print(p);
            case Ast.ExprStmt es -> { expr(es.e); c.op(es.e.ty == Ty.INT ? POP2 : POP, -es.e.ty.slots()); }
            case Ast.Break b -> c.jump(GOTO, loops.peek()[1], 0);
            case Ast.Continue k -> c.jump(GOTO, loops.peek()[0], 0);
            default -> throw new IllegalStateException(s.getClass().toString());
        }
        if (c.depth() != 0) throw new IllegalStateException("stack not empty after statement on line " + s.line);
    }

    private void print(Ast.Print p) {
        int out = cw.cp.field("java/lang/System", "out", "Ljava/io/PrintStream;");
        boolean first = true;
        for (Object item : p.items) {
            if (!first) { c.op2(GETSTATIC, out, 1); ldcString(" "); c.op2(INVOKEVIRTUAL, printStr(), -2); }
            first = false;
            c.op2(GETSTATIC, out, 1);
            if (item instanceof String s) {
                ldcString(s);
                c.op2(INVOKEVIRTUAL, printStr(), -2);
            } else {
                Ast.Expr e = (Ast.Expr) item;
                expr(e);
                if (e.ty == Ty.INT) c.op2(INVOKEVIRTUAL, cw.cp.method(PS, "print", "(J)V"), -3);
                else {
                    c.op2(INVOKESTATIC, cw.cp.method("java/util/Arrays", "toString", "([J)Ljava/lang/String;"), 0);
                    c.op2(INVOKEVIRTUAL, printStr(), -2);
                }
            }
        }
        c.op2(GETSTATIC, out, 1);
        c.op2(INVOKEVIRTUAL, cw.cp.method(PS, "println", "()V"), -1);
    }

    private int printStr() { return cw.cp.method(PS, "print", "(Ljava/lang/String;)V"); }

    private void ldcString(String s) {
        int idx = cw.cp.string(s);
        if (idx <= 255) c.op1(LDC, idx, 1); else c.op2(LDC_W, idx, 1);
    }

    private void load(Local l) { c.op1(l.ty == Ty.INT ? LLOAD : ALOAD, l.slot, l.ty.slots()); }
    private void store(Local l) { c.op1(l.ty == Ty.INT ? LSTORE : ASTORE, l.slot, -l.ty.slots()); }

    // ---------------- expressions ----------------
    private void expr(Ast.Expr e) {
        switch (e) {
            case Ast.Num n -> pushLong(n.v);
            case Ast.Var v -> load(v.local);
            case Ast.Un u when u.op.equals("-") -> { expr(u.e); c.op(LNEG, 0); }
            case Ast.Bin b when arith(b.op) != 0 -> { expr(b.l); expr(b.r); c.op(arith(b.op), -2); }
            case Ast.Un u -> boolValue(u);            // "!"
            case Ast.Bin b -> boolValue(b);           // comparisons, && and ||
            case Ast.Index ix -> { expr(ix.arr); expr(ix.idx); c.op(L2I, -1); c.op(LALOAD, 0); }
            case Ast.ArrLit a -> {
                pushInt(a.elems.size());
                c.op1(NEWARRAY, T_LONG, 0);
                for (int i = 0; i < a.elems.size(); i++) {
                    c.op(DUP, 1); pushInt(i); expr(a.elems.get(i)); c.op(LASTORE, -4);
                }
            }
            case Ast.Call call -> call(call);
            default -> throw new IllegalStateException(e.getClass().toString());
        }
    }

    private static int arith(String op) {
        return switch (op) { case "+" -> LADD; case "-" -> LSUB; case "*" -> LMUL; case "/" -> LDIV; case "%" -> LREM; default -> 0; };
    }

    private void call(Ast.Call call) {
        if (call.builtin != null) {
            switch (call.builtin) {
                case "len" -> { expr(call.args.get(0)); c.op(ARRAYLENGTH, 0); c.op(I2L, 1); }
                case "array" -> { expr(call.args.get(0)); c.op(L2I, -1); c.op1(NEWARRAY, T_LONG, 0); }
                case "clock" -> c.op2(INVOKESTATIC, cw.cp.method("java/lang/System", "currentTimeMillis", "()J"), 2);
                case "putc" -> {
                    c.op2(GETSTATIC, cw.cp.field("java/lang/System", "out", "Ljava/io/PrintStream;"), 1);
                    expr(call.args.get(0)); c.op(L2I, -1); c.op(I2C, 0);
                    c.op2(INVOKEVIRTUAL, cw.cp.method(PS, "print", "(C)V"), -2);
                    c.op(LCONST_0, 2);
                }
                case "abs" -> { expr(call.args.get(0)); c.op2(INVOKESTATIC, cw.cp.method("java/lang/Math", "abs", "(J)J"), 0); }
                default -> throw new IllegalStateException(call.builtin);
            }
            return;
        }
        int argSlots = 0;
        for (Ast.Expr a : call.args) { expr(a); argSlots += a.ty.slots(); }
        Fn f = call.target;
        c.op2(INVOKESTATIC, cw.cp.method(cw.name, f.name, f.descriptor()), f.ret.slots() - argSlots);
    }

    /** Materialise a boolean expression as the long 0 or 1. */
    private void boolValue(Ast.Expr e) {
        var t = c.label(); var end = c.label();
        jumpIf(e, t, true);
        c.op(LCONST_0, 2);
        c.jump(GOTO, end, 0);
        c.setDepth(c.depth() - 2);   // the other path arrives with the 0 not pushed
        c.bind(t);
        c.op(LCONST_1, 2);
        c.bind(end);
    }

    /**
     * Branch to {@code target} iff {@code e} is truthy == {@code sense}; otherwise fall through.
     * Conditions compile straight to conditional jumps (short-circuit included) instead of
     * building 0/1 values and testing them.
     */
    private void jumpIf(Ast.Expr e, ClassWriter.Code.Label target, boolean sense) {
        if (e instanceof Ast.Un u && u.op.equals("!")) { jumpIf(u.e, target, !sense); return; }
        if (e instanceof Ast.Bin b) {
            switch (b.op) {
                case "&&" -> {
                    if (sense) { var skip = c.label(); jumpIf(b.l, skip, false); jumpIf(b.r, target, true); c.bind(skip); }
                    else { jumpIf(b.l, target, false); jumpIf(b.r, target, false); }
                    return;
                }
                case "||" -> {
                    if (sense) { jumpIf(b.l, target, true); jumpIf(b.r, target, true); }
                    else { var skip = c.label(); jumpIf(b.l, skip, true); jumpIf(b.r, target, false); c.bind(skip); }
                    return;
                }
                default -> {
                    int cmp = cmpOp(b.op);
                    if (cmp != 0) {
                        expr(b.l); expr(b.r);
                        c.op(LCMP, -3);
                        c.jump(sense ? cmp : invert(cmp), target, -1);
                        return;
                    }
                }
            }
        }
        if (e instanceof Ast.Num n) {           // constant condition, e.g. `while 1 { ... }`
            if ((n.v != 0) == sense) c.jump(GOTO, target, 0);
            return;
        }
        expr(e);
        c.op(LCONST_0, 2);
        c.op(LCMP, -3);
        c.jump(sense ? IFNE : IFEQ, target, -1);
    }

    private static int cmpOp(String op) {
        return switch (op) {
            case "==" -> IFEQ; case "!=" -> IFNE; case "<" -> IFLT; case "<=" -> IFLE;
            case ">" -> IFGT; case ">=" -> IFGE; default -> 0;
        };
    }

    private static int invert(int op) {
        return switch (op) {
            case IFEQ -> IFNE; case IFNE -> IFEQ; case IFLT -> IFGE; case IFGE -> IFLT;
            case IFGT -> IFLE; case IFLE -> IFGT; default -> throw new IllegalStateException();
        };
    }

    private void pushLong(long v) {
        if (v == 0) c.op(LCONST_0, 2);
        else if (v == 1) c.op(LCONST_1, 2);
        else if (v == (byte) v) { c.op1(BIPUSH, (int) v & 0xFF, 1); c.op(I2L, 1); }
        else if (v == (short) v) { c.op2(SIPUSH, (int) v & 0xFFFF, 1); c.op(I2L, 1); }
        else c.op2(LDC2_W, cw.cp.lng(v), 2);
    }

    private void pushInt(int v) {
        if (v >= 0 && v <= 5) c.op(ICONST_0 + v, 1);
        else if (v == (byte) v) c.op1(BIPUSH, v & 0xFF, 1);
        else if (v == (short) v) c.op2(SIPUSH, v & 0xFFFF, 1);
        else throw new IllegalStateException("array literal too large");
    }
}
