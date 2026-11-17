(* A Raft cluster running a replicated key/value register store inside a
   deterministic discrete-event simulator, with a Jepsen-style nemesis.

   Everything non-deterministic (message delays, drops, duplication,
   partitions, crashes, election timeouts, client behaviour) is drawn from
   one seeded PRNG, so any run - including any bug it finds - can be
   replayed exactly from its seed. *)

open Lin

type bug =
  | No_bug
  | Stale_reads (* leader answers reads from local state, skipping the log *)
  | Forget_vote (* votedFor is not persisted across a crash *)
  | Eager_truncate (* follower truncates its log on every AppendEntries *)
  | Commit_old_term (* leader commits old-term entries by counting replicas (Raft fig. 8) *)

let all_bugs = [ Stale_reads; Forget_vote; Eager_truncate; Commit_old_term ]

let string_of_bug = function
  | No_bug -> "none"
  | Stale_reads -> "stale-reads"
  | Forget_vote -> "forget-vote"
  | Eager_truncate -> "eager-truncate"
  | Commit_old_term -> "commit-old-term"

let bug_of_string s =
  List.find_opt (fun b -> string_of_bug b = s) (No_bug :: all_bugs)

let bug_doc = function
  | No_bug -> "correct Raft"
  | Stale_reads -> "leader serves reads locally without confirming it is still leader"
  | Forget_vote -> "votedFor kept in memory only, so a restarted node can vote twice in a term"
  | Eager_truncate -> "follower drops everything after prevLogIndex even when entries match"
  | Commit_old_term -> "no election no-op, and old-term entries commit by replica count (Figure 8)"

type cmd = { cid : int; client : int; key : int; inp : input }
type entry = { term : int; cmd : cmd option }

type msg =
  | RequestVote of { term : int; cand : int; last_idx : int; last_term : int }
  | Vote of { term : int; from : int; granted : bool }
  | Append of {
      term : int;
      leader : int;
      prev_idx : int;
      prev_term : int;
      entries : entry list;
      commit : int;
    }
  | AppendResp of { term : int; from : int; success : bool; idx : int }
  | ClientReq of cmd
  | ClientResp of { cid : int; out : output option; hint : int }

type role = Follower | Candidate | Leader

type node = {
  id : int;
  mutable up : bool;
  (* persistent state *)
  mutable term : int;
  mutable voted_for : int;
  mutable log : entry array; (* 1-based; log.(0) is a term-0 sentinel *)
  mutable len : int;
  (* volatile state *)
  mutable role : role;
  mutable commit : int;
  mutable applied : int;
  kv : (int, int) Hashtbl.t;
  sessions : (int, int * output) Hashtbl.t; (* client -> last cid, its result *)
  mutable votes : int list;
  next_idx : int array;
  match_idx : int array;
  mutable egen : int;
  mutable hint : int;
  pending : (int, int) Hashtbl.t; (* log index -> cid awaiting a reply *)
}

type client = {
  cl : int;
  mutable cur : (int * int * input) option; (* cid, key, input *)
  mutable call_t : int;
  mutable target : int;
  mutable attempt : int;
  last_seen : int array;
}

type ev =
  | Deliver of int * int * msg (* dst, src, message *)
  | ElectionTimer of int * int
  | Heartbeat of int * int
  | ClientNext of int
  | ClientAttempt of int * int * int (* client, cid, attempt *)
  | ClientTimeout of int * int
  | Nemesis
  | Restart of int
  | Kill of int * int (* node, downtime: a "buggify" fault aimed at a fragile moment *)
  | Finale

type config = {
  seed : int;
  bug : bug;
  nodes : int;
  clients : int;
  keys : int;
  duration : int; (* ms of simulated time with traffic + faults *)
  drop : float;
  dup : float;
  trace : bool;
  buggify : bool;
}

let default_config =
  {
    seed = 1;
    bug = No_bug;
    nodes = 5;
    clients = 8;
    keys = 3;
    duration = 10_000;
    drop = 0.03;
    dup = 0.02;
    trace = false;
    buggify = true;
  }

