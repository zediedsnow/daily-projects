package ochre

import java.io.ByteArrayOutputStream

class EncodeOptions(
    val quality: Int = 75,
    /** luma sampling factors; chroma is always 1x1. (2,2)=4:2:0, (2,1)=4:2:2, (1,1)=4:4:4 */
    val hSamp: Int = 2,
    val vSamp: Int = 2,
    val optimize: Boolean = false,
    val progressive: Boolean = false,
    /** restart interval in MCUs, 0 = none */
    val restartInterval: Int = 0,
)

/** Where entropy-coded output goes: real bits, or just symbol statistics for table optimization. */
private interface Sink {
    fun symbol(tbl: Int, ac: Boolean, sym: Int)
    fun bits(v: Int, n: Int)
    fun restartMarker(n: Int)
    fun flush()
}

private class CountingSink : Sink {
    val dc = Array(4) { LongArray(257) }
    val ac = Array(4) { LongArray(257) }
    override fun symbol(tbl: Int, ac: Boolean, sym: Int) { (if (ac) this.ac else dc)[tbl][sym]++ }
    override fun bits(v: Int, n: Int) {}
    override fun restartMarker(n: Int) {}
    override fun flush() {}
}

private class BitSink(val out: ByteArrayOutputStream, dcT: Array<HuffSpec?>, acT: Array<HuffSpec?>) : Sink {
    private val dcCodes = dcT.map { it?.codes() }
    private val acCodes = acT.map { it?.codes() }
    private var acc = 0L
    private var cnt = 0
    override fun symbol(tbl: Int, ac: Boolean, sym: Int) {
        val (code, size) = (if (ac) acCodes[tbl] else dcCodes[tbl]) ?: error("no table")
        check(size[sym] != 0) { "symbol $sym has no code in table $tbl" }
        bits(code[sym], size[sym])
    }
    override fun bits(v: Int, n: Int) {
        if (n == 0) return
        acc = (acc shl n) or (v.toLong() and ((1L shl n) - 1)); cnt += n
        while (cnt >= 8) {
            val b = ((acc shr (cnt - 8)) and 0xff).toInt()
            out.write(b); if (b == 0xff) out.write(0)
            cnt -= 8
        }
    }
    override fun flush() { if (cnt > 0) bits(0x7f, 8 - cnt); acc = 0; cnt = 0 }
    override fun restartMarker(n: Int) { flush(); out.write(0xff); out.write(0xd0 + n) }
}

private class EncComp(val id: Int, val h: Int, val v: Int, val tq: Int, val tbl: Int) {
    var bw = 0; var bh = 0; var bwAlloc = 0; var bhAlloc = 0
    lateinit var coef: IntArray
}

private data class Scan(val comps: List<Int>, val ss: Int, val se: Int, val ah: Int, val al: Int)

class Encoder(private val img: Raster, private val opt: EncodeOptions = EncodeOptions()) {
    private val comps: List<EncComp>
    private val hmax: Int
    private val vmax: Int
    private val mcusX: Int
    private val mcusY: Int
    private val quant: Array<IntArray>

    init {
        require(img.channels == 1 || img.channels == 3) { "need a gray or RGB image" }
        require(img.width in 1..65535 && img.height in 1..65535)
        comps = if (img.channels == 1) listOf(EncComp(1, 1, 1, 0, 0))
        else listOf(EncComp(1, opt.hSamp, opt.vSamp, 0, 0), EncComp(2, 1, 1, 1, 1), EncComp(3, 1, 1, 1, 1))
        hmax = comps.maxOf { it.h }; vmax = comps.maxOf { it.v }
        mcusX = ceilDiv(img.width, 8 * hmax); mcusY = ceilDiv(img.height, 8 * vmax)
        quant = arrayOf(scaledQuant(STD_LUMA_QUANT, opt.quality), scaledQuant(STD_CHROMA_QUANT, opt.quality))
    }

