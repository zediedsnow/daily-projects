package ochre

import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO
import kotlin.math.log10
import kotlin.system.exitProcess

// ---------------------------------------------------------------- image I/O (PNM natively, PNG via ImageIO)

fun readImage(path: String): Raster {
    val bytes = File(path).readBytes()
    if (bytes.size > 2 && bytes[0] == 'P'.code.toByte() && (bytes[1] == '5'.code.toByte() || bytes[1] == '6'.code.toByte())) {
        var p = 2
        fun token(): Int {
            while (true) {
                while (bytes[p].toInt().toChar().isWhitespace()) p++
                if (bytes[p] == '#'.code.toByte()) { while (bytes[p] != '\n'.code.toByte()) p++ } else break
            }
            val s = p; while (!bytes[p].toInt().toChar().isWhitespace()) p++
            return String(bytes, s, p - s).toInt()
        }
        val ch = if (bytes[1] == '5'.code.toByte()) 1 else 3
        val w = token(); val h = token(); val mx = token(); p++
        require(mx == 255) { "only 8-bit PNM supported" }
        return Raster(w, h, ch, bytes.copyOfRange(p, p + w * h * ch))
    }
    if (bytes.size > 2 && (bytes[0].toInt() and 0xff) == 0xff && (bytes[1].toInt() and 0xff) == 0xd8) return Decoder(bytes).decode()
    val bi = ImageIO.read(File(path)) ?: error("cannot read $path")
    val gray = bi.type == BufferedImage.TYPE_BYTE_GRAY
    val r = Raster(bi.width, bi.height, if (gray) 1 else 3)
    for (y in 0 until bi.height) for (x in 0 until bi.width) {
        val argb = bi.getRGB(x, y)
        if (gray) r.data[y * bi.width + x] = bi.raster.getSample(x, y, 0).toByte()
        else {
            val o = (y * bi.width + x) * 3
            r.data[o] = (argb shr 16).toByte(); r.data[o + 1] = (argb shr 8).toByte(); r.data[o + 2] = argb.toByte()
        }
    }
    return r
}

fun writeImage(r: Raster, path: String) {
    if (path.endsWith(".ppm") || path.endsWith(".pgm") || path.endsWith(".pnm")) {
        File(path).outputStream().use {
            it.write("P${if (r.channels == 1) 5 else 6}\n${r.width} ${r.height}\n255\n".toByteArray()); it.write(r.data)
        }
        return
    }
    val bi = BufferedImage(r.width, r.height, if (r.channels == 1) BufferedImage.TYPE_BYTE_GRAY else BufferedImage.TYPE_INT_RGB)
    for (y in 0 until r.height) for (x in 0 until r.width) {
        val i = y * r.width + x
        if (r.channels == 1) bi.raster.setSample(x, y, 0, r.data[i].toInt() and 0xff)
        else bi.setRGB(x, y, ((r.data[3 * i].toInt() and 0xff) shl 16) or ((r.data[3 * i + 1].toInt() and 0xff) shl 8) or (r.data[3 * i + 2].toInt() and 0xff))
    }
    ImageIO.write(bi, path.substringAfterLast('.', "png"), File(path))
}

fun psnr(a: Raster, b: Raster): Double {
    require(a.width == b.width && a.height == b.height && a.channels == b.channels)
    var se = 0.0
    for (i in a.data.indices) { val d = (a.data[i].toInt() and 0xff) - (b.data[i].toInt() and 0xff); se += d * d }
    val mse = se / a.data.size
    return if (mse == 0.0) Double.POSITIVE_INFINITY else 10 * log10(255.0 * 255.0 / mse)
}

// ---------------------------------------------------------------- CLI

fun parseOptions(args: List<String>): EncodeOptions {
    var q = 75; var h = 2; var v = 2; var optimize = false; var prog = false; var rst = 0
    var i = 0
    while (i < args.size) {
        when (args[i]) {
            "-q", "--quality" -> q = args[++i].toInt()
            "-s", "--subsample" -> when (args[++i]) {
                "444" -> { h = 1; v = 1 }; "422" -> { h = 2; v = 1 }; "420" -> { h = 2; v = 2 }
                "440" -> { h = 1; v = 2 }; "411" -> { h = 4; v = 1 }
                else -> error("subsampling must be 444, 422, 420, 440 or 411")
            }
            "-o", "--optimize" -> optimize = true
            "-p", "--progressive" -> prog = true
            "-r", "--restart" -> rst = args[++i].toInt()
            else -> error("unknown option ${args[i]}")
        }
        i++
    }
    return EncodeOptions(q, h, v, optimize, prog, rst)
}