type stats = {
  mutable sent : int;
  mutable dropped : int;
  mutable duplicated : int;
  mutable events : int;
  mutable elections : int;
  mutable leaders : int;
  mutable crashes : int;
  mutable partitions : int;
  mutable ok : int;
  mutable info : int;
}

(* things the visualiser wants to know about *)
type tl_event = Became_leader of int | Lost_leadership | Crashed | Restarted

type sim = {
  cfg : config;
  rng : Rng.t;
  q : ev Pq.t;
  mutable now : int;
  nodes : node array;
  clients : client array;
  link : bool array array; (* link.(i).(j): can node i talk to node j *)
  mutable history : op list;
  mutable next_cid : int;
  mutable next_val : int;
  mutable safety : (int * string) list;
  leader_of_term : (int, int) Hashtbl.t;
  committed : (int, int * int * int) Hashtbl.t;
      (* log index -> entry term, cid, and the term in which it was first applied *)
  stats : stats;
  mutable timeline : (int * int * tl_event) list;
  mutable partition_log : (int * string) list;
}

let majority s = (Array.length s.nodes / 2) + 1
let trace s fmt = Printf.ksprintf (fun str -> if s.cfg.trace then Printf.printf "%6d  %s\n" s.now str) fmt

let violation s fmt =
  Printf.ksprintf
    (fun str ->
      trace s "SAFETY VIOLATION: %s" str;
      if not (List.exists (fun (_, x) -> x = str) s.safety) then s.safety <- (s.now, str) :: s.safety)
    fmt

let at s delay ev = Pq.push s.q (s.now + delay) ev

(* ---------------------------------------------------------------- network *)

let send s ~src ~dst m =
  s.stats.sent <- s.stats.sent + 1;
  let delay () = if Rng.chance s.rng 0.05 then Rng.range s.rng 20 120 else Rng.range s.rng 1 12 in
  if Rng.chance s.rng s.cfg.drop then s.stats.dropped <- s.stats.dropped + 1
  else begin
    at s (delay ()) (Deliver (dst, src, m));
    if Rng.chance s.rng s.cfg.dup then begin
      s.stats.duplicated <- s.stats.duplicated + 1;
      at s (delay ()) (Deliver (dst, src, m))
    end
  end

let is_node s a = a < Array.length s.nodes

(* ------------------------------------------------------------------ raft *)

let last_term n = n.log.(n.len).term

let append_entry n e =
  if n.len + 1 >= Array.length n.log then begin
    let b = Array.make (2 * Array.length n.log) { term = 0; cmd = None } in
    Array.blit n.log 0 b 0 (n.len + 1);
    n.log <- b
  end;
  n.len <- n.len + 1;
  n.log.(n.len) <- e

let reset_election s n =
  n.egen <- n.egen + 1;
  at s (Rng.range s.rng 150 300) (ElectionTimer (n.id, n.egen))

let set_term n t =
  if t > n.term then begin
    n.term <- t;
    n.voted_for <- -1
  end

let become_follower s n t =
  set_term n t;
  if n.role = Leader then begin
    trace s "n%d steps down (term %d)" n.id n.term;
    s.timeline <- (s.now, n.id, Lost_leadership) :: s.timeline;
    Hashtbl.reset n.pending
  end;
  n.role <- Follower

let send_append s n p =
  let ni = max 1 (min n.next_idx.(p) (n.len + 1)) in
  let prev_idx = ni - 1 in
  let hi = min n.len (prev_idx + 32) in
  let entries = List.init (hi - prev_idx) (fun i -> n.log.(prev_idx + 1 + i)) in
  send s ~src:n.id ~dst:p
    (Append
       { term = n.term; leader = n.id; prev_idx; prev_term = n.log.(prev_idx).term; entries; commit = n.commit })

let broadcast_append s n =
  Array.iter (fun p -> if p.id <> n.id then send_append s n p.id) s.nodes

let cid_of e = match e.cmd with None -> -1 | Some c -> c.cid