    fun encode(): ByteArray {
        computeCoefficients()
        val out = ByteArrayOutputStream(img.width * img.height / 2 + 1024)
        writeHeaders(out)
        val progressive = opt.progressive
        val optimize = opt.optimize || progressive // libjpeg forces optimal tables in progressive mode
        val scans = if (progressive) progressionScript() else listOf(Scan(comps.indices.toList(), 0, 63, 0, 0))
        val dcT = arrayOfNulls<HuffSpec>(4); val acT = arrayOfNulls<HuffSpec>(4)
        var frameWritten = false
        val sentDc = BooleanArray(4); val sentAc = BooleanArray(4)
        for (scan in scans) {
            val isDc = scan.ss == 0
            if (optimize) {
                val counter = CountingSink()
                encodeScan(scan, counter)
                val done = BooleanArray(4)
                for (ci in scan.comps) {
                    val t = comps[ci].tbl
                    if (progressive) {
                        if (isDc && scan.ah != 0) continue
                        if (!done[t]) { if (isDc) dcT[t] = optimalHuffman(counter.dc[t]) else acT[t] = optimalHuffman(counter.ac[t]); done[t] = true }
                        if (isDc) sentDc[t] = false else sentAc[t] = false
                    } else if (!done[t]) {
                        dcT[t] = optimalHuffman(counter.dc[t]); acT[t] = optimalHuffman(counter.ac[t]); done[t] = true
                        sentDc[t] = false; sentAc[t] = false
                    }
                }
            } else {
                dcT[0] = STD_DC_LUMA; acT[0] = STD_AC_LUMA; dcT[1] = STD_DC_CHROMA; acT[1] = STD_AC_CHROMA
            }
            if (!frameWritten) { writeFrame(out); frameWritten = true }
            // DHT for this scan
            for (ci in scan.comps) {
                val t = comps[ci].tbl
                if (progressive) {
                    if (isDc) { if (scan.ah == 0 && !sentDc[t]) { writeDht(out, dcT[t]!!, t, false); sentDc[t] = true } }
                    else if (!sentAc[t]) { writeDht(out, acT[t]!!, t, true); sentAc[t] = true }
                } else {
                    if (!sentDc[t]) { writeDht(out, dcT[t]!!, t, false); sentDc[t] = true }
                    if (!sentAc[t]) { writeDht(out, acT[t]!!, t, true); sentAc[t] = true }
                }
            }
            if (opt.restartInterval != lastDri) {
                out.write(0xff); out.write(0xdd); u16(out, 4); u16(out, opt.restartInterval); lastDri = opt.restartInterval
            }
            out.write(0xff); out.write(0xda)
            u16(out, 6 + 2 * scan.comps.size)
            out.write(scan.comps.size)
            for (ci in scan.comps) {
                val c = comps[ci]
                val td = if (progressive && (!isDc || scan.ah != 0)) 0 else c.tbl
                val ta = if (progressive && isDc) 0 else c.tbl
                out.write(c.id); out.write((td shl 4) or ta)
            }
            out.write(scan.ss); out.write(scan.se); out.write((scan.ah shl 4) or scan.al)
            val sink = BitSink(out, dcT, acT)
            encodeScan(scan, sink)
            sink.flush()
        }
        out.write(0xff); out.write(0xd9)
        return out.toByteArray()
    }

    private var lastDri = 0

    // ------------------------------------------------------------------ sample prep + DCT

