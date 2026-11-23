package ochre

class JpegError(msg: String) : Exception(msg)

/** Decoding Huffman table: 9-bit lookahead table plus canonical maxcode/valptr fallback. */
class HuffDecoder(val spec: HuffSpec) {
    private val maxcode = IntArray(18)
    private val valptr = IntArray(17)
    private val mincode = IntArray(17)
    val look = IntArray(1 shl LOOK) // (len shl 8) | symbol, 0 if not resolvable

    init {
        var code = 0; var k = 0
        for (len in 1..16) {
            valptr[len] = k; mincode[len] = code
            code += spec.bits[len]; k += spec.bits[len]
            if (code > (1 shl len)) throw JpegError("bad Huffman table (code space overflow)")
            maxcode[len] = if (spec.bits[len] != 0) code - 1 else -1
            code = code shl 1
        }
        maxcode[17] = Int.MAX_VALUE
        val (codes, sizes) = spec.codes()
        for (sym in spec.vals) {
            val len = sizes[sym]
            if (len <= LOOK) {
                val base = codes[sym] shl (LOOK - len)
                for (f in 0 until (1 shl (LOOK - len))) look[base or f] = (len shl 8) or sym
            }
        }
    }

    fun decode(br: BitReader): Int {
        val peek = br.peek(LOOK)
        val e = look[peek]
        if (e != 0) { br.skip(e shr 8); return e and 0xff }
        var code = br.bits(LOOK + 1)
        var len = LOOK + 1
        while (len <= 16 && code > maxcode[len]) { code = (code shl 1) or br.bit(); len++ }
        if (len > 16) throw JpegError("corrupt Huffman code")
        val i = valptr[len] + code - mincode[len]
        if (i !in spec.vals.indices) throw JpegError("corrupt Huffman code")
        return spec.vals[i]
    }

    companion object { const val LOOK = 9 }
}

/** MSB-first entropy-segment reader that un-stuffs 0xFF00 and stops (feeding zeros) at markers. */
class BitReader(private val d: ByteArray, var pos: Int) {
    private var acc = 0L
    private var cnt = 0
    var hitMarker = false; private set

    private fun fill() {
        while (cnt <= 56) {
            var b = 0
            if (!hitMarker && pos < d.size) {
                b = d[pos].toInt() and 0xff
                if (b == 0xff) {
                    val nx = if (pos + 1 < d.size) d[pos + 1].toInt() and 0xff else 0xd9
                    if (nx == 0) pos += 2 else { hitMarker = true; b = 0 }
                } else pos++
            }
            acc = acc or (b.toLong() shl (56 - cnt))
            cnt += 8
        }
    }
    fun peek(n: Int): Int { if (cnt < n) fill(); return (acc ushr (64 - n)).toInt() }
    fun skip(n: Int) { acc = acc shl n; cnt -= n }
    fun bits(n: Int): Int { if (n == 0) return 0; val v = peek(n); skip(n); return v }
    fun bit(): Int = bits(1)
    fun receiveExtend(s: Int): Int {
        if (s == 0) return 0
        val v = bits(s)
        return if (v < (1 shl (s - 1))) v - (1 shl s) + 1 else v
    }
    /** Discard buffered bits and consume the expected RSTn marker. */
    fun restart() {
        acc = 0; cnt = 0; hitMarker = false
        while (pos + 1 < d.size) {
            if ((d[pos].toInt() and 0xff) == 0xff) {
                val m = d[pos + 1].toInt() and 0xff
                if (m in 0xd0..0xd7) { pos += 2; return }
                if (m != 0 && m != 0xff) return // some other marker: leave it for the caller
            }
            pos++
        }
    }
}

class Component(val id: Int, val h: Int, val v: Int, var tq: Int) {
    var bw = 0; var bh = 0          // blocks actually covering the component (libjpeg width_in_blocks)
    var bwAlloc = 0; var bhAlloc = 0 // padded to whole MCUs
    var dsW = 0; var dsH = 0        // downsampled_width / height
    lateinit var coef: IntArray     // natural-order coefficients, 64 per block
    var dcPred = 0
    var dcTable = 0; var acTable = 0
}

data class ScanInfo(val comps: List<Int>, val ss: Int, val se: Int, val ah: Int, val al: Int)