let apply s n =
  while n.applied < min n.commit n.len do
    n.applied <- n.applied + 1;
    let e = n.log.(n.applied) in
    (match Hashtbl.find_opt s.committed n.applied with
    | None -> Hashtbl.add s.committed n.applied (e.term, cid_of e, n.term)
    | Some (t, c, _) ->
        if t <> e.term || c <> cid_of e then
          violation s "state machine safety: n%d applied a different entry at index %d" n.id n.applied);
    match e.cmd with
    | None -> ()
    | Some c ->
        let out =
          match Hashtbl.find_opt n.sessions c.client with
          | Some (last, o) when c.cid <= last -> if c.cid = last then o else Unknown
          | _ ->
              let cur = Option.value (Hashtbl.find_opt n.kv c.key) ~default:0 in
              let o =
                match c.inp with
                | Read -> RVal cur
                | Write v -> Hashtbl.replace n.kv c.key v; WOk
                | Cas (a, b) ->
                    if cur = a then (Hashtbl.replace n.kv c.key b; CasRes true) else CasRes false
              in
              Hashtbl.replace n.sessions c.client (c.cid, o);
              o
        in
        if n.role = Leader then
          match Hashtbl.find_opt n.pending n.applied with
          | Some cid when cid = c.cid ->
              Hashtbl.remove n.pending n.applied;
              send s ~src:n.id ~dst:(Array.length s.nodes + c.client)
                (ClientResp { cid; out = Some out; hint = n.id })
          | _ -> ()
  done

let advance_commit s n =
  let rec go idx =
    if idx > n.commit then begin
      let cnt = ref 0 in
      Array.iter (fun p -> if p.id = n.id || n.match_idx.(p.id) >= idx then incr cnt) s.nodes;
      if !cnt >= majority s && (s.cfg.bug = Commit_old_term || n.log.(idx).term = n.term) then
        n.commit <- idx
      else go (idx - 1)
    end
  in
  go n.len;
  apply s n

let become_leader s n =
  n.role <- Leader;
  n.hint <- n.id;
  s.stats.leaders <- s.stats.leaders + 1;
  trace s "n%d becomes LEADER for term %d (log %d, commit %d)" n.id n.term n.len n.commit;
  s.timeline <- (s.now, n.id, Became_leader n.term) :: s.timeline;
  (match Hashtbl.find_opt s.leader_of_term n.term with
  | Some other when other <> n.id ->
      violation s "election safety: n%d and n%d are both leader of term %d" other n.id n.term
  | _ -> Hashtbl.replace s.leader_of_term n.term n.id);
  let missing = ref None in
  Hashtbl.iter
    (fun idx (t, _, ct) ->
      if ct < n.term && (idx > n.len || n.log.(idx).term <> t) && (!missing = None || Some idx < !missing) then
        missing := Some idx)
    s.committed;
  (match !missing with
  | Some idx ->
      violation s "leader completeness: n%d elected in term %d without entry %d committed earlier" n.id n.term idx
  | None -> ());
  (* buggify: sometimes kill a brand-new leader before it has finished
     its first round of replication *)
  if s.cfg.buggify && s.now < s.cfg.duration && Rng.chance s.rng 0.1 then
    at s (Rng.range s.rng 0 15) (Kill (n.id, Rng.range s.rng 1 400));
  Array.fill n.next_idx 0 (Array.length n.next_idx) (n.len + 1);
  Array.fill n.match_idx 0 (Array.length n.match_idx) 0;
  (* The no-op entry lets a new leader commit earlier-term entries safely.
     The commit-old-term bug models an implementation without it, which
     is exactly the situation Figure 8 of the Raft paper warns about. *)
  if s.cfg.bug <> Commit_old_term then append_entry n { term = n.term; cmd = None };
  broadcast_append s n;
  at s 50 (Heartbeat (n.id, n.term))