    private fun computeCoefficients() {
        val W = img.width; val H = img.height
        val full: List<ByteArray> = if (img.channels == 1) listOf(img.data) else {
            val y = ByteArray(W * H); val cb = ByteArray(W * H); val cr = ByteArray(W * H)
            val d = img.data
            for (i in 0 until W * H) {
                val r = d[3 * i].toInt() and 0xff; val g = d[3 * i + 1].toInt() and 0xff; val b = d[3 * i + 2].toInt() and 0xff
                y[i] = ((Color.R_Y[r] + Color.G_Y[g] + Color.B_Y[b]) shr 16).toByte()
                cb[i] = ((Color.R_CB[r] + Color.G_CB[g] + Color.B_CB[b]) shr 16).toByte()
                cr[i] = ((Color.B_CB[r] + Color.G_CR[g] + Color.B_CR[b]) shr 16).toByte()
            }
            listOf(y, cb, cr)
        }
        val blk = IntArray(64)
        for ((ci, c) in comps.withIndex()) {
            c.bw = ceilDiv(W * c.h, hmax * 8); c.bh = ceilDiv(H * c.v, vmax * 8)
            c.bwAlloc = mcusX * c.h; c.bhAlloc = mcusY * c.v
            c.coef = IntArray(c.bwAlloc * c.bhAlloc * 64)
            val sx = hmax / c.h; val sy = vmax / c.v
            // 1. edge-replicate the full-resolution plane: width to the downsampler's input width,
            //    height to a whole row group (jcprepct/jcsample expand_right_edge/expand_bottom_edge)
            val pw = c.bw * 8 * sx; val ph = ceilDiv(H, vmax) * vmax
            val src = full[ci]
            // 2. downsample with libjpeg's ordered-dither rounding biases
            val dw = c.bw * 8; val dhReal = ph / sy; val dh = c.bh * 8
            val ds = ByteArray(dw * maxOf(dh, dhReal))
            fun px(x: Int, y: Int) = src[minOf(y, H - 1) * W + minOf(x, W - 1)].toInt() and 0xff
            for (y in 0 until dhReal) for (x in 0 until dw) {
                val v = when {
                    sx == 1 && sy == 1 -> px(x, y)
                    sx == 2 && sy == 1 -> (px(2 * x, y) + px(2 * x + 1, y) + (x and 1)) shr 1
                    sx == 2 && sy == 2 -> (px(2 * x, 2 * y) + px(2 * x + 1, 2 * y) + px(2 * x, 2 * y + 1) + px(2 * x + 1, 2 * y + 1) + 1 + (x and 1)) shr 2
                    else -> {
                        var s = 0
                        for (yy in 0 until sy) for (xx in 0 until sx) s += px(x * sx + xx, y * sy + yy)
                        val n = sx * sy
                        (s + n / 2) / n
                    }
                }
                ds[y * dw + x] = v.toByte()
            }
            // 3. pad the downsampled plane to whole blocks by repeating its last row
            for (y in dhReal until dh) System.arraycopy(ds, (dhReal - 1) * dw, ds, y * dw, dw)
            // 4. forward DCT + quantize every real block
            val q = quant[c.tq]
            for (by in 0 until c.bh) for (bx in 0 until c.bw) {
                for (r in 0 until 8) for (k in 0 until 8) blk[r * 8 + k] = (ds[(by * 8 + r) * dw + bx * 8 + k].toInt() and 0xff) - 128
                Dct.forward(blk)
                val off = (by * c.bwAlloc + bx) * 64
                for (i in 0 until 64) {
                    val qv = q[i] shl 3
                    var t = blk[i]
                    t = if (t < 0) -((-t + (qv shr 1)) / qv) else (t + (qv shr 1)) / qv
                    c.coef[off + i] = t
                }
            }
            // 5. dummy blocks that pad partial MCUs: zero AC, DC copied from the neighbour
            for (by in 0 until c.bh) for (bx in c.bw until c.bwAlloc)
                c.coef[(by * c.bwAlloc + bx) * 64] = c.coef[(by * c.bwAlloc + bx - 1) * 64]
            for (by in c.bh until c.bhAlloc) for (bx in 0 until c.bwAlloc) {
                val mcuLast = (bx / c.h) * c.h + c.h - 1
                c.coef[(by * c.bwAlloc + bx) * 64] = c.coef[((by - 1) * c.bwAlloc + mcuLast) * 64]
            }
        }
    }

    // ------------------------------------------------------------------ scans

    /** jpeg_simple_progression() from jcparam.c */
    private fun progressionScript(): List<Scan> {
        val n = comps.size
        val all = comps.indices.toList()
        return if (n == 3) listOf(
            Scan(all, 0, 0, 0, 1),
            Scan(listOf(0), 1, 5, 0, 2),
            Scan(listOf(2), 1, 63, 0, 1),
            Scan(listOf(1), 1, 63, 0, 1),
            Scan(listOf(0), 6, 63, 0, 2),
            Scan(listOf(0), 1, 63, 2, 1),
            Scan(all, 0, 0, 1, 0),
            Scan(listOf(2), 1, 63, 1, 0),
            Scan(listOf(1), 1, 63, 1, 0),
            Scan(listOf(0), 1, 63, 1, 0),
        ) else listOf(
            Scan(all, 0, 0, 0, 1),
            Scan(all, 1, 5, 0, 2),
            Scan(all, 6, 63, 0, 2),
            Scan(all, 1, 63, 2, 1),
            Scan(all, 0, 0, 1, 0),
            Scan(all, 1, 63, 1, 0),
        )
    }

