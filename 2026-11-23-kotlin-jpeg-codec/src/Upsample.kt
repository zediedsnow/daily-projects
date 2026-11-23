package ochre

/**
 * Chroma upsampling exactly as libjpeg-turbo's jdsample.c does it: "fancy" triangle filters for
 * the common 2:1 cases (with their alternating +1/+2 and +7/+8 rounding biases and edge-row
 * replication), plain sample replication for everything else.
 */
object Upsample {
    fun toFull(f: Frame, c: Component, plane: ByteArray, stride: Int): ByteArray {
        val W = f.width; val H = f.height
        if (f.hmax % c.h != 0 || f.vmax % c.v != 0) throw JpegError("fractional sampling ratios are not supported")
        val sx = f.hmax / c.h; val sy = f.vmax / c.v
        val dw = c.dsW; val dh = c.dsH
        val outW = dw * sx; val outH = dh * sy
        val big = ByteArray(outW * outH)
        fun s(x: Int, y: Int) = plane[y * stride + x].toInt() and 0xff
        when {
            sx == 1 && sy == 1 -> for (y in 0 until dh) System.arraycopy(plane, y * stride, big, y * outW, dw)
            sx == 2 && sy == 1 && dw > 2 -> for (y in 0 until dh) {
                val o = y * outW
                big[o] = s(0, y).toByte()
                big[o + 1] = ((s(0, y) * 3 + s(1, y) + 2) shr 2).toByte()
                for (x in 1 until dw - 1) {
                    val v = s(x, y) * 3
                    big[o + 2 * x] = ((v + s(x - 1, y) + 1) shr 2).toByte()
                    big[o + 2 * x + 1] = ((v + s(x + 1, y) + 2) shr 2).toByte()
                }
                val l = dw - 1
                big[o + 2 * l] = ((s(l, y) * 3 + s(l - 1, y) + 1) shr 2).toByte()
                big[o + 2 * l + 1] = s(l, y).toByte()
            }
            sx == 1 && sy == 2 -> for (y in 0 until dh) for (v in 0..1) {
                val ny = if (v == 0) maxOf(y - 1, 0) else minOf(y + 1, dh - 1)
                val bias = if (v == 0) 1 else 2
                val o = (2 * y + v) * outW
                for (x in 0 until dw) big[o + x] = ((s(x, y) * 3 + s(x, ny) + bias) shr 2).toByte()
            }
            sx == 2 && sy == 2 && dw > 2 -> for (y in 0 until dh) for (v in 0..1) {
                val ny = if (v == 0) maxOf(y - 1, 0) else minOf(y + 1, dh - 1)
                val o = (2 * y + v) * outW
                fun col(x: Int) = s(x, y) * 3 + s(x, ny)
                var thiscol = col(0); var nextcol = col(1)
                big[o] = ((thiscol * 4 + 8) shr 4).toByte()
                big[o + 1] = ((thiscol * 3 + nextcol + 7) shr 4).toByte()
                var lastcol = thiscol; thiscol = nextcol
                for (x in 1 until dw - 1) {
                    nextcol = col(x + 1)
                    big[o + 2 * x] = ((thiscol * 3 + lastcol + 8) shr 4).toByte()
                    big[o + 2 * x + 1] = ((thiscol * 3 + nextcol + 7) shr 4).toByte()
                    lastcol = thiscol; thiscol = nextcol
                }
                val l = dw - 1
                big[o + 2 * l] = ((thiscol * 3 + lastcol + 8) shr 4).toByte()
                big[o + 2 * l + 1] = ((thiscol * 4 + 7) shr 4).toByte()
            }
            else -> for (y in 0 until outH) for (x in 0 until outW) big[y * outW + x] = plane[(y / sy) * stride + x / sx]
        }
        if (outW == W && outH == H) return big
        val out = ByteArray(W * H)
        for (y in 0 until H) System.arraycopy(big, y * outW, out, y * W, W)
        return out
    }
}