let start_election s n =
  n.term <- n.term + 1;
  n.voted_for <- n.id;
  n.role <- Candidate;
  n.votes <- [ n.id ];
  s.stats.elections <- s.stats.elections + 1;
  trace s "n%d starts election for term %d" n.id n.term;
  reset_election s n;
  Array.iter
    (fun p ->
      if p.id <> n.id then
        send s ~src:n.id ~dst:p.id
          (RequestVote { term = n.term; cand = n.id; last_idx = n.len; last_term = last_term n }))
    s.nodes

let handle_node s n src m =
  match m with
  | RequestVote r ->
      if r.term > n.term then become_follower s n r.term;
      let up_to_date = r.last_term > last_term n || (r.last_term = last_term n && r.last_idx >= n.len) in
      let granted = r.term = n.term && (n.voted_for = -1 || n.voted_for = r.cand) && up_to_date in
      if granted then begin
        n.voted_for <- r.cand;
        trace s "n%d votes for n%d in term %d (my log %d/%d, cand %d/%d)" n.id r.cand n.term n.len (last_term n) r.last_idx r.last_term;
        reset_election s n;
        (* buggify: sometimes bounce a node right after it votes *)
        if s.cfg.buggify && s.now < s.cfg.duration && Rng.chance s.rng 0.2 then
          at s (Rng.range s.rng 0 5) (Kill (n.id, Rng.range s.rng 1 20))
      end;
      send s ~src:n.id ~dst:src (Vote { term = n.term; from = n.id; granted })
  | Vote v ->
      if v.term > n.term then become_follower s n v.term
      else if n.role = Candidate && v.term = n.term && v.granted && not (List.mem v.from n.votes) then begin
        n.votes <- v.from :: n.votes;
        if List.length n.votes >= majority s then become_leader s n
      end
  | Append a ->
      let reply success idx =
        send s ~src:n.id ~dst:src (AppendResp { term = n.term; from = n.id; success; idx })
      in
      if a.term < n.term then reply false 0
      else begin
        set_term n a.term;
        if n.role <> Follower then become_follower s n a.term;
        n.hint <- a.leader;
        reset_election s n;
        if a.prev_idx > n.len then reply false n.len
        else if n.log.(a.prev_idx).term <> a.prev_term then begin
          (* skip back over the whole conflicting term in one round trip *)
          let t = n.log.(a.prev_idx).term in
          let i = ref a.prev_idx in
          while !i > 1 && n.log.(!i - 1).term = t do decr i done;
          reply false (!i - 1)
        end
        else begin
          if s.cfg.bug = Eager_truncate then n.len <- a.prev_idx;
          let idx = ref a.prev_idx in
          List.iter
            (fun (e : entry) ->
              incr idx;
              if !idx <= n.len && n.log.(!idx).term <> e.term then n.len <- !idx - 1;
              if !idx > n.len then append_entry n e)
            a.entries;
          let last_new = a.prev_idx + List.length a.entries in
          n.commit <- max n.commit (min a.commit last_new);
          reply true last_new;
          apply s n
        end
      end
  | AppendResp r ->
      if r.term > n.term then become_follower s n r.term
      else if n.role = Leader && r.term = n.term then begin
        if r.success then begin
          if r.idx > n.match_idx.(r.from) then n.match_idx.(r.from) <- r.idx;
          n.next_idx.(r.from) <- max n.next_idx.(r.from) (r.idx + 1);
          advance_commit s n
        end
        else begin
          n.next_idx.(r.from) <- max 1 (min n.next_idx.(r.from) (r.idx + 1));
          send_append s n r.from
        end
      end
  | ClientReq c ->
      let reply out hint =
        send s ~src:n.id ~dst:(Array.length s.nodes + c.client) (ClientResp { cid = c.cid; out; hint })
      in
      if n.role <> Leader then reply None n.hint
      else if s.cfg.bug = Stale_reads && c.inp = Read then
        reply (Some (RVal (Option.value (Hashtbl.find_opt n.kv c.key) ~default:0))) n.id
      else if not (Hashtbl.fold (fun _ cid acc -> acc || cid = c.cid) n.pending false) then begin
        append_entry n { term = n.term; cmd = Some c };
        Hashtbl.replace n.pending n.len c.cid;
        broadcast_append s n
      end
  | ClientResp _ -> ()