    private class State {
        val lastDc = IntArray(4)
        var eobrun = 0
        var be = 0
        val corr = IntArray(1000)
    }

    private fun encodeScan(scan: Scan, sink: Sink) {
        val st = State()
        var rstNum = 0
        val ri = opt.restartInterval
        var togo = ri
        fun mcuStart() {
            if (ri == 0) return
            if (togo == 0) {
                if (opt.progressive) emitEobrun(st, sink, scan)
                sink.restartMarker(rstNum); rstNum = (rstNum + 1) and 7
                st.lastDc.fill(0); st.eobrun = 0; st.be = 0
                togo = ri
            }
            togo--
        }
        val block: (Int, EncComp, Int) -> Unit = when {
            !opt.progressive -> { ci, c, off -> sequentialBlock(st, sink, ci, c, off) }
            scan.ss == 0 && scan.ah == 0 -> { ci, c, off -> dcFirst(st, sink, ci, c, off, scan.al) }
            scan.ss == 0 -> { _, c, off -> sink.bits((c.coef[off] shr scan.al) and 1, 1) }
            scan.ah == 0 -> { _, c, off -> acFirst(st, sink, c, off, scan) }
            else -> { _, c, off -> acRefine(st, sink, c, off, scan) }
        }
        if (scan.comps.size == 1) {
            val ci = scan.comps[0]; val c = comps[ci]
            for (by in 0 until c.bh) for (bx in 0 until c.bw) { mcuStart(); block(ci, c, (by * c.bwAlloc + bx) * 64) }
        } else {
            for (my in 0 until mcusY) for (mx in 0 until mcusX) {
                mcuStart()
                for (ci in scan.comps) {
                    val c = comps[ci]
                    for (v in 0 until c.v) for (h in 0 until c.h) block(ci, c, ((my * c.v + v) * c.bwAlloc + mx * c.h + h) * 64)
                }
            }
        }
        if (opt.progressive) emitEobrun(st, sink, scan)
    }

    private fun nbitsOf(a: Int): Int { var t = a; var n = 0; while (t != 0) { n++; t = t shr 1 }; return n }

    private fun sequentialBlock(st: State, sink: Sink, ci: Int, c: EncComp, off: Int) {
        val b = c.coef
        var temp = b[off] - st.lastDc[ci]; st.lastDc[ci] = b[off]
        var temp2 = temp
        if (temp < 0) { temp = -temp; temp2-- }
        val nb = nbitsOf(temp)
        sink.symbol(c.tbl, false, nb); sink.bits(temp2, nb)
        var r = 0
        for (k in 1 until 64) {
            var t = b[off + ZIGZAG[k]]
            if (t == 0) { r++; continue }
            while (r > 15) { sink.symbol(c.tbl, true, 0xf0); r -= 16 }
            var t2 = t
            if (t < 0) { t = -t; t2-- }
            val n = nbitsOf(t)
            sink.symbol(c.tbl, true, (r shl 4) + n); sink.bits(t2, n)
            r = 0
        }
        if (r > 0) sink.symbol(c.tbl, true, 0)
    }

    private fun dcFirst(st: State, sink: Sink, ci: Int, c: EncComp, off: Int, al: Int) {
        val v = c.coef[off] shr al
        var temp = v - st.lastDc[ci]; st.lastDc[ci] = v
        var temp2 = temp
        if (temp < 0) { temp = -temp; temp2-- }
        val nb = nbitsOf(temp)
        sink.symbol(c.tbl, false, nb); sink.bits(temp2, nb)
    }

    private fun emitEobrun(st: State, sink: Sink, scan: Scan) {
        if (st.eobrun > 0) {
            val nb = nbitsOf(st.eobrun) - 1
            check(nb <= 14)
            val tbl = comps[scan.comps[0]].tbl
            sink.symbol(tbl, true, nb shl 4)
            if (nb > 0) sink.bits(st.eobrun, nb)
            st.eobrun = 0
            for (i in 0 until st.be) sink.bits(st.corr[i], 1)
            st.be = 0
        }
    }

