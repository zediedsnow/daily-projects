(* quorum: Raft + nemesis + linearizability checker, all in one binary. *)

open Lin

type key_report = { key : int; nops : int; res : Lin.result; secs : float }

let analyze (o : Raft.outcome) =
  List.init o.cfg_used.keys (fun key ->
      let ops = Array.of_list (List.filter (fun (op : op) -> op.key = key) (Array.to_list o.history)) in
      let t0 = Sys.time () in
      let res = Lin.check ops in
      { key; nops = Array.length ops; res; secs = Sys.time () -. t0 })

let linearizable reps = List.for_all (fun r -> match r.res with Linearizable _ -> true | _ -> false) reps
let gave_up reps = List.exists (fun r -> match r.res with Gave_up _ -> true | _ -> false) reps

let fmt_time t = if t = max_int then "  never" else Printf.sprintf "%7d" t

let print_op prefix (op : op) =
  Printf.printf "%s#%-5d c%-2d [%s ..%s ms]  %-24s%s\n" prefix op.id op.client (fmt_time op.call)
    (fmt_time op.ret) (describe op) (if op.node >= 0 then Printf.sprintf "(answered by n%d)" op.node else "")

let states_str st = String.concat " or " (List.map string_of_int st)

let report (o : Raft.outcome) reps =
  let st = o.stats in
  let h = o.history in
  let count f = Array.fold_left (fun a op -> if f op then a + 1 else a) 0 h in
  Printf.printf "seed %d, bug: %s, %d nodes, %d clients, %d keys, %.1f s simulated\n" o.cfg_used.seed
    (Raft.string_of_bug o.cfg_used.bug) o.cfg_used.nodes o.cfg_used.clients o.cfg_used.keys
    (float o.end_time /. 1000.);
  Printf.printf "  events %d | messages %d sent, %d dropped, %d duplicated\n" st.events st.sent st.dropped
    st.duplicated;
  Printf.printf "  nemesis: %d partitions, %d crashes | %d elections, %d leaders elected\n" st.partitions
    st.crashes st.elections st.leaders;
  Printf.printf "  history: %d ops (%d reads, %d writes, %d cas) - %d ok, %d indeterminate\n" (Array.length h)
    (count (fun op -> op.input = Read))
    (count (fun op -> match op.input with Write _ -> true | _ -> false))
    (count (fun op -> match op.input with Cas _ -> true | _ -> false))
    (count (fun op -> not (indeterminate op)))
    (count indeterminate);
  Printf.printf "\nRaft invariants (checked online):\n";
  if o.safety = [] then
    Printf.printf "  election safety, log matching, leader completeness, state machine safety: OK\n"
  else begin
    List.iteri (fun i (t, s) -> if i < 6 then Printf.printf "  t=%dms  %s\n" t s) o.safety;
    let n = List.length o.safety in
    if n > 6 then Printf.printf "  ... and %d more\n" (n - 6)
  end;
  Printf.printf "\nLinearizability (Wing-Gong-Lowe search, per key):\n";
  List.iter
    (fun r ->
      match r.res with
      | Linearizable _ -> Printf.printf "  key %d: %4d ops  linearizable    (%.3fs)\n" r.key r.nops r.secs
      | Gave_up n -> Printf.printf "  key %d: %4d ops  UNKNOWN - search budget of %d steps exhausted\n" r.key r.nops n
      | Violation v ->
          Printf.printf "  key %d: %4d ops  NOT LINEARIZABLE (%.3fs)\n" r.key r.nops r.secs;
          let pre = v.prefix in
          let len = List.length pre in
          Printf.printf "    longest valid linearization covers %d ops; its last few:\n" len;
          List.iteri (fun i op -> if i >= len - 5 then print_op "      " op) pre;
          Printf.printf "    register is now %s, but this op had already returned and cannot be placed:\n"
            (states_str v.states);
          print_op "   >> " v.stuck)
    reps

(* --------------------------------------------------------------- selftest *)