fun info(path: String) {
    val bytes = File(path).readBytes()
    val dec = Decoder(bytes)
    dec.parse()
    val f = dec.frame!!
    println("$path: ${bytes.size} bytes, ${f.width}x${f.height}, ${if (f.progressive) "progressive" else "baseline"}, " +
        "${f.comps.size} component(s), ${f.mcusX}x${f.mcusY} MCUs")
    for (c in f.comps) println("  component ${c.id}: sampling ${c.h}x${c.v}, quant table ${c.tq}, ${c.bw}x${c.bh} blocks")
    println("markers:")
    for (m in dec.markers) println("  $m")
    for ((i, t) in dec.qt.withIndex()) if (t != null) {
        println("quant table $i (natural order):")
        for (r in 0 until 8) println("  " + (0 until 8).joinToString(" ") { "%3d".format(t[r * 8 + it]) })
    }
    // coefficient statistics
    var nz = 0L; var tot = 0L
    for (c in f.comps) for (i in 0 until c.bh) for (j in 0 until c.bw) {
        val off = (i * c.bwAlloc + j) * 64
        for (k in 0 until 64) { tot++; if (c.coef[off + k] != 0) nz++ }
    }
    println("nonzero coefficients: $nz / $tot (%.1f%%), %.3f bits per pixel".format(100.0 * nz / tot, bytes.size * 8.0 / (f.width * f.height)))
}

fun usage(): Nothing {
    System.err.println("""
        ochre - a JPEG codec from scratch, bit-exact with libjpeg-turbo

        usage:
          ochre decode <in.jpg> <out.png|ppm|pgm>
          ochre encode <in.png|ppm|pgm|jpg> <out.jpg> [-q 1-100] [-s 444|422|420|440|411] [--optimize] [--progressive] [--restart N]
          ochre info <in.jpg>
          ochre scans <in.jpg> <prefix>          write the image as it looks after each progressive scan
          ochre psnr <a> <b>
          ochre batch <jobfile>                  run many decode/encode lines in one JVM (used by the test suite)
    """.trimIndent())
    exitProcess(2)
}

fun runLine(a: List<String>) {
    when (a[0]) {
        "decode" -> writeImage(Decoder(File(a[1]).readBytes()).decode(), a[2])
        "encode" -> File(a[2]).writeBytes(Encoder(readImage(a[1]), parseOptions(a.drop(3))).encode())
        else -> error("bad batch command ${a[0]}")
    }
}

fun main(argv: Array<String>) {
    if (argv.isEmpty()) usage()
    try {
        when (argv[0]) {
            "decode", "encode" -> {
                if (argv.size < 3) usage()
                val t0 = System.nanoTime()
                runLine(argv.toList())
                if (argv[0] == "encode") {
                    val src = readImage(argv[1]); val out = File(argv[2])
                    val back = Decoder(out.readBytes()).decode()
                    System.err.println("%s: %d bytes (%.3f bpp), PSNR %.2f dB, %.0f ms".format(argv[2], out.length(),
                        out.length() * 8.0 / (src.width * src.height), psnr(src, back), (System.nanoTime() - t0) / 1e6))
                }
            }
            "info" -> info(argv.getOrNull(1) ?: usage())
            "psnr" -> println("%.3f".format(psnr(readImage(argv[1]), readImage(argv[2]))))
            "scans" -> {
                val dec = Decoder(File(argv[1]).readBytes())
                var n = 0
                dec.onScan = { d ->
                    n++
                    writeImage(d.render(), "%s%02d.png".format(argv[2], n))
                }
                dec.parse()
                println("wrote $n scan images")
            }
            "corrupt" -> {
                // robustness fuzzing: mutate valid files, decoding must finish with an image or a clean JpegError
                val n = argv[2].toInt(); val rnd = java.util.Random(argv.getOrNull(3)?.toLong() ?: 1L)
                var decoded = 0; var rejected = 0; var crashed = 0
                for (path in argv[1].split(",")) {
                    val orig = File(path).readBytes()
                    repeat(n) {
                        val d = orig.copyOf(if (rnd.nextInt(4) == 0) rnd.nextInt(orig.size) + 1 else orig.size)
                        repeat(1 + rnd.nextInt(8)) { val i = rnd.nextInt(d.size); d[i] = when (rnd.nextInt(3)) { 0 -> rnd.nextInt(256).toByte(); 1 -> (d[i].toInt() xor (1 shl rnd.nextInt(8))).toByte(); else -> 0xff.toByte() } }
                        try { Decoder(d).decode(); decoded++ } catch (e: JpegError) { rejected++ } catch (e: Throwable) {
                            crashed++; if (crashed <= 5) { System.err.println("crash: $e"); e.stackTrace.take(3).forEach { System.err.println("   at $it") } }
                        }
                    }
                }
                println("corrupt: $decoded decoded, $rejected rejected cleanly, $crashed crashed")
                if (crashed > 0) exitProcess(1)
            }
            "batch" -> {
                var ok = 0; var bad = 0
                File(argv[1]).forEachLine { line ->
                    if (line.isBlank()) return@forEachLine
                    val a = line.trim().split(Regex("\\s+"))
                    try { runLine(a); ok++ } catch (e: Exception) { bad++; System.err.println("FAIL $line: $e") }
                }
                println("batch: $ok ok, $bad failed")
            }
            else -> usage()
        }
    } catch (e: JpegError) {
        System.err.println("ochre: ${e.message}"); exitProcess(1)
    }
}
