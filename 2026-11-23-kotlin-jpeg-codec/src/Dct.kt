package ochre

/**
 * The "ISLOW" integer DCT pair from the IJG reference (Loeffler/Ligtenberg/Moschytz, 12 multiplies
 * per 1-D pass, 13-bit fixed point constants). Reproducing it to the bit is what lets ochre agree
 * exactly with libjpeg-turbo instead of "within one or two levels".
 */
object Dct {
    private const val CONST_BITS = 13
    private const val PASS1_BITS = 2
    private const val F_0_298631336 = 2446
    private const val F_0_390180644 = 3196
    private const val F_0_541196100 = 4433
    private const val F_0_765366865 = 6270
    private const val F_0_899976223 = 7373
    private const val F_1_175875602 = 9633
    private const val F_1_501321110 = 12299
    private const val F_1_847759065 = 15137
    private const val F_1_961570560 = 16069
    private const val F_2_053119869 = 16819
    private const val F_2_562915447 = 20995
    private const val F_3_072711026 = 25172

    private fun descale(x: Int, n: Int) = (x + (1 shl (n - 1))) shr n

    /** Post-IDCT range limiting with libjpeg's 10-bit wraparound table semantics. */
    private val RANGE = IntArray(1024).also {
        for (k in 0 until 1024) it[k] = when {
            k < 128 -> k + 128
            k < 512 -> 255
            k < 896 -> 0
            else -> k - 896
        }
    }

    /** In-place forward DCT on 64 centered samples (output scaled up by 8, as in jfdctint.c). */
    fun forward(d: IntArray) {
        for (r in 0 until 8) {
            val o = r * 8
            val tmp0 = d[o] + d[o + 7]; val tmp7 = d[o] - d[o + 7]
            val tmp1 = d[o + 1] + d[o + 6]; val tmp6 = d[o + 1] - d[o + 6]
            val tmp2 = d[o + 2] + d[o + 5]; val tmp5 = d[o + 2] - d[o + 5]
            val tmp3 = d[o + 3] + d[o + 4]; val tmp4 = d[o + 3] - d[o + 4]
            val tmp10 = tmp0 + tmp3; val tmp13 = tmp0 - tmp3
            val tmp11 = tmp1 + tmp2; val tmp12 = tmp1 - tmp2
            d[o] = (tmp10 + tmp11) shl PASS1_BITS
            d[o + 4] = (tmp10 - tmp11) shl PASS1_BITS
            var z1 = (tmp12 + tmp13) * F_0_541196100
            d[o + 2] = descale(z1 + tmp13 * F_0_765366865, CONST_BITS - PASS1_BITS)
            d[o + 6] = descale(z1 + tmp12 * -F_1_847759065, CONST_BITS - PASS1_BITS)
            z1 = tmp4 + tmp7; var z2 = tmp5 + tmp6; var z3 = tmp4 + tmp6; var z4 = tmp5 + tmp7
            val z5 = (z3 + z4) * F_1_175875602
            val t4 = tmp4 * F_0_298631336; val t5 = tmp5 * F_2_053119869
            val t6 = tmp6 * F_3_072711026; val t7 = tmp7 * F_1_501321110
            z1 *= -F_0_899976223; z2 *= -F_2_562915447; z3 *= -F_1_961570560; z4 *= -F_0_390180644
            z3 += z5; z4 += z5
            d[o + 7] = descale(t4 + z1 + z3, CONST_BITS - PASS1_BITS)
            d[o + 5] = descale(t5 + z2 + z4, CONST_BITS - PASS1_BITS)
            d[o + 3] = descale(t6 + z2 + z3, CONST_BITS - PASS1_BITS)
            d[o + 1] = descale(t7 + z1 + z4, CONST_BITS - PASS1_BITS)
        }
        for (c in 0 until 8) {
            val tmp0 = d[c] + d[c + 56]; val tmp7 = d[c] - d[c + 56]
            val tmp1 = d[c + 8] + d[c + 48]; val tmp6 = d[c + 8] - d[c + 48]
            val tmp2 = d[c + 16] + d[c + 40]; val tmp5 = d[c + 16] - d[c + 40]
            val tmp3 = d[c + 24] + d[c + 32]; val tmp4 = d[c + 24] - d[c + 32]
            val tmp10 = tmp0 + tmp3; val tmp13 = tmp0 - tmp3
            val tmp11 = tmp1 + tmp2; val tmp12 = tmp1 - tmp2
            d[c] = descale(tmp10 + tmp11, PASS1_BITS)
            d[c + 32] = descale(tmp10 - tmp11, PASS1_BITS)
            var z1 = (tmp12 + tmp13) * F_0_541196100
            d[c + 16] = descale(z1 + tmp13 * F_0_765366865, CONST_BITS + PASS1_BITS)
            d[c + 48] = descale(z1 + tmp12 * -F_1_847759065, CONST_BITS + PASS1_BITS)
            z1 = tmp4 + tmp7; var z2 = tmp5 + tmp6; var z3 = tmp4 + tmp6; var z4 = tmp5 + tmp7
            val z5 = (z3 + z4) * F_1_175875602
            val t4 = tmp4 * F_0_298631336; val t5 = tmp5 * F_2_053119869
            val t6 = tmp6 * F_3_072711026; val t7 = tmp7 * F_1_501321110
            z1 *= -F_0_899976223; z2 *= -F_2_562915447; z3 *= -F_1_961570560; z4 *= -F_0_390180644
            z3 += z5; z4 += z5
            d[c + 56] = descale(t4 + z1 + z3, CONST_BITS + PASS1_BITS)
            d[c + 40] = descale(t5 + z2 + z4, CONST_BITS + PASS1_BITS)
            d[c + 24] = descale(t6 + z2 + z3, CONST_BITS + PASS1_BITS)
            d[c + 8] = descale(t7 + z1 + z4, CONST_BITS + PASS1_BITS)
        }
    }