(* --------------------------------------------------------------- clients *)

let attempt_timeout = 150
let op_timeout = 1000

let client_send s c =
  match c.cur with
  | None -> ()
  | Some (cid, key, inp) ->
      c.attempt <- c.attempt + 1;
      send s ~src:(Array.length s.nodes + c.cl) ~dst:c.target (ClientReq { cid; client = c.cl; key; inp });
      at s attempt_timeout (ClientAttempt (c.cl, cid, c.attempt))

let client_next s c =
  if s.now < s.cfg.duration then begin
    let cid = s.next_cid in
    s.next_cid <- cid + 1;
    let key = Rng.int s.rng s.cfg.keys in
    let fresh () = s.next_val <- s.next_val + 1; s.next_val in
    let r = Rng.int s.rng 100 in
    let inp =
      if r < 45 then Read else if r < 75 then Write (fresh ()) else Cas (c.last_seen.(key), fresh ())
    in
    c.cur <- Some (cid, key, inp);
    c.call_t <- s.now;
    c.attempt <- 0;
    client_send s c;
    at s op_timeout (ClientTimeout (c.cl, cid))
  end

let finish_op s c output ret node =
  match c.cur with
  | None -> ()
  | Some (cid, key, input) ->
      if not (output = Unknown && input = Read) then
        s.history <- { id = cid; client = c.cl; key; input; output; call = c.call_t; ret; node } :: s.history;
      (match (input, output) with
      | _, RVal v -> c.last_seen.(key) <- v
      | Write v, WOk -> c.last_seen.(key) <- v
      | Cas (_, v), CasRes true -> c.last_seen.(key) <- v
      | _ -> ());
      c.cur <- None;
      at s (Rng.range s.rng 0 15) (ClientNext c.cl)

let handle_client s c m =
  match (m, c.cur) with
  | ClientResp r, Some (cid, _, _) when r.cid = cid -> (
      match r.out with
      | Some o ->
          s.stats.ok <- s.stats.ok + 1;
          finish_op s c o s.now r.hint
      | None ->
          c.target <- (if r.hint >= 0 && r.hint <> c.target then r.hint else Rng.int s.rng (Array.length s.nodes));
          client_send s c)
  | _ -> ()

(* --------------------------------------------------------------- nemesis *)

let crash s n =
  if n.role = Leader then s.timeline <- (s.now, n.id, Lost_leadership) :: s.timeline;
  n.up <- false;
  s.stats.crashes <- s.stats.crashes + 1;
  s.timeline <- (s.now, n.id, Crashed) :: s.timeline

let set_links s name f =
  let nn = Array.length s.nodes in
  for i = 0 to nn - 1 do
    for j = 0 to nn - 1 do
      s.link.(i).(j) <- i = j || f i j
    done
  done;
  if name <> "healed" then s.stats.partitions <- s.stats.partitions + 1;
  trace s "nemesis: %s" name;
  s.partition_log <- (s.now, name) :: s.partition_log

let shuffled s =
  let perm = Array.init (Array.length s.nodes) Fun.id in
  for i = Array.length perm - 1 downto 1 do
    let j = Rng.int s.rng (i + 1) in
    let t = perm.(i) in
    perm.(i) <- perm.(j);
    perm.(j) <- t
  done;
  perm

let names l = String.concat "," (List.map (Printf.sprintf "n%d") l)

let bounce s n =
  if n.up then begin
    crash s n;
    trace s "nemesis: bounce n%d" n.id;
    at s (Rng.range s.rng 1 40) (Restart n.id)
  end

