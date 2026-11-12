import java.util.ArrayList;
import java.util.List;


/** Recursive-descent parser: tokens -> AST. Top-level statements become the body of main(). */
final class Parser {
    private final List<Lexer.Tok> toks;
    private int p;

    Parser(List<Lexer.Tok> toks) { this.toks = toks; }

    static Program parse(String src) { return new Parser(Lexer.lex(src)).program(); }

    // ---------------- helpers ----------------
    private Lexer.Tok peek() { return toks.get(p); }
    private Lexer.Tok next() { return toks.get(p++); }
    private boolean at(String s) { return peek().is(s); }
    private boolean accept(String s) { if (at(s)) { p++; return true; } return false; }
    private Lexer.Tok expect(String s) {
        if (!at(s)) throw new CompileError(peek().line(), "expected '" + s + "' but found " + peek());
        return next();
    }
    private String ident() {
        Lexer.Tok t = next();
        if (t.kind() != Lexer.K.IDENT) throw new CompileError(t.line(), "expected a name but found " + t);
        return t.text();
    }
    private <T extends Ast.Expr> T at(T e, int line) { e.line = line; return e; }
    private <T extends Ast.Stmt> T st(T s, int line) { s.line = line; return s; }

    // ---------------- program ----------------
    Program program() {
        Program prog = new Program();
        Fn main = new Fn("main", 1);
        main.isMain = true;
        main.body = new Ast.Block();
        while (peek().kind() != Lexer.K.EOF) {
            if (at("fn")) prog.fns.add(function());
            else main.body.stmts.add(statement());
        }
        prog.main = main;
        prog.fns.add(main);
        return prog;
    }

    private Ty type() {
        expect("int");
        if (accept("[")) { expect("]"); return Ty.ARR; }
        return Ty.INT;
    }

    private Fn function() {
        int line = expect("fn").line();
        Fn f = new Fn(ident(), line);
        if (f.name.equals("main")) throw new CompileError(line, "'main' is reserved for top-level code");
        expect("(");
        if (!at(")")) {
            do {
                String name = ident();
                expect(":");
                f.params.add(new Local(name, type()));
            } while (accept(","));
        }
        expect(")");
        if (accept(":")) f.ret = type();
        f.body = block();
        return f;
    }

    private Ast.Block block() {
        int line = expect("{").line();
        Ast.Block b = st(new Ast.Block(), line);
        while (!at("}")) {
            if (peek().kind() == Lexer.K.EOF) throw new CompileError(line, "unclosed '{'");
            b.stmts.add(statement());
        }
        expect("}");
        return b;
    }

    // ---------------- statements ----------------
    private Ast.Stmt statement() {
        Lexer.Tok t = peek();
        int line = t.line();
        if (at("{")) return block();
        if (accept("let")) {
            String name = ident();
            Ty declared = accept(":") ? type() : null;
            expect("=");
            Ast.Expr init = expr();
            expect(";");
            return st(new Ast.Let(new Local(name, declared), init), line);
        }
        if (accept("if")) return ifRest(line);
        if (accept("while")) {
            Ast.Expr c = expr();
            return st(new Ast.While(c, block()), line);
        }
        if (accept("for")) {
            String name = ident();
            expect("in");
            Ast.Expr from = expr();
            expect("..");
            Ast.Expr to = expr();
            return st(new Ast.For(new Local(name, Ty.INT), new Local(" end", Ty.INT), from, to, block()), line);
        }
        if (accept("return")) {
            Ast.Expr v = at(";") ? null : expr();
            expect(";");
            return st(new Ast.Return(v), line);
        }
        if (accept("break")) { expect(";"); return st(new Ast.Break(), line); }
        if (accept("continue")) { expect(";"); return st(new Ast.Continue(), line); }
        if (accept("print")) {
            expect("(");
            List<Object> items = new ArrayList<>();
            if (!at(")")) {
                do {
                    if (peek().kind() == Lexer.K.STR) items.add(next().text());
                    else items.add(expr());
                } while (accept(","));
            }
            expect(")");
            expect(";");
            return st(new Ast.Print(items), line);
        }
        Ast.Expr e = expr();
        if (accept("=")) {
            Ast.Expr v = expr();
            expect(";");
            if (e instanceof Ast.Var var) return st(new Ast.Assign(var, v), line);
            if (e instanceof Ast.Index ix) return st(new Ast.IndexAssign(ix.arr, ix.idx, v), line);
            throw new CompileError(line, "left side of '=' must be a variable or a[i]");
        }
        expect(";");
        return st(new Ast.ExprStmt(e), line);
    }

    private Ast.Stmt ifRest(int line) {
        Ast.Expr c = expr();
        Ast.Block then = block();
        Ast.Stmt otherwise = null;
        if (accept("else")) {
            int l2 = peek().line();
            otherwise = accept("if") ? ifRest(l2) : block();
        }
        return st(new Ast.If(c, then, otherwise), line);
    }

    // ---------------- expressions (precedence climbing) ----------------
    private static final String[][] LEVELS = {
        {"||"}, {"&&"}, {"==", "!="}, {"<", "<=", ">", ">="}, {"+", "-"}, {"*", "/", "%"}
    };

    private Ast.Expr expr() { return binary(0); }

    private Ast.Expr binary(int level) {
        if (level == LEVELS.length) return unary();
        Ast.Expr l = binary(level + 1);
        outer:
        while (true) {
            for (String op : LEVELS[level]) {
                if (at(op)) {
                    int line = next().line();
                    l = at(new Ast.Bin(op, l, binary(level + 1)), line);
                    continue outer;
                }
            }
            return l;
        }
    }

    private Ast.Expr unary() {
        int line = peek().line();
        if (accept("-")) {
            Ast.Expr e = unary();
            if (e instanceof Ast.Num n) return at(new Ast.Num(-n.v), line);   // fold literal negation
            return at(new Ast.Un("-", e), line);
        }
        if (accept("!")) return at(new Ast.Un("!", unary()), line);
        return postfix();
    }

    private Ast.Expr postfix() {
        Ast.Expr e = primary();
        while (at("[")) {
            int line = next().line();
            Ast.Expr idx = expr();
            expect("]");
            e = at(new Ast.Index(e, idx), line);
        }
        return e;
    }

    private Ast.Expr primary() {
        Lexer.Tok t = next();
        int line = t.line();
        switch (t.kind()) {
            case NUM: return at(new Ast.Num(t.num()), line);
            case IDENT:
                if (accept("(")) {
                    List<Ast.Expr> args = new ArrayList<>();
                    if (!at(")")) do args.add(expr()); while (accept(","));
                    expect(")");
                    return at(new Ast.Call(t.text(), args), line);
                }
                return at(new Ast.Var(t.text()), line);
            default:
        }
        if (t.is("(")) { Ast.Expr e = expr(); expect(")"); return e; }
        if (t.is("[")) {
            List<Ast.Expr> elems = new ArrayList<>();
            if (!at("]")) do elems.add(expr()); while (accept(","));
            expect("]");
            return at(new Ast.ArrLit(elems), line);
        }
        throw new CompileError(line, "unexpected " + t);
    }
}