let random_history rng =
  let n = Rng.range rng 1 7 in
  let ops =
    List.init n (fun i ->
        let call = Rng.int rng 20 in
        let info = Rng.chance rng 0.12 in
        let ret = if info then max_int else call + Rng.range rng 0 10 in
        let point = if info then call + Rng.int rng 30 else Rng.range rng call ret in
        let inp =
          match Rng.int rng 3 with
          | 0 -> Read
          | 1 -> Write (Rng.int rng 4)
          | _ -> Cas (Rng.int rng 4, Rng.int rng 4)
        in
        (point, i, call, ret, inp, info))
  in
  (* execute sequentially in linearization-point order to get honest outputs *)
  let sorted = List.sort compare ops in
  let reg = ref 0 in
  let res =
    List.map
      (fun (_, i, call, ret, inp, info) ->
        let out =
          match inp with
          | Read -> RVal !reg
          | Write v -> reg := v; WOk
          | Cas (a, b) -> if !reg = a then (reg := b; CasRes true) else CasRes false
        in
        let out = if info then Unknown else out in
        { id = i; client = i; key = 0; input = inp; output = out; call; ret; node = -1 })
      sorted
  in
  let arr = Array.of_list res in
  (* half the time, corrupt one observed result *)
  if Rng.chance rng 0.5 then begin
    let k = Rng.int rng n in
    let op = arr.(k) in
    let out =
      match op.output with
      | RVal v -> RVal ((v + 1 + Rng.int rng 3) mod 4)
      | CasRes b -> CasRes (not b)
      | o -> o
    in
    arr.(k) <- { op with output = out }
  end;
  arr

let selftest () =
  (* hand-written cases first *)
  let op id input output call ret = { id; client = id; key = 0; input; output; call; ret; node = -1 } in
  let cases =
    [
      ("sequential write/read", [| op 1 (Write 1) WOk 0 1; op 2 Read (RVal 1) 2 3 |], true);
      ("stale read after write", [| op 1 (Write 1) WOk 0 1; op 2 Read (RVal 0) 2 3 |], false);
      ("concurrent read sees either", [| op 1 (Write 1) WOk 0 10; op 2 Read (RVal 0) 2 3; op 3 Read (RVal 1) 4 5 |], true);
      ("new-old inversion", [| op 1 (Write 1) WOk 0 10; op 2 Read (RVal 1) 2 3; op 3 Read (RVal 0) 4 5 |], false);
      ("indeterminate write may land", [| op 1 (Write 7) Unknown 0 max_int; op 2 Read (RVal 7) 5 6 |], true);
      ("indeterminate write may not land", [| op 1 (Write 7) Unknown 0 max_int; op 2 Read (RVal 0) 5 6 |], true);
      ("cas success needs match", [| op 1 (Cas (0, 3)) (CasRes true) 0 1; op 2 (Cas (0, 4)) (CasRes true) 2 3 |], false);
      ( "indeterminate cas",
        [| op 1 (Write 1) WOk 0 1; op 2 (Cas (1, 2)) Unknown 2 max_int; op 3 Read (RVal 2) 9 9; op 4 Read (RVal 2) 10 11 |],
        true );
    ]
  in
  let fails = ref 0 in
  List.iter
    (fun (name, h, expect) ->
      let got = match Lin.check h with Linearizable _ -> true | _ -> false in
      let brute = Lin.brute h in
      let ok = got = expect && brute = expect in
      if not ok then incr fails;
      Printf.printf "  %-34s expect %-5b checker %-5b brute force %-5b %s\n" name expect got brute
        (if ok then "ok" else "FAIL"))
    cases;
  let rng = Rng.make 2026 in
  let trials = 50_000 in
  let lin = ref 0 and nonlin = ref 0 in
  for _ = 1 to trials do
    let h = random_history rng in
    let a = match Lin.check h with Linearizable _ -> true | _ -> false in
    let b = Lin.brute h in
    if a then incr lin else incr nonlin;
    if a <> b then begin
      incr fails;
      if !fails < 5 then begin
        Printf.printf "  MISMATCH checker=%b brute=%b\n" a b;
        Array.iter (print_op "    ") h
      end
    end
  done;
  Printf.printf "  %d random histories: %d linearizable, %d not; checker agrees with brute force on all but %d\n"
    trials !lin !nonlin !fails;
  if !fails > 0 then exit 1