class Frame(val progressive: Boolean, val width: Int, val height: Int, val comps: List<Component>) {
    val hmax = comps.maxOf { it.h }
    val vmax = comps.maxOf { it.v }
    val mcusX = ceilDiv(width, 8 * hmax)
    val mcusY = ceilDiv(height, 8 * vmax)
    init {
        for (c in comps) {
            c.dsW = ceilDiv(width * c.h, hmax); c.dsH = ceilDiv(height * c.v, vmax)
            c.bw = ceilDiv(width * c.h, hmax * 8); c.bh = ceilDiv(height * c.v, vmax * 8)
            c.bwAlloc = mcusX * c.h; c.bhAlloc = mcusY * c.v
            c.coef = IntArray(c.bwAlloc * c.bhAlloc * 64)
        }
    }
}

fun ceilDiv(a: Int, b: Int) = (a + b - 1) / b

/** A decoded image: interleaved 8-bit samples, 1 (gray) or 3 (RGB) channels. */
class Raster(val width: Int, val height: Int, val channels: Int, val data: ByteArray = ByteArray(width * height * channels))

class Decoder(private val d: ByteArray) {
    val qt = arrayOfNulls<IntArray>(4)
    private val dcTabs = arrayOfNulls<HuffDecoder>(4)
    private val acTabs = arrayOfNulls<HuffDecoder>(4)
    var frame: Frame? = null; private set
    var restartInterval = 0; private set
    private var sawJfif = false
    private var adobeTransform = -1
    private var eobrun = 0
    val scans = ArrayList<ScanInfo>()
    val markers = ArrayList<String>()

    /** Called after each scan (used to render progressive refinement). */
    var onScan: ((Decoder) -> Unit)? = null

    fun decode(): Raster {
        parse()
        return render()
    }

    fun parse() {
        var p = 0
        if (d.size < 4 || (d[0].toInt() and 0xff) != 0xff || (d[1].toInt() and 0xff) != 0xd8) throw JpegError("not a JPEG (no SOI)")
        p = 2
        markers.add("SOI")
        while (true) {
            while (p < d.size && (d[p].toInt() and 0xff) != 0xff) p++ // tolerate garbage
            while (p < d.size && (d[p].toInt() and 0xff) == 0xff) p++ // fill bytes
            if (p >= d.size) throw JpegError("unexpected end of data (no EOI)")
            val m = d[p++].toInt() and 0xff
            if (m == 0xd9) { markers.add("EOI"); return }
            if (m in 0xd0..0xd7 || m == 0x01) continue
            if (p + 2 > d.size) throw JpegError("unexpected end of data")
            val len = u16(p)
            val seg = p + 2; val end = p + len
            if (len < 2 || end > d.size) throw JpegError("truncated segment %02X".format(m))
            when (m) {
                0xc0, 0xc1, 0xc2 -> { readSof(m, seg); markers.add("SOF${m - 0xc0} ${frame!!.width}x${frame!!.height}") }
                0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf ->
                    throw JpegError("unsupported JPEG process SOF%d (lossless/hierarchical/arithmetic)".format(m - 0xc0))
                0xc4 -> { readDht(seg, end); markers.add("DHT") }
                0xdb -> { readDqt(seg, end); markers.add("DQT") }
                0xdd -> { restartInterval = u16(seg); markers.add("DRI $restartInterval") }
                0xda -> { p = readScan(p); onScan?.invoke(this); continue }
                0xe0 -> { if (len >= 7 && String(d, seg, 4, Charsets.ISO_8859_1) == "JFIF") sawJfif = true; markers.add("APP0") }
                0xee -> {
                    if (len >= 12 && String(d, seg, 5, Charsets.ISO_8859_1) == "Adobe") adobeTransform = d[seg + 11].toInt() and 0xff
                    markers.add("APP14")
                }
                0xfe -> markers.add("COM \"" + String(d, seg, len - 2, Charsets.ISO_8859_1).take(40) + "\"")
                else -> markers.add("%s%02X".format(if (m in 0xe0..0xef) "APP" + (m - 0xe0) + " " else "M", m))
            }
            p = end
        }
    }

    private fun u16(p: Int) = ((d[p].toInt() and 0xff) shl 8) or (d[p + 1].toInt() and 0xff)