    /**
     * Dequantize + inverse DCT one block of natural-order coefficients, writing 8x8 samples
     * (0..255) into [out] at [off] with row stride [stride]. [ws] is a 64-int scratch buffer.
     */
    fun inverse(coef: IntArray, cOff: Int, q: IntArray, out: ByteArray, off: Int, stride: Int, ws: IntArray) {
        for (c in 0 until 8) {
            val i = cOff + c
            if (coef[i + 8] == 0 && coef[i + 16] == 0 && coef[i + 24] == 0 && coef[i + 32] == 0 &&
                coef[i + 40] == 0 && coef[i + 48] == 0 && coef[i + 56] == 0
            ) {
                val dc = (coef[i] * q[c]) shl PASS1_BITS
                for (r in 0 until 8) ws[r * 8 + c] = dc
                continue
            }
            var z2 = coef[i + 16] * q[c + 16]; var z3 = coef[i + 48] * q[c + 48]
            var z1 = (z2 + z3) * F_0_541196100
            var tmp2 = z1 + z3 * -F_1_847759065
            var tmp3 = z1 + z2 * F_0_765366865
            z2 = coef[i] * q[c]; z3 = coef[i + 32] * q[c + 32]
            var tmp0 = (z2 + z3) shl CONST_BITS
            var tmp1 = (z2 - z3) shl CONST_BITS
            val tmp10 = tmp0 + tmp3; val tmp13 = tmp0 - tmp3
            val tmp11 = tmp1 + tmp2; val tmp12 = tmp1 - tmp2
            tmp0 = coef[i + 56] * q[c + 56]; tmp1 = coef[i + 40] * q[c + 40]
            tmp2 = coef[i + 24] * q[c + 24]; tmp3 = coef[i + 8] * q[c + 8]
            z1 = tmp0 + tmp3; z2 = tmp1 + tmp2; z3 = tmp0 + tmp2; var z4 = tmp1 + tmp3
            val z5 = (z3 + z4) * F_1_175875602
            tmp0 *= F_0_298631336; tmp1 *= F_2_053119869; tmp2 *= F_3_072711026; tmp3 *= F_1_501321110
            z1 *= -F_0_899976223; z2 *= -F_2_562915447; z3 *= -F_1_961570560; z4 *= -F_0_390180644
            z3 += z5; z4 += z5
            tmp0 += z1 + z3; tmp1 += z2 + z4; tmp2 += z2 + z3; tmp3 += z1 + z4
            val n = CONST_BITS - PASS1_BITS
            ws[c] = descale(tmp10 + tmp3, n); ws[56 + c] = descale(tmp10 - tmp3, n)
            ws[8 + c] = descale(tmp11 + tmp2, n); ws[48 + c] = descale(tmp11 - tmp2, n)
            ws[16 + c] = descale(tmp12 + tmp1, n); ws[40 + c] = descale(tmp12 - tmp1, n)
            ws[24 + c] = descale(tmp13 + tmp0, n); ws[32 + c] = descale(tmp13 - tmp0, n)
        }
        val n2 = CONST_BITS + PASS1_BITS + 3
        for (r in 0 until 8) {
            val w = r * 8
            val o = off + r * stride
            if (ws[w + 1] == 0 && ws[w + 2] == 0 && ws[w + 3] == 0 && ws[w + 4] == 0 &&
                ws[w + 5] == 0 && ws[w + 6] == 0 && ws[w + 7] == 0
            ) {
                val v = RANGE[descale(ws[w], PASS1_BITS + 3) and 1023].toByte()
                for (k in 0 until 8) out[o + k] = v
                continue
            }
            var z2 = ws[w + 2]; var z3 = ws[w + 6]
            var z1 = (z2 + z3) * F_0_541196100
            var tmp2 = z1 + z3 * -F_1_847759065
            var tmp3 = z1 + z2 * F_0_765366865
            var tmp0 = (ws[w] + ws[w + 4]) shl CONST_BITS
            var tmp1 = (ws[w] - ws[w + 4]) shl CONST_BITS
            val tmp10 = tmp0 + tmp3; val tmp13 = tmp0 - tmp3
            val tmp11 = tmp1 + tmp2; val tmp12 = tmp1 - tmp2
            tmp0 = ws[w + 7]; tmp1 = ws[w + 5]; tmp2 = ws[w + 3]; tmp3 = ws[w + 1]
            z1 = tmp0 + tmp3; z2 = tmp1 + tmp2; z3 = tmp0 + tmp2; var z4 = tmp1 + tmp3
            val z5 = (z3 + z4) * F_1_175875602
            tmp0 *= F_0_298631336; tmp1 *= F_2_053119869; tmp2 *= F_3_072711026; tmp3 *= F_1_501321110
            z1 *= -F_0_899976223; z2 *= -F_2_562915447; z3 *= -F_1_961570560; z4 *= -F_0_390180644
            z3 += z5; z4 += z5
            tmp0 += z1 + z3; tmp1 += z2 + z4; tmp2 += z2 + z3; tmp3 += z1 + z4
            out[o] = RANGE[descale(tmp10 + tmp3, n2) and 1023].toByte()
            out[o + 7] = RANGE[descale(tmp10 - tmp3, n2) and 1023].toByte()
            out[o + 1] = RANGE[descale(tmp11 + tmp2, n2) and 1023].toByte()
            out[o + 6] = RANGE[descale(tmp11 - tmp2, n2) and 1023].toByte()
            out[o + 2] = RANGE[descale(tmp12 + tmp1, n2) and 1023].toByte()
            out[o + 5] = RANGE[descale(tmp12 - tmp1, n2) and 1023].toByte()
            out[o + 3] = RANGE[descale(tmp13 + tmp0, n2) and 1023].toByte()
            out[o + 4] = RANGE[descale(tmp13 - tmp0, n2) and 1023].toByte()
        }
    }
}