(* ------------------------------------------------------------------ CLI *)

let usage () =
  print_string
    {|usage:
  quorum run   [--seed N] [--bug B] [--duration MS] [--no-buggify] [--trace] [--svg FILE]
  quorum sweep [--seeds N] [--from N] [--bug B|all] [--duration MS] [--no-buggify]
  quorum selftest
  quorum bugs
|};
  exit 2

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  let cmd, rest = match args with c :: r -> (c, r) | [] -> usage () in
  let cfg = ref Raft.default_config in
  let seeds = ref 100 and from = ref 1 and svg = ref None and all = ref false in
  let rec parse = function
    | "--seed" :: v :: r -> cfg := { !cfg with seed = int_of_string v }; parse r
    | "--seeds" :: v :: r -> seeds := int_of_string v; parse r
    | "--from" :: v :: r -> from := int_of_string v; parse r
    | "--duration" :: v :: r -> cfg := { !cfg with duration = int_of_string v }; parse r
    | "--no-buggify" :: r -> cfg := { !cfg with buggify = false }; parse r
    | "--trace" :: r -> cfg := { !cfg with trace = true }; parse r
    | "--svg" :: v :: r -> svg := Some v; parse r
    | "--bug" :: "all" :: r -> all := true; parse r
    | "--bug" :: v :: r -> (
        match Raft.bug_of_string v with
        | Some b -> cfg := { !cfg with bug = b }; parse r
        | None -> Printf.eprintf "unknown bug %s (try: quorum bugs)\n" v; exit 2)
    | [] -> ()
    | x :: _ -> Printf.eprintf "unknown argument %s\n" x; usage ()
  in
  parse rest;
  match cmd with
  | "run" ->
      let o = Raft.run !cfg in
      if !cfg.trace then print_newline ();
      let reps = analyze o in
      report o reps;
      (match !svg with
      | Some file ->
          let focus =
            List.find_map (fun r -> match r.res with Violation v -> Some (r.key, v) | _ -> None) reps
          in
          Viz.write file o focus;
          Printf.printf "\nwrote %s\n" file
      | None -> ());
      if not (linearizable reps && o.safety = []) then exit 1
  | "sweep" ->
      let bugs = if !all then Raft.No_bug :: Raft.all_bugs else [ !cfg.bug ] in
      Printf.printf "%-16s %6s %9s %14s %12s %8s  %s\n" "bug" "runs" "ops" "nonlinearizable" "raft-invariant" "cpu" "first failing seeds";
      List.iter
        (fun bug ->
          let t0 = Sys.time () in
          let nl = ref 0 and inv = ref 0 and ops = ref 0 and unk = ref 0 and failing = ref [] in
          for seed = !from to !from + !seeds - 1 do
            let o = Raft.run { !cfg with seed; bug } in
            let reps = analyze o in
            ops := !ops + Array.length o.history;
            let bad_lin = not (linearizable reps) && not (gave_up reps) in
            if gave_up reps then incr unk;
            if bad_lin then incr nl;
            if o.safety <> [] then incr inv;
            if (bad_lin || o.safety <> []) && List.length !failing < 5 then failing := seed :: !failing
          done;
          Printf.printf "%-16s %6d %9d %14d %12d %7.1fs  %s%s\n%!" (Raft.string_of_bug bug) !seeds !ops !nl !inv
            (Sys.time () -. t0)
            (String.concat " " (List.rev_map string_of_int !failing))
            (if !unk > 0 then Printf.sprintf " (%d inconclusive)" !unk else ""))
        bugs
  | "selftest" -> selftest ()
  | "bugs" ->
      List.iter
        (fun b -> Printf.printf "  %-16s %s\n" (Raft.string_of_bug b) (Raft.bug_doc b))
        (Raft.No_bug :: Raft.all_bugs)
  | _ -> usage ()
