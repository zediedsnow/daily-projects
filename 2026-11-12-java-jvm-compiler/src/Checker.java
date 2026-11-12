import java.util.ArrayDeque;
import java.util.Deque;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Semantic pass: resolves every name to a function or a JVM local slot, infers and checks
 * types, and validates break/continue/return. After this the AST is ready for both the
 * bytecode generator and the reference interpreter.
 */
final class Checker {
    private final Map<String, Fn> fns = new HashMap<>();
    private final Deque<Map<String, Local>> scopes = new ArrayDeque<>();
    private Fn fn;
    private int nextSlot, loopDepth;

    static void check(Program prog) { new Checker().run(prog); }

    private void run(Program prog) {
        for (Fn f : prog.fns) {
            if (fns.put(f.name, f) != null) throw new CompileError(f.line, "function '" + f.name + "' defined twice");
            if (BUILTINS.containsKey(f.name)) throw new CompileError(f.line, "'" + f.name + "' is a built-in");
        }
        for (Fn f : prog.fns) function(f);
    }

    private void function(Fn f) {
        fn = f;
        nextSlot = f.isMain ? 1 : 0;   // main's slot 0 holds String[] args
        loopDepth = 0;
        scopes.clear();
        scopes.push(new HashMap<>());
        for (Local p : f.params) declare(p, f.line);
        block(f.body, false);
        f.maxSlots = nextSlot;
        if (nextSlot > 255) throw new CompileError(f.line, "too many locals in '" + f.name + "'");
    }

    private void declare(Local l, int line) {
        if (scopes.peek().containsKey(l.name)) throw new CompileError(line, "'" + l.name + "' already declared in this scope");
        l.slot = nextSlot;
        nextSlot += l.ty.slots();
        scopes.peek().put(l.name, l);
    }

    private Local lookup(String name, int line) {
        for (Map<String, Local> s : scopes) { Local l = s.get(name); if (l != null) return l; }
        throw new CompileError(line, "unknown variable '" + name + "'");
    }

    // ---------------- statements ----------------
    private void block(Ast.Block b, boolean newScope) {
        if (newScope) scopes.push(new HashMap<>());
        for (Ast.Stmt s : b.stmts) stmt(s);
        if (newScope) scopes.pop();
    }

    private void stmt(Ast.Stmt s) {
        if (s instanceof Ast.Block b) block(b, true);
        else if (s instanceof Ast.Let let) {
            Ty t = expr(let.init);
            if (let.local.ty != null && let.local.ty != t) mismatch(s.line, let.local.ty, t);
            let.local.ty = t;
            declare(let.local, s.line);   // declared after init: `let x = x + 1;` sees the outer x
        } else if (s instanceof Ast.Assign a) {
            Ty want = expr(a.target);
            want(a.value, want);
        } else if (s instanceof Ast.IndexAssign ia) {
            want(ia.arr, Ty.ARR); want(ia.idx, Ty.INT); want(ia.value, Ty.INT);
        } else if (s instanceof Ast.If i) {
            want(i.cond, Ty.INT);
            block(i.then, true);
            if (i.otherwise != null) stmt(i.otherwise);
        } else if (s instanceof Ast.While w) {
            want(w.cond, Ty.INT);
            loopDepth++; block(w.body, true); loopDepth--;
        } else if (s instanceof Ast.For f) {
            want(f.from, Ty.INT); want(f.to, Ty.INT);
            scopes.push(new HashMap<>());
            declare(f.end, s.line);
            declare(f.var, s.line);
            loopDepth++; block(f.body, true); loopDepth--;
            scopes.pop();
        } else if (s instanceof Ast.Return r) {
            if (fn.isMain) {
                if (r.value != null) throw new CompileError(s.line, "top-level 'return' takes no value");
            } else if (r.value != null) want(r.value, fn.ret);
        } else if (s instanceof Ast.Print p) {
            for (Object o : p.items) if (o instanceof Ast.Expr e) expr(e);
        } else if (s instanceof Ast.ExprStmt es) {
            expr(es.e);
        } else if (s instanceof Ast.Break || s instanceof Ast.Continue) {
            if (loopDepth == 0) throw new CompileError(s.line, "break/continue outside a loop");
        } else throw new IllegalStateException(s.getClass().toString());
    }

    // ---------------- expressions ----------------
    /** name -> {arity, returns array?} */
    static final Map<String, Ty[]> BUILTINS = Map.of(
        "len",   new Ty[] {Ty.INT, Ty.ARR},   // ret, params...
        "array", new Ty[] {Ty.ARR, Ty.INT},
        "clock", new Ty[] {Ty.INT},
        "abs",   new Ty[] {Ty.INT, Ty.INT},
        "putc",  new Ty[] {Ty.INT, Ty.INT});   // print one character, no newline

    private void want(Ast.Expr e, Ty t) {
        Ty got = expr(e);
        if (got != t) mismatch(e.line, t, got);
    }

    private static void mismatch(int line, Ty want, Ty got) {
        throw new CompileError(line, "type mismatch: expected " + want.name + " but got " + got.name);
    }

    private Ty expr(Ast.Expr e) {
        return e.ty = switch (e) {
            case Ast.Num n -> Ty.INT;
            case Ast.Var v -> (v.local = lookup(v.name, v.line)).ty;
            case Ast.Un u -> { want(u.e, Ty.INT); yield Ty.INT; }
            case Ast.Bin b -> {
                if (b.op.equals("==") || b.op.equals("!=")) {
                    Ty l = expr(b.l);
                    if (l != Ty.INT) throw new CompileError(b.line, "only ints can be compared");
                    want(b.r, Ty.INT);
                } else { want(b.l, Ty.INT); want(b.r, Ty.INT); }
                yield Ty.INT;
            }
            case Ast.Index ix -> { want(ix.arr, Ty.ARR); want(ix.idx, Ty.INT); yield Ty.INT; }
            case Ast.ArrLit a -> { for (Ast.Expr x : a.elems) want(x, Ty.INT); yield Ty.ARR; }
            case Ast.Call c -> call(c);
            default -> throw new IllegalStateException(e.getClass().toString());
        };
    }

    private Ty call(Ast.Call c) {
        Ty[] sig = BUILTINS.get(c.name);
        if (sig != null) {
            c.builtin = c.name;
            arity(c, sig.length - 1);
            for (int i = 1; i < sig.length; i++) want(c.args.get(i - 1), sig[i]);
            return sig[0];
        }
        Fn f = fns.get(c.name);
        if (f == null || f.isMain) throw new CompileError(c.line, "unknown function '" + c.name + "'");
        c.target = f;
        arity(c, f.params.size());
        for (int i = 0; i < f.params.size(); i++) want(c.args.get(i), f.params.get(i).ty);
        return f.ret;
    }

    private static void arity(Ast.Call c, int n) {
        List<Ast.Expr> a = c.args;
        if (a.size() != n) throw new CompileError(c.line, "'" + c.name + "' takes " + n + " argument(s), got " + a.size());
    }
}