let nemesis s =
  let nn = Array.length s.nodes in
  let down = Array.fold_left (fun a n -> if n.up then a else a + 1) 0 s.nodes in
  let r = Rng.int s.rng 100 in
  if r < 25 then set_links s "healed" (fun _ _ -> true)
  else if r < 40 then begin
    (* two halves *)
    let perm = shuffled s in
    let cut = Rng.range s.rng 1 (nn - 1) in
    let side = Array.make nn 0 in
    Array.iteri (fun i p -> side.(p) <- (if i < cut then 1 else 0)) perm;
    let a = List.filter (fun i -> side.(i) = 1) (List.init nn Fun.id) in
    let b = List.filter (fun i -> side.(i) = 0) (List.init nn Fun.id) in
    set_links s (Printf.sprintf "partition %s | %s" (names a) (names b)) (fun i j -> side.(i) = side.(j))
  end
  else if r < 50 then begin
    let leaders = Array.to_list s.nodes |> List.filter (fun n -> n.role = Leader && n.up) |> List.map (fun n -> n.id) in
    if leaders <> [] then
      set_links s ("isolate leader " ^ names leaders) (fun i j -> List.mem i leaders = List.mem j leaders)
  end
  else if r < 58 then begin
    (* bridge: two halves that can both see one node in the middle *)
    let perm = shuffled s in
    let mid = perm.(0) in
    let side = Array.make nn 0 in
    Array.iteri (fun i p -> if i > 0 then side.(p) <- (if i mod 2 = 0 then 1 else 2)) perm;
    let grp g = List.filter (fun i -> side.(i) = g) (List.init nn Fun.id) in
    set_links s (Printf.sprintf "bridge %s <-> n%d <-> %s" (names (grp 1)) mid (names (grp 2)))
      (fun i j -> side.(i) = side.(j) || i = mid || j = mid)
  end
  else if r < 64 then begin
    (* majorities ring: everyone sees a majority, but no two see the same one *)
    let perm = shuffled s in
    let pos = Array.make nn 0 in
    Array.iteri (fun i p -> pos.(p) <- i) perm;
    set_links s
      (Printf.sprintf "majorities ring %s" (names (Array.to_list perm)))
      (fun i j ->
        let d = abs (pos.(i) - pos.(j)) in
        min d (nn - d) <= majority s / 2)
  end
  else if r < 80 && down < 2 then begin
    let ups = Array.to_list s.nodes |> List.filter (fun n -> n.up) in
    (* prefer killing a leader: that is where the interesting bugs live *)
    let leaders = List.filter (fun n -> n.role = Leader) ups in
    let pool = if leaders <> [] && Rng.chance s.rng 0.6 then leaders else ups in
    let n = List.nth pool (Rng.int s.rng (List.length pool)) in
    crash s n;
    trace s "nemesis: crash n%d" n.id;
    at s (Rng.range s.rng 50 900) (Restart n.id)
  end
  else if r >= 80 then
    (* kill -9 and immediately restart: loses all volatile state while the
       rest of the cluster barely notices *)
    for _ = 1 to Rng.range s.rng 1 2 do
      bounce s s.nodes.(Rng.int s.rng nn)
    done;
  if s.now < s.cfg.duration then at s (Rng.range s.rng 200 800) Nemesis

let restart s n =
  if not n.up then begin
    n.up <- true;
    n.role <- Follower;
    n.commit <- 0;
    n.applied <- 0;
    Hashtbl.reset n.kv;
    Hashtbl.reset n.sessions;
    Hashtbl.reset n.pending;
    n.votes <- [];
    if s.cfg.bug = Forget_vote then n.voted_for <- -1;
    s.timeline <- (s.now, n.id, Restarted) :: s.timeline;
    trace s "n%d restarts (term %d, log %d)" n.id n.term n.len;
    reset_election s n
  end

(* ------------------------------------------------------------------- run *)

type outcome = {
  cfg_used : config;
  history : op array;
  safety : (int * string) list;
  stats : stats;
  timeline : (int * int * tl_event) list;
  partitions : (int * string) list;
  end_time : int;
}

