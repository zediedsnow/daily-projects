import java.util.ArrayList;
import java.util.List;
import java.util.Set;

/** Hand-written lexer for Jolt source text. */
final class Lexer {
    enum K { NUM, IDENT, STR, KW, OP, EOF }

    record Tok(K kind, String text, long num, int line) {
        boolean is(String s) { return (kind == K.OP || kind == K.KW) && text.equals(s); }
        @Override public String toString() { return kind == K.EOF ? "end of file" : "'" + text + "'"; }
    }

    static final Set<String> KEYWORDS = Set.of(
        "fn", "let", "if", "else", "while", "for", "in", "return", "print", "break", "continue", "int");

    // Longest operators first so "<=" wins over "<".
    static final String[] OPS = {
        "..", "==", "!=", "<=", ">=", "&&", "||",
        "+", "-", "*", "/", "%", "<", ">", "!", "=", "(", ")", "{", "}", "[", "]", ",", ":", ";"
    };

    static List<Tok> lex(String src) {
        List<Tok> out = new ArrayList<>();
        int i = 0, line = 1, n = src.length();
        while (i < n) {
            char c = src.charAt(i);
            if (c == '\n') { line++; i++; continue; }
            if (Character.isWhitespace(c)) { i++; continue; }
            if (c == '/' && i + 1 < n && src.charAt(i + 1) == '/') {
                while (i < n && src.charAt(i) != '\n') i++;
                continue;
            }
            if (Character.isDigit(c)) {
                int s = i;
                while (i < n && (Character.isDigit(src.charAt(i)) || src.charAt(i) == '_')) i++;
                String t = src.substring(s, i);
                long v;
                try { v = Long.parseLong(t.replace("_", "")); }
                catch (NumberFormatException e) { throw new CompileError(line, "number too large: " + t); }
                out.add(new Tok(K.NUM, t, v, line));
                continue;
            }
            if (Character.isLetter(c) || c == '_') {
                int s = i;
                while (i < n && (Character.isLetterOrDigit(src.charAt(i)) || src.charAt(i) == '_')) i++;
                String t = src.substring(s, i);
                out.add(new Tok(KEYWORDS.contains(t) ? K.KW : K.IDENT, t, 0, line));
                continue;
            }
            if (c == '\'' && i + 2 < n && src.charAt(i + 2) == '\'') {   // char literal 'x' is just a number
                out.add(new Tok(K.NUM, src.substring(i, i + 3), src.charAt(i + 1), line));
                i += 3;
                continue;
            }
            if (c == '"') {
                StringBuilder sb = new StringBuilder();
                i++;
                while (true) {
                    if (i >= n || src.charAt(i) == '\n') throw new CompileError(line, "unterminated string");
                    char d = src.charAt(i++);
                    if (d == '"') break;
                    if (d == '\\' && i < n) {
                        char e = src.charAt(i++);
                        sb.append(switch (e) {
                            case 'n' -> '\n'; case 't' -> '\t'; case '"' -> '"'; case '\\' -> '\\';
                            default -> throw new CompileError(line, "bad escape \\" + e);
                        });
                    } else sb.append(d);
                }
                out.add(new Tok(K.STR, sb.toString(), 0, line));
                continue;
            }
            boolean matched = false;
            for (String op : OPS) {
                if (src.startsWith(op, i)) {
                    out.add(new Tok(K.OP, op, 0, line));
                    i += op.length();
                    matched = true;
                    break;
                }
            }
            if (!matched) throw new CompileError(line, "unexpected character '" + c + "'");
        }
        out.add(new Tok(K.EOF, "", 0, line));
        return out;
    }
}

final class CompileError extends RuntimeException {
    final int line;
    CompileError(int line, String msg) { super(msg); this.line = line; }
    @Override public String getMessage() { return "line " + line + ": " + super.getMessage(); }
}
