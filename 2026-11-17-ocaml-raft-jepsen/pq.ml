(* Binary min-heap keyed on (time, insertion order): events at the same
   instant fire in the order they were scheduled, keeping runs deterministic. *)
type 'a t = { mutable a : (int * int * 'a) option array; mutable n : int; mutable seq : int }

let create () = { a = Array.make 256 None; n = 0; seq = 0 }
let size h = h.n
let lt (t1, s1, _) (t2, s2, _) = t1 < t2 || (t1 = t2 && s1 < s2)
let get h i = match h.a.(i) with Some x -> x | None -> assert false

let push h time v =
  if h.n = Array.length h.a then begin
    let b = Array.make (2 * h.n) None in
    Array.blit h.a 0 b 0 h.n;
    h.a <- b
  end;
  let x = (time, h.seq, v) in
  h.seq <- h.seq + 1;
  let i = ref h.n in
  h.n <- h.n + 1;
  while !i > 0 && lt x (get h ((!i - 1) / 2)) do
    h.a.(!i) <- h.a.((!i - 1) / 2);
    i := (!i - 1) / 2
  done;
  h.a.(!i) <- Some x

let pop h =
  if h.n = 0 then None
  else begin
    let top = get h 0 in
    h.n <- h.n - 1;
    let x = get h h.n in
    h.a.(h.n) <- None;
    if h.n > 0 then begin
      let i = ref 0 and fin = ref false in
      while not !fin do
        let l = (2 * !i) + 1 in
        if l >= h.n then fin := true
        else begin
          let c = if l + 1 < h.n && lt (get h (l + 1)) (get h l) then l + 1 else l in
          if lt (get h c) x then (h.a.(!i) <- h.a.(c); i := c) else fin := true
        end
      done;
      h.a.(!i) <- Some x
    end;
    let t, _, v = top in
    Some (t, v)
  end
