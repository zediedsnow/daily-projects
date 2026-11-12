import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Minimal, dependency-free writer for the JVM class-file format (JVMS chapter 4).
 * Everything here is raw bytes: no ASM, no javax.tools, no javac.
 */
final class ClassWriter {
    /** Class-file version 49 (Java 5): the JVM's type-inferring verifier checks our code,
     *  so we don't have to emit StackMapTable frames. Modern JVMs still load it happily. */
    static final int MAJOR = 49;

    final ConstPool cp = new ConstPool();
    private final List<byte[]> methods = new ArrayList<>();
    final String name;

    ClassWriter(String internalName) { this.name = internalName; }

    void addMethod(String mname, String desc, Code code, int maxLocals) {
        try {
            ByteArrayOutputStream bo = new ByteArrayOutputStream();
            DataOutputStream o = new DataOutputStream(bo);
            o.writeShort(0x0009);                  // ACC_PUBLIC | ACC_STATIC
            o.writeShort(cp.utf8(mname));
            o.writeShort(cp.utf8(desc));
            o.writeShort(1);                       // one attribute: Code
            byte[] bytecode = code.finish();
            o.writeShort(cp.utf8("Code"));
            o.writeInt(2 + 2 + 4 + bytecode.length + 2 + 2);
            o.writeShort(code.maxStack());
            o.writeShort(maxLocals);
            o.writeInt(bytecode.length);
            o.write(bytecode);
            o.writeShort(0);                       // exception table
            o.writeShort(0);                       // code attributes
            methods.add(bo.toByteArray());
        } catch (IOException e) { throw new UncheckedIOException(e); }
    }

    byte[] toBytes() {
        try {
            int thisIdx = cp.cls(name), superIdx = cp.cls("java/lang/Object");
            ByteArrayOutputStream bo = new ByteArrayOutputStream();
            DataOutputStream o = new DataOutputStream(bo);
            o.writeInt(0xCAFEBABE);
            o.writeShort(0);
            o.writeShort(MAJOR);
            o.writeShort(cp.count);
            o.write(cp.bytes());
            o.writeShort(0x0021);                  // ACC_PUBLIC | ACC_SUPER
            o.writeShort(thisIdx);
            o.writeShort(superIdx);
            o.writeShort(0);                       // interfaces
            o.writeShort(0);                       // fields
            o.writeShort(methods.size());
            for (byte[] m : methods) o.write(m);
            o.writeShort(0);                       // class attributes
            return bo.toByteArray();
        } catch (IOException e) { throw new UncheckedIOException(e); }
    }

    /** The constant pool, with de-duplication of every entry kind. */
    static final class ConstPool {
        private final ByteArrayOutputStream bo = new ByteArrayOutputStream();
        private final DataOutputStream o = new DataOutputStream(bo);
        private final Map<String, Integer> cache = new HashMap<>();
        int count = 1;   // index 0 is unused by definition

        byte[] bytes() { return bo.toByteArray(); }

        private interface Body { void write() throws IOException; }

        private int entry(String key, int tag, int width, Body body) {
            Integer hit = cache.get(key);
            if (hit != null) return hit;
            try { o.writeByte(tag); body.write(); } catch (IOException e) { throw new UncheckedIOException(e); }
            int idx = count;
            count += width;   // long/double entries take two indices (a famous JVM wart)
            if (count > 0xFFFF) throw new IllegalStateException("constant pool overflow");
            cache.put(key, idx);
            return idx;
        }

        int utf8(String s) { return entry("U" + s, 1, 1, () -> o.writeUTF(s)); }  // writeUTF = JVM "modified UTF-8"
        int cls(String n) { int u = utf8(n); return entry("C" + n, 7, 1, () -> o.writeShort(u)); }
        int string(String s) { int u = utf8(s); return entry("S" + s, 8, 1, () -> o.writeShort(u)); }
        int lng(long v) { return entry("J" + v, 5, 2, () -> o.writeLong(v)); }
        int nat(String n, String d) {
            int a = utf8(n), b = utf8(d);
            return entry("N" + n + ":" + d, 12, 1, () -> { o.writeShort(a); o.writeShort(b); });
        }
        int field(String owner, String n, String d) {
            int c = cls(owner), nt = nat(n, d);
            return entry("F" + owner + "." + n + ":" + d, 9, 1, () -> { o.writeShort(c); o.writeShort(nt); });
        }
        int method(String owner, String n, String d) {
            int c = cls(owner), nt = nat(n, d);
            return entry("M" + owner + "." + n + ":" + d, 10, 1, () -> { o.writeShort(c); o.writeShort(nt); });
        }
    }

    /** A growable bytecode buffer with forward-referencing labels and operand-stack depth tracking. */
    static final class Code {
        private byte[] b = new byte[64];
        private int len, depth, maxDepth;
        private final List<int[]> fixups = new ArrayList<>();   // {opcodePos, operandPos, labelId}
        private final List<Label> labels = new ArrayList<>();

        static final class Label { int pos = -1; final int id; Label(int id) { this.id = id; } }

        Label label() { Label l = new Label(labels.size()); labels.add(l); return l; }
        void bind(Label l) { l.pos = len; }

        int size() { return len; }
        int maxStack() { return maxDepth; }
        int depth() { return depth; }
        void setDepth(int d) { depth = d; }

        private void u1(int v) { if (len == b.length) b = Arrays.copyOf(b, len * 2); b[len++] = (byte) v; }
        void u2(int v) { u1(v >> 8); u1(v); }

        /** Emit an opcode and account for its net effect on the operand stack (in slots). */
        void op(int opcode, int stackDelta) {
            u1(opcode);
            depth += stackDelta;
            if (depth < 0) throw new IllegalStateException("stack underflow at " + len);
            maxDepth = Math.max(maxDepth, depth);
        }
        void op1(int opcode, int operand, int delta) { op(opcode, delta); u1(operand); }
        void op2(int opcode, int operand, int delta) { op(opcode, delta); u2(operand); }

        void jump(int opcode, Label l, int delta) {
            int at = len;
            op(opcode, delta);
            fixups.add(new int[] {at, len, l.id});
            u2(0);
        }

        byte[] finish() {
            for (int[] f : fixups) {
                Label l = labels.get(f[2]);
                if (l.pos < 0) throw new IllegalStateException("unbound label");
                int off = l.pos - f[0];
                if (off != (short) off) throw new IllegalStateException("branch too far (method is too large)");
                b[f[1]] = (byte) (off >> 8);
                b[f[1] + 1] = (byte) off;
            }
            return Arrays.copyOf(b, len);
        }
    }
}
