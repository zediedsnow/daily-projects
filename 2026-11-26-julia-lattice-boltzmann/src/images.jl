# ---------------------------------------------------------------------------
# Dependency-free image output: an indexed-colour PNG writer (zlib stream
# made of stored DEFLATE blocks after PNG "Up" filtering) and an animated
# GIF89a writer with its own variable-width LZW encoder.
# ---------------------------------------------------------------------------

const CRC_TABLE = let t = zeros(UInt32, 256)
    for n in 0:255
        c = UInt32(n)
        for _ in 1:8
            c = (c & 1) != 0 ? 0xedb88320 ⊻ (c >> 1) : c >> 1
        end
        t[n+1] = c
    end
    t
end

function crc32(data, crc = 0xffffffff)
    for b in data
        crc = CRC_TABLE[((crc ⊻ b) & 0xff) + 1] ⊻ (crc >> 8)
    end
    crc
end

function adler32(data)
    a = UInt32(1); b = UInt32(0)
    for x in data
        a = (a + x) % 65521
        b = (b + a) % 65521
    end
    (b << 16) | a
end

be32(x) = UInt8[(x >> 24) & 0xff, (x >> 16) & 0xff, (x >> 8) & 0xff, x & 0xff]

function png_chunk(io, tag, data)
    write(io, be32(UInt32(length(data))))
    body = vcat(Vector{UInt8}(tag), data)
    write(io, body)
    write(io, be32(crc32(body) ⊻ 0xffffffff))
end

"""
    write_png(path, idx, palette)

`idx` is a width × height matrix of palette indices (0-based UInt8);
`palette` a vector of (r, g, b) tuples. Row 1 of the image is y = height.
"""
function write_png(path, idx::AbstractMatrix{UInt8}, palette)
    w, h = size(idx)
    raw = UInt8[]
    prev = zeros(UInt8, w)
    for row in h:-1:1                      # flip: y up
        cur = idx[:, row]
        push!(raw, 0x02)                   # filter type "Up"
        append!(raw, cur .- prev)
        prev = cur
    end
    z = UInt8[0x78, 0x01]
    n = length(raw); pos = 1
    while true
        len = min(65535, n - pos + 1)
        last = pos + len > n
        push!(z, last ? 0x01 : 0x00)
        append!(z, UInt8[len & 0xff, len >> 8, ~len & 0xff, (~len >> 8) & 0xff])
        append!(z, @view raw[pos:pos+len-1])
        pos += len
        last && break
    end
    append!(z, be32(adler32(raw)))
    open(path, "w") do io
        write(io, UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        png_chunk(io, "IHDR", vcat(be32(UInt32(w)), be32(UInt32(h)),
                                   UInt8[8, 3, 0, 0, 0]))
        pal = UInt8[]
        for (r, g, b) in palette
            push!(pal, r, g, b)
        end
        png_chunk(io, "PLTE", pal)
        png_chunk(io, "IDAT", z)
        png_chunk(io, "IEND", UInt8[])
    end
    path
end

# --- GIF -------------------------------------------------------------------

"Variable-width LZW as specified by GIF89a (min code size 8)."
function gif_lzw(pixels::Vector{UInt8})
    clear = 256; eoi = 257
    out = UInt8[]; acc = UInt32(0); nbits = 0
    width = 9
    emit(code) = begin
        acc |= UInt32(code) << nbits; nbits += width
        while nbits >= 8
            push!(out, acc & 0xff); acc >>= 8; nbits -= 8
        end
    end
    dict = Dict{Tuple{Int,UInt8},Int}()
    next = 258
    emit(clear)
    prefix = Int(pixels[1])
    for k in 2:length(pixels)
        c = pixels[k]
        code = get(dict, (prefix, c), -1)
        if code >= 0
            prefix = code
            continue
        end
        emit(prefix)
        if next < 4096
            dict[(prefix, c)] = next
            next += 1
            # the decoder widens one code later, after it has seen `next-1`
            next > (1 << width) && width < 12 && (width += 1)
        else
            emit(clear)
            empty!(dict); next = 258; width = 9
        end
        prefix = Int(c)
    end
    emit(prefix)
    emit(eoi)
    nbits > 0 && push!(out, acc & 0xff)
    out
end

"""
    write_gif(path, frames, palette; delay = 4)

`frames` are width × height index matrices (y up), `delay` in 1/100 s.
"""
function write_gif(path, frames, palette; delay = 4)
    w, h = size(frames[1])
    le16(x) = UInt8[x & 0xff, (x >> 8) & 0xff]
    open(path, "w") do io
        write(io, b"GIF89a", le16(w), le16(h), UInt8[0xf7, 0, 0])
        for k in 1:256
            r, g, b = k <= length(palette) ? palette[k] : (0, 0, 0)
            write(io, UInt8[r, g, b])
        end
        write(io, UInt8[0x21, 0xff, 0x0b], b"NETSCAPE2.0",
              UInt8[3, 1, 0, 0, 0])                       # loop forever
        for fr in frames
            write(io, UInt8[0x21, 0xf9, 4, 0], le16(delay), UInt8[0, 0])
            write(io, UInt8[0x2c], le16(0), le16(0), le16(w), le16(h), UInt8[0])
            px = vec(permutedims(fr[:, end:-1:1]))       # row-major, top first
            data = gif_lzw(px)
            write(io, UInt8[8])
            for p in 1:255:length(data)
                chunk = @view data[p:min(p + 254, end)]
                write(io, UInt8(length(chunk)), chunk)
            end
            write(io, UInt8[0])
        end
        write(io, UInt8[0x3b])
    end
    path
end

# --- colour ---------------------------------------------------------------

"Diverging blue–white–red map in 254 entries, plus solid (254) and wall (255)."
function vort_palette()
    stops = [(5, 48, 97), (33, 102, 172), (67, 147, 195), (146, 197, 222),
             (247, 247, 247), (244, 165, 130), (214, 96, 77), (178, 24, 43),
             (103, 0, 31)]
    pal = NTuple{3,UInt8}[]
    for k in 0:253
        t = k / 253 * (length(stops) - 1)
        j = min(floor(Int, t), length(stops) - 2); a = t - j
        c0 = stops[j+1]; c1 = stops[j+2]
        push!(pal, ntuple(m -> round(UInt8, (1 - a) * c0[m] + a * c1[m]), 3))
    end
    push!(pal, (70, 70, 78), (30, 30, 36))
    pal
end

"Map a field to palette indices, clipping at ±`clip`, solids drawn grey."
function field_indices(field, solid, clip; scale = 1)
    nx, ny = size(field)
    img = Matrix{UInt8}(undef, nx * scale, ny * scale)
    for y in 1:ny*scale, x in 1:nx*scale
        X = (x - 1) ÷ scale + 1; Y = (y - 1) ÷ scale + 1
        img[x, y] = solid[X, Y] ? 0xfe :
            round(UInt8, clamp((field[X, Y] / clip + 1) / 2, 0, 1) * 253)
    end
    img
end
