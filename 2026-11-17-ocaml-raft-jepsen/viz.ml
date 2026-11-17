(* SVG report: the whole run's cluster timeline on top, and a zoomed-in
   history of the offending key around the linearizability violation. *)

open Lin

let esc s =
  let b = Buffer.create (String.length s) in
  String.iter
    (function
      | '<' -> Buffer.add_string b "&lt;"
      | '>' -> Buffer.add_string b "&gt;"
      | '&' -> Buffer.add_string b "&amp;"
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

let term_colors = [| "#4e79a7"; "#f28e2b"; "#59a14f"; "#b07aa1"; "#76b7b2"; "#edc948"; "#ff9da7"; "#9c755f" |]

let short_input = function
  | Read -> "r"
  | Write v -> Printf.sprintf "w %d" v
  | Cas (a, b) -> Printf.sprintf "cas %d→%d" a b

let short_output = function
  | RVal v -> Printf.sprintf " = %d" v
  | WOk -> ""
  | CasRes true -> " ✓"
  | CasRes false -> " ✗"
  | Unknown -> " ?"

let write file (o : Raft.outcome) (focus : (int * Lin.violation) option) =
  let b = Buffer.create 65536 in
  let p fmt = Printf.bprintf b fmt in
  let width = 1400 and left = 70 and right = 30 in
  let plot_w = width - left - right in
  let nn = o.cfg_used.nodes and nc = o.cfg_used.clients in
  let end_t = o.end_time in
  (* ------------------------------------------------ zoom window choice *)
  let key, w0, w1 =
    match focus with
    | Some (key, v) ->
        let st = v.stuck in
        let last_prefix =
          match List.rev v.prefix with x :: _ -> x.call | [] -> st.call
        in
        let lo = min st.call last_prefix - 250 in
        let hi = (if st.ret = max_int then st.call + 300 else st.ret) + 120 in
        (key, max 0 lo, hi)
    | None -> (0, o.cfg_used.duration / 2, (o.cfg_used.duration / 2) + 700)
  in
  let row_h = 22 in
  let top1 = 92 in
  let h1 = (nn + 1) * row_h in
  let top2 = top1 + h1 + 110 in
  let h2 = nc * 30 in
  let height = top2 + h2 + 90 in
  p {|<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="ui-monospace, Menlo, Consolas, monospace" font-size="12">
<rect width="100%%" height="100%%" fill="#fbfaf7"/>
<defs><pattern id="hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="6" height="6" fill="#e9d9d9"/><line x1="0" y1="0" x2="0" y2="6" stroke="#c0392b" stroke-width="2"/></pattern>
<linearGradient id="fade" x1="0" x2="1"><stop offset="0" stop-color="#999" stop-opacity="0.35"/><stop offset="1" stop-color="#999" stop-opacity="0"/></linearGradient></defs>
|}
    width height width height;
  let verdict =
    match focus with
    | Some (k, _) -> Printf.sprintf "NOT LINEARIZABLE (key %d)" k
    | None -> if o.safety = [] then "linearizable, all Raft invariants hold" else "Raft invariant violated"
  in
  p {|<text x="%d" y="30" font-size="18" font-weight="bold" fill="#222">quorum · seed %d · bug: %s · %s</text>
|}
    left o.cfg_used.seed (Raft.string_of_bug o.cfg_used.bug) (esc verdict);
  p {|<text x="%d" y="50" fill="#666">%d ops, %d elections, %d crashes, %d partitions, %d messages (%d dropped, %d duplicated)</text>
|}
    left (Array.length o.history) o.stats.elections o.stats.crashes o.stats.partitions o.stats.sent o.stats.dropped
    o.stats.duplicated;
  (* --------------------------------------------- panel 1: cluster state *)
  let x1 t = float left +. (float t *. float plot_w /. float end_t) in
  p {|<text x="%d" y="%d" font-weight="bold" fill="#333">cluster (whole run)</text>
|} left (top1 - 6);
  (* zoom window highlight *)
  p {|<rect x="%.1f" y="%d" width="%.1f" height="%d" fill="#ffe08a" opacity="0.45"/>
|}
    (x1 w0) top1 (max 2. (x1 w1 -. x1 w0)) h1;
  for i = 0 to nn - 1 do
    let y = top1 + (i * row_h) in
    p {|<text x="%d" y="%d" text-anchor="end" fill="#333">n%d</text>
|} (left - 8) (y + 15) i;
    p {|<rect x="%d" y="%d" width="%d" height="%d" fill="#e8e6e0"/>
|} left (y + 4) plot_w (row_h - 8);
    let evs = List.filter (fun (_, n, _) -> n = i) o.timeline in
    (* down intervals and leader intervals *)
    let down_since = ref None and lead_since = ref None in
    let close_lead t =
      match !lead_since with
      | Some (t0, term) ->
          let c = term_colors.(term mod Array.length term_colors) in
          p {|<rect x="%.1f" y="%d" width="%.1f" height="%d" fill="%s"><title>n%d leader of term %d, %d-%d ms</title></rect>
|}
            (x1 t0) (y + 2) (max 1.5 (x1 t -. x1 t0)) (row_h - 4) c i term t0 t;
          if x1 t -. x1 t0 > 26. then
            p {|<text x="%.1f" y="%d" fill="#fff" font-size="10">T%d</text>
|} (x1 t0 +. 3.) (y + 15) term;
          lead_since := None
      | None -> ()
    in
    let close_down t =
      match !down_since with
      | Some t0 ->
          p {|<rect x="%.1f" y="%d" width="%.1f" height="%d" fill="url(#hatch)"><title>n%d down %d-%d ms</title></rect>
|}
            (x1 t0) (y + 2) (max 1.5 (x1 t -. x1 t0)) (row_h - 4) i t0 t;
          down_since := None
      | None -> ()
    in
    List.iter
      (fun (t, _, e) ->
        match e with
        | Raft.Became_leader term -> close_lead t; lead_since := Some (t, term)
        | Raft.Lost_leadership -> close_lead t
        | Raft.Crashed -> close_lead t; down_since := Some t
        | Raft.Restarted -> close_down t)
      evs;
    close_lead end_t;
    close_down end_t
  done;
  (* network row *)
  let ny = top1 + (nn * row_h) in
  p {|<text x="%d" y="%d" text-anchor="end" fill="#333">net</text>
|} (left - 8) (ny + 15);
  let rec parts = function
    | (t0, name) :: ((t1, _) :: _ as rest) ->
        if name <> "healed" then
          p {|<rect x="%.1f" y="%d" width="%.1f" height="%d" fill="#e15759" opacity="0.55"><title>%d-%d ms: %s</title></rect>
|}
            (x1 t0) (ny + 4) (max 1.5 (x1 t1 -. x1 t0)) (row_h - 8) t0 t1 (esc name);
        parts rest
    | _ -> ()
  in
  parts o.partitions;
  (* time axis *)
  let axis y t0 t1 xf step =
    let t = ref ((t0 + step - 1) / step * step) in
    while !t <= t1 do
      p {|<line x1="%.1f" x2="%.1f" y1="%d" y2="%d" stroke="#aaa"/><text x="%.1f" y="%d" text-anchor="middle" fill="#888" font-size="10">%s</text>
|}
        (xf !t) (xf !t) y (y + 4) (xf !t) (y + 15)
        (if step >= 1000 then Printf.sprintf "%ds" (!t / 1000) else Printf.sprintf "%dms" !t);
      t := !t + step
    done
  in
  axis (ny + row_h) 0 end_t x1 1000;
  (* legend *)
  let ly = ny + row_h + 34 in
  p {|<rect x="%d" y="%d" width="14" height="10" fill="%s"/><text x="%d" y="%d" fill="#555">leader (colour = term)</text>
<rect x="%d" y="%d" width="14" height="10" fill="url(#hatch)"/><text x="%d" y="%d" fill="#555">crashed</text>
<rect x="%d" y="%d" width="14" height="10" fill="#e15759" opacity="0.55"/><text x="%d" y="%d" fill="#555">network partitioned (hover for topology)</text>
<rect x="%d" y="%d" width="14" height="10" fill="#ffe08a"/><text x="%d" y="%d" fill="#555">window shown below</text>
|}
    left ly term_colors.(0) (left + 20) (ly + 9)
    (left + 210) ly (left + 230) (ly + 9)
    (left + 320) ly (left + 340) (ly + 9)
    (left + 640) ly (left + 660) (ly + 9);
  (* -------------------------------------------- panel 2: key history *)
  let x2 t = float left +. (float (t - w0) *. float plot_w /. float (w1 - w0)) in
  let clampx t = max (float left) (min (float (left + plot_w)) (x2 t)) in
  p {|<text x="%d" y="%d" font-weight="bold" fill="#333">key %d, %d–%d ms: each bar is one client operation, from invocation to response</text>
|}
    left (top2 - 10) key w0 w1;
  for c = 0 to nc - 1 do
    let y = top2 + (c * 30) in
    p {|<text x="%d" y="%d" text-anchor="end" fill="#333">c%d</text><line x1="%d" x2="%d" y1="%d" y2="%d" stroke="#eee"/>
|}
      (left - 8) (y + 18) c left (left + plot_w) (y + 13) (y + 13)
  done;
  (* partitions/crashes as faint background in panel 2 *)
  let rec parts2 = function
    | (t0, name) :: ((t1, _) :: _ as rest) ->
        if name <> "healed" && t1 > w0 && t0 < w1 then
          p {|<rect x="%.1f" y="%d" width="%.1f" height="%d" fill="#e15759" opacity="0.07"/><text x="%.1f" y="%d" fill="#c0392b" font-size="10">%s</text>
|}
            (clampx t0) top2 (clampx t1 -. clampx t0) h2 (clampx t0 +. 3.) (top2 + h2 + 14) (esc name);
        parts2 rest
    | _ -> ()
  in
  parts2 o.partitions;
  let order = Hashtbl.create 16 in
  let stuck_id = match focus with Some (_, v) -> v.stuck.id | None -> -1 in
  (match focus with
  | Some (_, v) ->
      let n = List.length v.prefix in
      List.iteri (fun i op -> if i >= n - 6 then Hashtbl.replace order op.id (i - n + 7)) v.prefix
  | None -> ());
  Array.iter
    (fun (op : op) ->
      let ret = if op.ret = max_int then w1 + 1000 else op.ret in
      if op.key = key && ret >= w0 && op.call <= w1 then begin
        let y = top2 + (op.client * 30) + 3 in
        let xa = clampx op.call and xb = clampx ret in
        let w = max 3. (xb -. xa) in
        let fill =
          match op.input with Read -> "#4e79a7" | Write _ -> "#59a14f" | Cas _ -> "#b07aa1"
        in
        let is_stuck = op.id = stuck_id in
        if op.ret = max_int then
          p {|<rect x="%.1f" y="%d" width="%.1f" height="20" rx="3" fill="url(#fade)" stroke="%s" stroke-dasharray="4 3"><title>#%d %s (indeterminate: client timed out)</title></rect>
|}
            xa y w fill op.id (esc (describe op))
        else
          p {|<rect x="%.1f" y="%d" width="%.1f" height="20" rx="3" fill="%s" fill-opacity="%s" stroke="%s" stroke-width="%s"><title>#%d %s, %d-%d ms</title></rect>
|}
            xa y w fill (if is_stuck then "1" else "0.8") (if is_stuck then "#d62728" else "none")
            (if is_stuck then "3" else "0") op.id (esc (describe op)) op.call op.ret;
        let label =
          short_input op.input ^ short_output op.output
          ^ if op.node >= 0 && (is_stuck || w > 120.) then Printf.sprintf "  via n%d" op.node else ""
        in
        let fits = float (String.length label) *. 7.2 +. 8. < w in
        if fits || op.ret = max_int then
          p {|<text x="%.1f" y="%d" fill="%s" font-size="11">%s</text>
|}
            (xa +. 4.) (y + 14) (if op.ret = max_int then "#555" else "#fff") (esc label)
        else
          p {|<text x="%.1f" y="%d" fill="#444" font-size="11">%s</text>
|} (xb +. 4.) (y + 14) (esc label);
        (match Hashtbl.find_opt order op.id with
        | Some k ->
            p {|<circle cx="%.1f" cy="%d" r="8" fill="#fff" stroke="#333"/><text x="%.1f" y="%d" text-anchor="middle" font-size="9" fill="#333">%d</text>
|}
              (xa -. 1.) (y - 1) (xa -. 1.) (y + 2) k
        | None -> ());
        if is_stuck then
          p {|<circle cx="%.1f" cy="%d" r="9" fill="#d62728"/><text x="%.1f" y="%d" text-anchor="middle" fill="#fff" font-weight="bold" font-size="12">✗</text>
|}
            (xa -. 13.) (y + 10) (xa -. 13.) (y + 14)
      end)
    o.history;
  axis (top2 + h2 + 20) w0 w1 x2 (if w1 - w0 > 1500 then 200 else if w1 - w0 > 600 then 100 else 50);
  (match focus with
  | Some (_, v) ->
      p {|<text x="%d" y="%d" fill="#333">Circles 1-6: the last steps of the longest valid linearization found (%d ops). After it the register holds %s, yet op #%d (red ✗) had already returned %s.</text>
|}
        left (height - 18) (List.length v.prefix)
        (String.concat " or " (List.map string_of_int v.states))
        v.stuck.id (esc (describe v.stuck))
  | None -> ());
  p "</svg>\n";
  let oc = open_out file in
  Buffer.output_buffer oc b;
  close_out oc