    private fun readSof(m: Int, p: Int) {
        if (frame != null) throw JpegError("duplicate SOF")
        if ((d[p].toInt() and 0xff) != 8) throw JpegError("only 8-bit precision is supported")
        val h = u16(p + 1); val w = u16(p + 3); val n = d[p + 5].toInt() and 0xff
        if (u16(p - 2) != 8 + 3 * n) throw JpegError("bad SOF length")
        if (w == 0 || h == 0) throw JpegError("zero image dimension (DNL not supported)")
        if (w.toLong() * h > 200_000_000L) throw JpegError("image too large")
        if (n != 1 && n != 3) throw JpegError("$n-component images are not supported")
        val comps = (0 until n).map {
            val o = p + 6 + it * 3
            val hv = d[o + 1].toInt() and 0xff
            Component(d[o].toInt() and 0xff, hv shr 4, hv and 15, d[o + 2].toInt() and 0xff).also { c ->
                if (c.h !in 1..4 || c.v !in 1..4) throw JpegError("bad sampling factors")
                if (c.tq > 3) throw JpegError("bad quantization table index")
            }
        }
        frame = Frame(m == 0xc2, w, h, comps)
    }

    private fun readDht(start: Int, end: Int) {
        var p = start
        while (p < end) {
            val tc = (d[p].toInt() and 0xff) shr 4; val th = d[p].toInt() and 15
            val bits = IntArray(17); var total = 0
            for (i in 1..16) { bits[i] = d[p + i].toInt() and 0xff; total += bits[i] }
            if (th > 3 || tc > 1 || total > 256 || p + 17 + total > end) throw JpegError("bad DHT segment")
            val vals = IntArray(total) { d[p + 17 + it].toInt() and 0xff }
            val t = HuffDecoder(HuffSpec(bits, vals))
            if (tc == 0) dcTabs[th and 3] = t else acTabs[th and 3] = t
            p += 17 + total
        }
    }

    private fun readDqt(start: Int, end: Int) {
        var p = start
        while (p < end) {
            val pq = (d[p].toInt() and 0xff) shr 4; val tq = d[p].toInt() and 3
            val t = IntArray(64)
            if (pq > 1 || p + 1 + 64 * (pq + 1) > end) throw JpegError("bad DQT segment")
            for (i in 0 until 64) {
                t[ZIGZAG[i]] = if (pq == 0) d[p + 1 + i].toInt() and 0xff else u16(p + 1 + 2 * i)
            }
            qt[tq] = t
            p += 1 + 64 * (if (pq == 0) 1 else 2)
        }
    }

    private fun readScan(p: Int): Int {
        val f = frame ?: throw JpegError("SOS before SOF")
        val len = u16(p)
        val ns = d[p + 2].toInt() and 0xff
        if (ns !in 1..4 || len != 6 + 2 * ns || p + len > d.size) throw JpegError("bad SOS segment")
        val sc = ArrayList<Component>()
        for (i in 0 until ns) {
            val id = d[p + 3 + i * 2].toInt() and 0xff
            val t = d[p + 4 + i * 2].toInt() and 0xff
            val c = f.comps.firstOrNull { it.id == id } ?: throw JpegError("scan references unknown component $id")
            c.dcTable = t shr 4; c.acTable = t and 15
            if (c.dcTable > 3 || c.acTable > 3 || c in sc) throw JpegError("bad SOS component spec")
            sc.add(c)
        }
        val q = p + 3 + ns * 2
        val ss = d[q].toInt() and 0xff; val se = d[q + 1].toInt() and 0xff
        val ah = (d[q + 2].toInt() and 0xff) shr 4; val al = d[q + 2].toInt() and 15
        if (f.progressive) {
            if (ss > se || se > 63 || al > 13 || (ss == 0 && se != 0) || (ss > 0 && ns != 1)) throw JpegError("bad progressive scan parameters")
        } else if (ss != 0 || se != 63 || ah != 0 || al != 0) throw JpegError("bad sequential scan parameters")
        if (sc.sumOf { it.h * it.v } > 10 && ns > 1) throw JpegError("too many blocks per MCU")
        scans.add(ScanInfo(sc.map { f.comps.indexOf(it) }, ss, se, ah, al))
        markers.add("SOS comps=${sc.map { it.id }} Ss=$ss Se=$se Ah=$ah Al=$al")
        val br = BitReader(d, p + len)
        decodeScan(f, sc, br, ss, se, ah, al)
        // advance to the next non-RST marker
        var r = br.pos
        while (r + 1 < d.size) {
            if ((d[r].toInt() and 0xff) == 0xff) {
                val m = d[r + 1].toInt() and 0xff
                if (m != 0 && m !in 0xd0..0xd7 && m != 0xff) break
            }
            r++
        }
        return r
    }

