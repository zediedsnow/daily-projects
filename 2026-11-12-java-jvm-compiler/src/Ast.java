import java.util.ArrayList;
import java.util.List;

/** Jolt's two value types: 64-bit integers and arrays of them. */
enum Ty {
    INT("J", "int"), ARR("[J", "int[]");
    final String desc, name;
    Ty(String desc, String name) { this.desc = desc; this.name = name; }
    int slots() { return this == INT ? 2 : 1; }   // a JVM long occupies two local slots
}

/** A resolved local variable: the checker assigns its JVM slot. */
final class Local {
    final String name; Ty ty; int slot;
    Local(String name, Ty ty) { this.name = name; this.ty = ty; }
}

final class Fn {
    final String name; final int line;
    final List<Local> params = new ArrayList<>();
    Ty ret = Ty.INT;
    Ast.Block body;
    boolean isMain;
    int maxSlots;   // filled in by the checker
    Fn(String name, int line) { this.name = name; this.line = line; }

    String descriptor() {
        if (isMain) return "([Ljava/lang/String;)V";
        StringBuilder sb = new StringBuilder("(");
        for (Local p : params) sb.append(p.ty.desc);
        return sb.append(')').append(ret.desc).toString();
    }
}

final class Program {
    final List<Fn> fns = new ArrayList<>();
    Fn main;
}

final class Ast {
    private Ast() {}

    // ---------------- expressions ----------------
    abstract static class Expr { int line; Ty ty; }
    static final class Num extends Expr { final long v; Num(long v) { this.v = v; } }
    static final class Var extends Expr { final String name; Local local; Var(String n) { name = n; } }
    static final class Bin extends Expr {
        final String op; final Expr l, r;
        Bin(String op, Expr l, Expr r) { this.op = op; this.l = l; this.r = r; }
    }
    static final class Un extends Expr { final String op; final Expr e; Un(String op, Expr e) { this.op = op; this.e = e; } }
    static final class Call extends Expr {
        final String name; final List<Expr> args; Fn target; String builtin;
        Call(String name, List<Expr> args) { this.name = name; this.args = args; }
    }
    static final class Index extends Expr { final Expr arr, idx; Index(Expr a, Expr i) { arr = a; idx = i; } }
    static final class ArrLit extends Expr { final List<Expr> elems; ArrLit(List<Expr> e) { elems = e; } }

    // ---------------- statements ----------------
    abstract static class Stmt { int line; }
    static final class Block extends Stmt { final List<Stmt> stmts = new ArrayList<>(); }
    static final class Let extends Stmt { final Local local; final Expr init; Let(Local l, Expr i) { local = l; init = i; } }
    static final class Assign extends Stmt { final Var target; final Expr value; Assign(Var t, Expr v) { target = t; value = v; } }
    static final class IndexAssign extends Stmt {
        final Expr arr, idx, value;
        IndexAssign(Expr a, Expr i, Expr v) { arr = a; idx = i; value = v; }
    }
    static final class If extends Stmt {
        final Expr cond; final Block then; final Stmt otherwise;   // otherwise: Block, If, or null
        If(Expr c, Block t, Stmt o) { cond = c; then = t; otherwise = o; }
    }
    static final class While extends Stmt { final Expr cond; final Block body; While(Expr c, Block b) { cond = c; body = b; } }
    static final class For extends Stmt {
        final Local var; final Local end; final Expr from, to; final Block body;
        For(Local v, Local e, Expr f, Expr t, Block b) { var = v; end = e; from = f; to = t; body = b; }
    }
    static final class Return extends Stmt { final Expr value; Return(Expr v) { value = v; } }
    static final class Print extends Stmt { final List<Object> items; Print(List<Object> i) { items = i; } }  // String | Expr
    static final class ExprStmt extends Stmt { final Expr e; ExprStmt(Expr e) { this.e = e; } }
    static final class Break extends Stmt {}
    static final class Continue extends Stmt {}
}