    private fun acFirst(st: State, sink: Sink, c: EncComp, off: Int, scan: Scan) {
        var r = 0
        for (k in scan.ss..scan.se) {
            var t = c.coef[off + ZIGZAG[k]]
            if (t == 0) { r++; continue }
            val t2: Int
            if (t < 0) { t = (-t) shr scan.al; t2 = t.inv() } else { t = t shr scan.al; t2 = t }
            if (t == 0) { r++; continue }
            if (st.eobrun > 0) emitEobrun(st, sink, scan)
            while (r > 15) { sink.symbol(c.tbl, true, 0xf0); r -= 16 }
            val n = nbitsOf(t)
            sink.symbol(c.tbl, true, (r shl 4) + n); sink.bits(t2, n)
            r = 0
        }
        if (r > 0) {
            st.eobrun++
            if (st.eobrun == 0x7fff) emitEobrun(st, sink, scan)
        }
    }

    private val absv = IntArray(64)
    private val br = IntArray(64)

    private fun acRefine(st: State, sink: Sink, c: EncComp, off: Int, scan: Scan) {
        var eob = 0
        for (k in scan.ss..scan.se) {
            var t = c.coef[off + ZIGZAG[k]]
            if (t < 0) t = -t
            t = t shr scan.al
            absv[k] = t
            if (t == 1) eob = k
        }
        var r = 0
        var nbr = 0          // correction bits buffered for the current block
        for (k in scan.ss..scan.se) {
            val t = absv[k]
            if (t == 0) { r++; continue }
            while (r > 15 && k <= eob) {
                emitEobrun(st, sink, scan)
                sink.symbol(c.tbl, true, 0xf0)
                r -= 16
                for (i in 0 until nbr) sink.bits(br[i], 1)
                nbr = 0
            }
            if (t > 1) { br[nbr++] = t and 1; continue }
            emitEobrun(st, sink, scan)
            sink.symbol(c.tbl, true, (r shl 4) + 1)
            sink.bits(if (c.coef[off + ZIGZAG[k]] < 0) 0 else 1, 1)
            for (i in 0 until nbr) sink.bits(br[i], 1)
            nbr = 0; r = 0
        }
        if (r > 0 || nbr > 0) {
            st.eobrun++
            for (i in 0 until nbr) st.corr[st.be + i] = br[i]
            st.be += nbr
            if (st.eobrun == 0x7fff || st.be > 1000 - 64 + 1) emitEobrun(st, sink, scan)
        }
    }

    // ------------------------------------------------------------------ markers

    private fun u16(o: ByteArrayOutputStream, v: Int) { o.write(v shr 8); o.write(v and 0xff) }

    private fun writeHeaders(o: ByteArrayOutputStream) {
        o.write(0xff); o.write(0xd8)
        // JFIF APP0, version 1.01, no units, 1:1 aspect, no thumbnail
        o.write(0xff); o.write(0xe0); u16(o, 16)
        o.write("JFIF".toByteArray()); o.write(0); o.write(1); o.write(1)
        o.write(0); u16(o, 1); u16(o, 1); o.write(0); o.write(0)
    }

    private fun writeFrame(o: ByteArrayOutputStream) {
        val used = comps.map { it.tq }.distinct()
        for (t in used) {
            o.write(0xff); o.write(0xdb); u16(o, 67); o.write(t)
            for (i in 0 until 64) o.write(quant[t][ZIGZAG[i]])
        }
        o.write(0xff); o.write(if (opt.progressive) 0xc2 else 0xc0)
        u16(o, 8 + 3 * comps.size); o.write(8); u16(o, img.height); u16(o, img.width); o.write(comps.size)
        for (c in comps) { o.write(c.id); o.write((c.h shl 4) or c.v); o.write(c.tq) }
    }

    private fun writeDht(o: ByteArrayOutputStream, t: HuffSpec, idx: Int, ac: Boolean) {
        o.write(0xff); o.write(0xc4)
        u16(o, 2 + 1 + 16 + t.vals.size)
        o.write(idx + if (ac) 0x10 else 0)
        for (i in 1..16) o.write(t.bits[i])
        for (v in t.vals) o.write(v)
    }
}