    private fun decodeScan(f: Frame, sc: List<Component>, br: BitReader, ss: Int, se: Int, ah: Int, al: Int) {
        for (c in sc) c.dcPred = 0
        eobrun = 0
        val decodeBlock: (Component, Int) -> Unit = if (!f.progressive) { c, off -> baseline(c, off, br) }
        else if (ss == 0) {
            if (se != 0) throw JpegError("bad progressive DC scan")
            if (ah == 0) { c, off -> dcFirst(c, off, br, al) } else { c, off -> dcRefine(c, off, br, al) }
        } else {
            if (sc.size != 1) throw JpegError("progressive AC scans must have one component")
            if (ah == 0) { c, off -> acFirst(c, off, br, ss, se, al) } else { c, off -> acRefine(c, off, br, ss, se, al) }
        }
        var mcu = 0
        val total: Int
        val single = sc.size == 1
        if (single) {
            val c = sc[0]
            total = c.bw * c.bh
            for (by in 0 until c.bh) for (bx in 0 until c.bw) {
                checkRestart(br, mcu, total, sc); mcu++
                decodeBlock(c, (by * c.bwAlloc + bx) * 64)
            }
        } else {
            total = f.mcusX * f.mcusY
            for (my in 0 until f.mcusY) for (mx in 0 until f.mcusX) {
                checkRestart(br, mcu, total, sc); mcu++
                for (c in sc) for (v in 0 until c.v) for (h in 0 until c.h) {
                    decodeBlock(c, ((my * c.v + v) * c.bwAlloc + mx * c.h + h) * 64)
                }
            }
        }
    }

    private fun checkRestart(br: BitReader, mcu: Int, total: Int, sc: List<Component>) {
        if (restartInterval > 0 && mcu > 0 && mcu % restartInterval == 0) {
            br.restart()
            for (c in sc) c.dcPred = 0
            eobrun = 0
        }
    }

    private fun dc(c: Component) = dcTabs[c.dcTable] ?: throw JpegError("missing DC table ${c.dcTable}")
    private fun ac(c: Component) = acTabs[c.acTable] ?: throw JpegError("missing AC table ${c.acTable}")

    private fun baseline(c: Component, off: Int, br: BitReader) {
        val blk = c.coef
        val t = dc(c).decode(br)
        c.dcPred += br.receiveExtend(t)
        blk[off] = c.dcPred
        val act = ac(c)
        var k = 1
        while (k < 64) {
            val rs = act.decode(br)
            val r = rs shr 4; val s = rs and 15
            if (s != 0) {
                k += r
                if (k > 63) break
                blk[off + ZIGZAG[k]] = br.receiveExtend(s)
                k++
            } else {
                if (r != 15) break
                k += 16
            }
        }
    }

    private fun dcFirst(c: Component, off: Int, br: BitReader, al: Int) {
        val t = dc(c).decode(br)
        c.dcPred += br.receiveExtend(t)
        c.coef[off] = c.dcPred shl al
    }

    private fun dcRefine(c: Component, off: Int, br: BitReader, al: Int) {
        if (br.bit() != 0) c.coef[off] = c.coef[off] or (1 shl al)
    }

    private fun acFirst(c: Component, off: Int, br: BitReader, ss: Int, se: Int, al: Int) {
        if (eobrun > 0) { eobrun--; return }
        val act = ac(c)
        var k = ss
        while (k <= se) {
            val rs = act.decode(br)
            val r = rs shr 4; val s = rs and 15
            if (s != 0) {
                k += r
                if (k > 63) break
                c.coef[off + ZIGZAG[k]] = br.receiveExtend(s) * (1 shl al)
            } else {
                if (r != 15) {
                    eobrun = 1 shl r
                    if (r != 0) eobrun += br.bits(r)
                    eobrun--
                    break
                }
                k += 15
            }
            k++
        }
    }

    private fun acRefine(c: Component, off: Int, br: BitReader, ss: Int, se: Int, al: Int) {
        val p1 = 1 shl al; val m1 = -1 shl al
        val blk = c.coef
        var k = ss
        if (eobrun == 0) {
            val act = ac(c)
            while (k <= se) {
                val rs = act.decode(br)
                var r = rs shr 4; var s = rs and 15
                if (s != 0) {
                    s = if (br.bit() != 0) p1 else m1
                } else if (r != 15) {
                    eobrun = 1 shl r
                    if (r != 0) eobrun += br.bits(r)
                    break
                }
                while (k <= se) {
                    val i = off + ZIGZAG[k]
                    val coef = blk[i]
                    if (coef != 0) {
                        if (br.bit() != 0 && (coef and p1) == 0) blk[i] = if (coef >= 0) coef + p1 else coef + m1
                    } else {
                        if (--r < 0) break
                    }
                    k++
                }
                if (s != 0 && k <= se) blk[off + ZIGZAG[k]] = s
                k++
            }
        }
        if (eobrun > 0) {
            while (k <= se) {
                val i = off + ZIGZAG[k]
                val coef = blk[i]
                if (coef != 0 && br.bit() != 0 && (coef and p1) == 0) blk[i] = if (coef >= 0) coef + p1 else coef + m1
                k++
            }
            eobrun--
        }
    }

