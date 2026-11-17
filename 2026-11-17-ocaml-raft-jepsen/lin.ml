(* Linearizability checker for a read/write/compare-and-set register.

   This is the Wing & Gong search with Lowe's memoisation, the same
   algorithm used by Porcupine and (in spirit) Knossos:

   - every operation contributes a "call" and a "return" event to a
     time-ordered doubly linked list;
   - we walk the list; at a call we try to linearize that operation right
     now (apply it to the model); if the model accepts and the resulting
     (set of linearized ops, model state) has not been seen before we
     "lift" the op out of the list and restart from the head;
   - reaching a return event means some op that has already returned has
     not been linearized, so we backtrack;
   - an empty list means every op found a linearization point.

   The model is nondeterministic (an indeterminate compare-and-set may or
   may not have succeeded), so states are *sets* of register values. *)

type input = Read | Write of int | Cas of int * int
type output = RVal of int | WOk | CasRes of bool | Unknown

type op = {
  id : int;
  client : int;
  key : int;
  input : input;
  output : output;
  call : int;
  ret : int; (* max_int = indeterminate: the client timed out *)
  node : int; (* which server answered, -1 if none did *)
}

let indeterminate o = o.ret = max_int

let string_of_input = function
  | Read -> "read"
  | Write v -> Printf.sprintf "write %d" v
  | Cas (a, b) -> Printf.sprintf "cas %d->%d" a b

let string_of_output = function
  | RVal v -> string_of_int v
  | WOk -> "ok"
  | CasRes b -> if b then "ok" else "fail"
  | Unknown -> "?"

let describe o =
  Printf.sprintf "%s => %s" (string_of_input o.input) (string_of_output o.output)

let step1 st inp out =
  match (inp, out) with
  | Read, RVal v -> if v = st then [ st ] else []
  | Read, _ -> [ st ]
  | Write v, _ -> [ v ]
  | Cas (o, n), CasRes true -> if st = o then [ n ] else []
  | Cas (o, _), CasRes false -> if st <> o then [ st ] else []
  | Cas (o, n), _ -> if st = o then [ n ] else [ st ]

let step states inp out =
  List.sort_uniq compare (List.concat_map (fun s -> step1 s inp out) states)

let init_state = [ 0 ]

type violation = {
  prefix : op list; (* longest linearizable prefix found *)
  states : int list; (* register value(s) after that prefix *)
  stuck : op; (* an op that had returned but could not be placed *)
}

type result =
  | Linearizable of op list (* a witness order *)
  | Violation of violation
  | Gave_up of int

let check ?(budget = 20_000_000) (ops : op array) : result =
  let n = Array.length ops in
  if n = 0 then Linearizable []
  else begin
    let m = 2 * n in
    let evs = Array.make m (0, 0, 0) in
    Array.iteri
      (fun i o ->
        evs.(2 * i) <- (o.call, 0, i);
        evs.((2 * i) + 1) <- (o.ret, 1, i))
      ops;
    (* calls sort before returns at the same instant: touching intervals
       count as concurrent, which is the permissive (correct) reading *)
    Array.sort compare evs;
    let head = m in
    let next = Array.make (m + 1) (-1) and prev = Array.make (m + 1) (-1) in
    let is_call = Array.make m false and opi = Array.make m 0 in
    let ret_of = Array.make n 0 in
    Array.iteri
      (fun k (_, kind, i) ->
        is_call.(k) <- kind = 0;
        opi.(k) <- i;
        if kind = 1 then ret_of.(i) <- k)
      evs;
    next.(head) <- 0;
    prev.(0) <- head;
    for k = 0 to m - 1 do
      next.(k) <- (if k + 1 < m then k + 1 else -1);
      if k > 0 then prev.(k) <- k - 1
    done;
    let unlink k =
      let p = prev.(k) and nx = next.(k) in
      next.(p) <- nx;
      if nx >= 0 then prev.(nx) <- p
    in
    let relink k =
      let p = prev.(k) and nx = next.(k) in
      next.(p) <- k;
      if nx >= 0 then prev.(nx) <- k
    in
    let lift e = unlink e; unlink ret_of.(opi.(e)) in
    let unlift e = relink ret_of.(opi.(e)); relink e in
    let bits = Bytes.make ((n + 7) / 8) '\000' in
    let setb i =
      Bytes.set bits (i lsr 3)
        (Char.chr (Char.code (Bytes.get bits (i lsr 3)) lor (1 lsl (i land 7))))
    in
    let clearb i =
      Bytes.set bits (i lsr 3)
        (Char.chr (Char.code (Bytes.get bits (i lsr 3)) land lnot (1 lsl (i land 7))))
    in
    let cache = Hashtbl.create 4096 in
    let stack = ref [] and depth = ref 0 in
    let state = ref init_state in
    let entry = ref next.(head) in
    let steps = ref 0 in
    let best = ref (-1) and best_prefix = ref [] and best_stuck = ref 0 in
    let result = ref None in
    while !result = None do
      incr steps;
      if !steps > budget then result := Some (Gave_up !steps)
      else if next.(head) = -1 then
        result :=
          Some (Linearizable (List.rev_map (fun (e, _) -> ops.(opi.(e))) !stack))
      else begin
        let e = !entry in
        if is_call.(e) then begin
          let i = opi.(e) in
          let o = ops.(i) in
          let ns = step !state o.input o.output in
          let fresh =
            ns <> []
            && begin
                 setb i;
                 let key = (Bytes.to_string bits, ns) in
                 if Hashtbl.mem cache key then (clearb i; false)
                 else (Hashtbl.add cache key (); true)
               end
          in
          if fresh then begin
            stack := (e, !state) :: !stack;
            incr depth;
            state := ns;
            lift e;
            entry := next.(head)
          end
          else entry := next.(e)
        end
        else begin
          if !depth > !best then begin
            best := !depth;
            best_prefix := List.rev_map (fun (e, _) -> ops.(opi.(e))) !stack;
            best_stuck := opi.(e)
          end;
          match !stack with
          | [] ->
              let st =
                List.fold_left (fun s o -> step s o.input o.output) init_state !best_prefix
              in
              result :=
                Some (Violation { prefix = !best_prefix; states = st; stuck = ops.(!best_stuck) })
          | (ce, st) :: rest ->
              stack := rest;
              decr depth;
              state := st;
              clearb opi.(ce);
              unlift ce;
              entry := next.(ce)
        end
      end
    done;
    match !result with Some r -> r | None -> assert false
  end

(* Exhaustive reference checker used by the self-test: try every
   permutation that respects real-time order. Only viable for tiny inputs. *)
let brute (ops : op array) =
  let n = Array.length ops in
  let used = Array.make n false in
  let rec go k states =
    k = n
    || begin
         let ok = ref false in
         for i = 0 to n - 1 do
           if (not !ok) && not used.(i) then begin
             (* i may go next only if no unused op returned before i was called *)
             let minimal = ref true in
             for j = 0 to n - 1 do
               if (not used.(j)) && j <> i && ops.(j).ret < ops.(i).call then minimal := false
             done;
             if !minimal then begin
               let ns = step states ops.(i).input ops.(i).output in
               if ns <> [] then begin
                 used.(i) <- true;
                 if go (k + 1) ns then ok := true;
                 used.(i) <- false
               end
             end
           end
         done;
         !ok
       end
  in
  go 0 init_state