let run (cfg : config) =
  let nn = cfg.nodes in
  let mk_node id =
    {
      id;
      up = true;
      term = 0;
      voted_for = -1;
      log = Array.make 256 { term = 0; cmd = None };
      len = 0;
      role = Follower;
      commit = 0;
      applied = 0;
      kv = Hashtbl.create 8;
      sessions = Hashtbl.create 8;
      votes = [];
      next_idx = Array.make nn 1;
      match_idx = Array.make nn 0;
      egen = 0;
      hint = -1;
      pending = Hashtbl.create 8;
    }
  in
  let rng = Rng.make cfg.seed in
  let s =
    {
      cfg;
      rng;
      q = Pq.create ();
      now = 0;
      nodes = Array.init nn mk_node;
      clients =
        Array.init cfg.clients (fun cl ->
            { cl; cur = None; call_t = 0; target = Rng.int rng nn; attempt = 0; last_seen = Array.make cfg.keys 0 });
      link = Array.make_matrix nn nn true;
      history = [];
      next_cid = 1;
      next_val = 0;
      safety = [];
      leader_of_term = Hashtbl.create 64;
      committed = Hashtbl.create 4096;
      stats =
        { sent = 0; dropped = 0; duplicated = 0; events = 0; elections = 0; leaders = 0; crashes = 0; partitions = 0; ok = 0; info = 0 };
      timeline = [];
      partition_log = [ (0, "healed") ];
    }
  in
  Array.iter (reset_election s) s.nodes;
  Array.iter (fun c -> at s (Rng.range s.rng 300 400) (ClientNext c.cl)) s.clients;
  at s 1000 Nemesis;
  at s cfg.duration Finale;
  let stop = cfg.duration + 3000 in
  let running = ref true in
  while !running do
    match Pq.pop s.q with
    | None -> running := false
    | Some (t, _) when t > stop -> running := false
    | Some (t, ev) -> (
        s.now <- t;
        s.stats.events <- s.stats.events + 1;
        match ev with
        | Deliver (dst, src, m) ->
            if is_node s dst then begin
              let n = s.nodes.(dst) in
              let cut = is_node s src && not s.link.(src).(dst) in
              if n.up && not cut then handle_node s n src m
            end
            else handle_client s s.clients.(dst - nn) m
        | ElectionTimer (id, gen) ->
            let n = s.nodes.(id) in
            if n.up && gen = n.egen then if n.role = Leader then reset_election s n else start_election s n
        | Heartbeat (id, term) ->
            let n = s.nodes.(id) in
            if n.up && n.role = Leader && n.term = term then begin
              broadcast_append s n;
              at s 50 (Heartbeat (id, term))
            end
        | ClientNext cl -> client_next s s.clients.(cl)
        | ClientAttempt (cl, cid, a) -> (
            let c = s.clients.(cl) in
            match c.cur with
            | Some (cid', _, _) when cid' = cid && a = c.attempt ->
                c.target <- Rng.int s.rng nn;
                client_send s c
            | _ -> ())
        | ClientTimeout (cl, cid) -> (
            let c = s.clients.(cl) in
            match c.cur with
            | Some (cid', _, _) when cid' = cid ->
                s.stats.info <- s.stats.info + 1;
                finish_op s c Unknown max_int (-1)
            | _ -> ())
        | Nemesis -> if s.now < cfg.duration then nemesis s
        | Restart id -> restart s s.nodes.(id)
        | Kill (id, downtime) ->
            let n = s.nodes.(id) in
            if n.up then begin
              crash s n;
              trace s "buggify: kill n%d for %dms" id downtime;
              at s downtime (Restart id)
            end
        | Finale ->
            trace s "finale: heal network, restart everyone, let the cluster settle";
            set_links s "healed" (fun _ _ -> true);
            Array.iter (restart s) s.nodes)
  done;
  (* operations still in flight when we stop are indeterminate *)
  Array.iter
    (fun c ->
      if c.cur <> None then begin
        s.stats.info <- s.stats.info + 1;
        finish_op s c Unknown max_int (-1)
      end)
    s.clients;
  {
    cfg_used = cfg;
    history = Array.of_list (List.rev s.history);
    safety = List.rev s.safety;
    stats = s.stats;
    timeline = List.rev s.timeline;
    partitions = List.rev s.partition_log;
    end_time = s.now;
  }
