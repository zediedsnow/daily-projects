(* SplitMix64: tiny, fast, and identical on every platform, so a seed
   reproduces a run bit-for-bit. *)
type t = { mutable s : int64 }

let make seed = { s = Int64.of_int seed }

let next t =
  t.s <- Int64.add t.s 0x9E3779B97F4A7C15L;
  let z = t.s in
  let z = Int64.mul (Int64.logxor z (Int64.shift_right_logical z 30)) 0xBF58476D1CE4E5B9L in
  let z = Int64.mul (Int64.logxor z (Int64.shift_right_logical z 27)) 0x94D049BB133111EBL in
  Int64.logxor z (Int64.shift_right_logical z 31)

let int t n = Int64.to_int (Int64.unsigned_rem (next t) (Int64.of_int n))
let float t = Int64.to_float (Int64.shift_right_logical (next t) 11) /. 9007199254740992.
let chance t p = float t < p
let range t lo hi = lo + int t (hi - lo + 1)