    // ---------------------------------------------------------------- reconstruction

    /** Inverse-DCT every block of every component into a padded sample plane. */
    fun planes(): List<ByteArray> {
        val f = frame ?: throw JpegError("no frame")
        val ws = IntArray(64)
        return f.comps.map { c ->
            val q = qt[c.tq] ?: throw JpegError("missing quantization table ${c.tq}")
            val stride = c.bwAlloc * 8
            val plane = ByteArray(stride * c.bhAlloc * 8)
            for (by in 0 until c.bhAlloc) for (bx in 0 until c.bwAlloc) {
                Dct.inverse(c.coef, (by * c.bwAlloc + bx) * 64, q, plane, by * 8 * stride + bx * 8, stride, ws)
            }
            plane
        }
    }

    fun isRgbColorspace(): Boolean {
        val f = frame!!
        if (f.comps.size != 3) return false
        if (sawJfif) return false
        if (adobeTransform >= 0) return adobeTransform == 0
        val ids = f.comps.map { it.id }
        return ids == listOf(82, 71, 66)
    }

    fun render(): Raster {
        val f = frame ?: throw JpegError("no frame")
        val pl = planes()
        val full = f.comps.mapIndexed { i, c -> Upsample.toFull(f, c, pl[i], c.bwAlloc * 8) }
        val W = f.width; val H = f.height
        if (f.comps.size == 1) {
            return Raster(W, H, 1, full[0])
        }
        val r = Raster(W, H, 3)
        val yp = full[0]; val cb = full[1]; val cr = full[2]
        val rgb = isRgbColorspace()
        var o = 0
        for (i in 0 until W * H) {
            val Y = yp[i].toInt() and 0xff; val B = cb[i].toInt() and 0xff; val R = cr[i].toInt() and 0xff
            if (rgb) {
                r.data[o] = yp[i]; r.data[o + 1] = cb[i]; r.data[o + 2] = cr[i]
            } else {
                r.data[o] = clamp(Y + Color.CR_R[R]).toByte()
                r.data[o + 1] = clamp(Y + ((Color.CB_G[B] + Color.CR_G[R]) shr 16)).toByte()
                r.data[o + 2] = clamp(Y + Color.CB_B[B]).toByte()
            }
            o += 3
        }
        return r
    }
}

fun clamp(v: Int) = if (v < 0) 0 else if (v > 255) 255 else v

/** Fixed-point YCbCr<->RGB tables from jdcolor.c / jccolor.c (SCALEBITS = 16). */
object Color {
    private const val SCALEBITS = 16
    private const val ONE_HALF = 1 shl (SCALEBITS - 1)
    private fun fix(x: Double) = (x * (1 shl SCALEBITS) + 0.5).toInt()
    val CR_R = IntArray(256) { ((fix(1.40200) * (it - 128)) + ONE_HALF) shr SCALEBITS }
    val CB_B = IntArray(256) { ((fix(1.77200) * (it - 128)) + ONE_HALF) shr SCALEBITS }
    val CR_G = IntArray(256) { -fix(0.71414) * (it - 128) }
    val CB_G = IntArray(256) { -fix(0.34414) * (it - 128) + ONE_HALF }

    // forward (encoder) tables
    private const val CBCR_OFFSET = 128 shl SCALEBITS
    val R_Y = IntArray(256) { fix(0.29900) * it }
    val G_Y = IntArray(256) { fix(0.58700) * it }
    val B_Y = IntArray(256) { fix(0.11400) * it + ONE_HALF }
    val R_CB = IntArray(256) { -fix(0.16874) * it }
    val G_CB = IntArray(256) { -fix(0.33126) * it }
    val B_CB = IntArray(256) { fix(0.5) * it + CBCR_OFFSET + ONE_HALF - 1 } // also R_CR
    val G_CR = IntArray(256) { -fix(0.41869) * it }
    val B_CR = IntArray(256) { -fix(0.08131) * it }
}
