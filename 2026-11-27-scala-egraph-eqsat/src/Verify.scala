package saturn

import scala.collection.mutable
import scala.util.Random

object Gen:
  val Vars3 = Vector("a", "b", "c")

  def leaf(r: Random, vars: IndexedSeq[String], consts: Boolean): Term =
    if consts && r.nextInt(3) == 0 then Term.num(r.nextInt(13) - 3) else Term.v(vars(r.nextInt(vars.length)))

  /** Random term over the full language (exponents and shift amounts are small literals). */
  def term(r: Random, depth: Int, vars: IndexedSeq[String] = Vars3, consts: Boolean = true): Term =
    if depth <= 0 || r.nextInt(5) == 0 then leaf(r, vars, consts)
    else
      def sub() = term(r, depth - 1, vars, consts)
      r.nextInt(11) match
        case 0 | 1 | 2 => Term(Op.Add, sub(), sub())
        case 3 | 4     => Term(Op.Sub, sub(), sub())
        case 5 | 6     => Term(Op.Mul, sub(), sub())
        case 7         => Term(Op.Neg, sub())
        case 8         => Term(Op.Shl, sub(), Term.num(r.nextInt(4)))
        case 9         => Term(Op.Pow, term(r, depth - 2, vars, consts), Term.num(r.nextInt(4)))
        case _         => Term(Op.Add, sub(), sub())

  /** Ground terms over + * neg with variables only (no analysis effects) for the CC oracle. */
  def ground(r: Random, depth: Int): Term =
    if depth <= 0 || r.nextInt(4) == 0 then Term.v(Vars3(r.nextInt(3)))
    else r.nextInt(5) match
      case 0 | 1 => Term(Op.Add, ground(r, depth - 1), ground(r, depth - 1))
      case 2 | 3 => Term(Op.Mul, ground(r, depth - 1), ground(r, depth - 1))
      case _     => Term(Op.Neg, ground(r, depth - 1))

  def env(r: Random, vars: Iterable[String], range: Int = 60): Map[String, BigInt] =
    vars.map(v => v -> BigInt(r.nextInt(2 * range + 1) - range)).toMap

  /** Semantics-preserving bloat: the "obfuscator" used by the optimisation benchmark. */
  def obfuscate(r: Random, t: Term, steps: Int): Term =
    def once(t: Term): Term =
      // pick a random position: descend with probability proportional to size
      if t.kids.nonEmpty && r.nextInt(t.size) != 0 then
        val i = r.nextInt(t.kids.length)
        Term(t.op, t.kids.updated(i, once(t.kids(i))))
      else
        val c = Term.num(r.nextInt(9) + 1)
        val y = Term.v(Vars3(r.nextInt(3)))
        r.nextInt(9) match
          case 0 => Term(Op.Add, t, Term(Op.Mul, Term.num(0), y))
          case 1 => Term(Op.Mul, t, Term.num(1))
          case 2 => Term(Op.Sub, Term(Op.Add, t, c), c)
          case 3 => Term(Op.Add, t, Term(Op.Sub, y, y))
          case 4 => Term(Op.Neg, Term(Op.Neg, t))
          case 5 => Term(Op.Sub, Term(Op.Shl, t, Term.num(1)), t)
          case 6 => Term(Op.Mul, t, Term(Op.Pow, y, Term.num(0)))
          case 7 => t match
            case Term(Op.Mul, List(a, Term(Op.Add, List(b, d)))) => Term(Op.Add, Term(Op.Mul, a, b), Term(Op.Mul, a, d))
            case Term(op @ (Op.Add | Op.Mul), List(a, b)) => Term(op, b, a)
            case _ => Term(Op.Sub, Term(Op.Mul, Term.num(2), t), t)
          case _ => Term(Op.Sub, Term(Op.Mul, Term.num(2), t), t)
    (1 to steps).foldLeft(t)((acc, _) => once(acc))

/** Semantic audit of a whole e-graph: under a concrete environment every e-class must
  * denote one integer, so every e-node in it must evaluate to the same value. */
object Audit:
  final case class Result(nodesChecked: Long, violations: List[String], unvalued: Int)

  def run(eg: EGraph, env: Map[String, BigInt]): Result =
    val vals = mutable.HashMap[Int, BigInt]()
    def evalNode(n: ENode): Option[BigInt] = n.op match
      case Op.Num(v) => Some(v)
      case Op.Var(x) => env.get(x)
      case op =>
        val ks = n.kids.map(k => vals.get(eg.find(k)))
        if ks.exists(_.isEmpty) then None else Op.eval(op, ks.map(_.get))
    var changed = true
    while changed do
      changed = false
      for c <- eg.classes.valuesIterator if !vals.contains(c.id); n <- c.nodes if !vals.contains(c.id) do
        evalNode(n).foreach { v => vals(c.id) = v; changed = true }
    var checked = 0L
    val bad = mutable.ListBuffer[String]()
    for c <- eg.classes.valuesIterator; n <- c.nodes do
      evalNode(n).foreach { v =>
        checked += 1
        if vals(c.id) != v then bad += s"class e${c.id}: node $n = $v but class = ${vals(c.id)}"
      }
    Result(checked, bad.toList, eg.classes.size - vals.size)

/** The verification suites run by `saturn test`. */
object Verify:
  private var failures = 0
  private def ok(cond: Boolean, msg: => String): Unit = if !cond then { failures += 1; println(s"    FAIL: $msg") }
  private def timed[A](label: String)(body: => A): A =
    val t0 = System.nanoTime()
    val a = body
    println(f"  [$label] done in ${(System.nanoTime() - t0) / 1e9}%.1f s")
    a

  def parserRoundTrip(n: Int): Unit = timed("parser") {
    val r = Random(1)
    var c = 0
    for _ <- 1 to n do
      val t = Gen.term(r, 6)
      val s = t.toString
      val back = Parser.parse(s)
      ok(back == t, s"round trip failed: $s -> ${back.toString}")
      c += 1
    println(s"    $c random terms print -> parse back to the identical tree")
  }

  def congruenceVsOracle(trials: Int): Unit = timed("congruence") {
    val r = Random(2)
    var pairs = 0L
    var merged = 0L
    for _ <- 1 to trials do
      val roots = List.fill(2 + r.nextInt(3))(Gen.ground(r, 4))
      val subs = mutable.LinkedHashSet[Term]()
      def collect(t: Term): Unit = { t.kids.foreach(collect); subs += t }
      roots.foreach(collect)
      val terms = subs.toVector
      val idx = terms.zipWithIndex.toMap
      val eg = EGraph()
      val ids = terms.map(eg.addTerm)
      val oracle = Array.tabulate(terms.length)(identity)
      def of(i: Int): Int = if oracle(i) == i then i else { oracle(i) = of(oracle(i)); oracle(i) }
      for _ <- 1 to 1 + r.nextInt(5) do
        val i = r.nextInt(terms.length); val j = r.nextInt(terms.length)
        eg.union(ids(i), ids(j))
        oracle(of(i)) = of(j)
      eg.rebuild()
      ok(eg.checkInvariants().isEmpty, s"invariants: ${eg.checkInvariants().take(3)}")
      // naive congruence closure to a fixed point
      var changed = true
      while changed do
        changed = false
        for i <- terms.indices; j <- i + 1 until terms.length if of(i) != of(j) do
          val (a, b) = (terms(i), terms(j))
          if a.op == b.op && a.kids.length == b.kids.length && a.kids.nonEmpty &&
             a.kids.zip(b.kids).forall((x, y) => of(idx(x)) == of(idx(y))) then
            oracle(of(i)) = of(j); changed = true
      for i <- terms.indices; j <- i + 1 until terms.length do
        pairs += 1
        val e = eg.find(ids(i)) == eg.find(ids(j))
        if e then merged += 1
        ok(e == (of(i) == of(j)), s"CC disagrees on ${terms(i)} vs ${terms(j)}")
    println(s"    $trials random e-graphs, $pairs term pairs: equivalence identical to naive congruence closure ($merged merged pairs)")
  }

  def ematchVsBruteForce(trials: Int): Unit = timed("e-matching") {
    val r = Random(3)
    val pats = List("(+ ?a ?b)", "(* ?a ?a)", "(+ (* ?a ?b) ?c)", "(* ?x (+ ?y ?x))", "(neg (neg ?a))",
      "(+ ?a (neg ?a))", "(* (+ ?a ?b) (+ ?b ?a))", "(+ a ?b)").map(Pat.parse)
    var total = 0L
    var runs = 0
    for _ <- 1 to trials do
      val eg = EGraph()
      val ts = List.fill(2 + r.nextInt(2))(Gen.ground(r, 3))
      val ids = ts.map(eg.addTerm)
      for _ <- 1 to r.nextInt(4) do eg.union(ids(r.nextInt(ids.length)), eg.addTerm(Gen.ground(r, 2)))
      eg.rebuild()
      val classes = eg.classes.keys.toVector
      if classes.size <= 22 then
        val index = eg.opIndex()
        for p <- pats do
          runs += 1
          val got = Matcher.search(eg, p, index).map((c, s) => (c, s.view.mapValues(eg.find).toMap)).toSet
          val vs = p.vars.toVector.sorted
          def exists(q: Pat, s: Subst, c: Int): Boolean = q match
            case Pat.PV(x) => eg.find(s(x)) == c
            case Pat.PN(op, ks) => eg.classes(c).nodes.exists(n => n.op == op && ks.zip(n.kids).forall((k, id) => exists(k, s, eg.find(id))))
          val want = mutable.HashSet[(Int, Subst)]()
          def assign(i: Int, s: Subst): Unit =
            if i == vs.length then classes.foreach(c => if exists(p, s, c) then want += ((c, s)))
            else classes.foreach(c => assign(i + 1, s.updated(vs(i), c)))
          assign(0, Map.empty)
          total += want.size
          ok(got == want.toSet, s"e-matching $p: got ${got.size}, brute force ${want.size}")
    println(s"    $runs (pattern, e-graph) searches agree with exhaustive enumeration ($total matches)")
  }

  def soundness(n: Int): Unit = timed("soundness") {
    val r = Random(4)
    var nodes = 0L
    var envChecks = 0
    var totalBefore = 0L
    var totalAfter = 0L
    for k <- 1 to n do
      val t = Gen.term(r, 5)
      val eg = EGraph()
      val root = eg.addTerm(t)
      val rep = Runner(eg, Rules.all, Limits(iters = 10, nodes = 25_000, millis = 3_000)).run()
      val inv = eg.checkInvariants()
      ok(inv.isEmpty, s"invariants after saturating $t: ${inv.take(3)}")
      val (_, out) = Extractor.extract(eg, root, AstSize)
      totalBefore += t.size; totalAfter += out.size
      for _ <- 1 to 12 do
        val env = Gen.env(r, Gen.Vars3)
        (t.eval(env), out.eval(env)) match
          case (Some(x), Some(y)) => envChecks += 1; ok(x == y, s"$t = $x but extracted $out = $y at $env")
          case (Some(x), None)    => ok(false, s"extracted $out undefined where $t = $x")
          case _ =>
      for _ <- 1 to 3 do
        val a = Audit.run(eg, Gen.env(r, Gen.Vars3, 1000))
        nodes += a.nodesChecked
        ok(a.violations.isEmpty, s"audit of e-graph for $t: ${a.violations.take(2)}")
    println(s"    $n random terms saturated; $envChecks extracted-vs-original evaluations equal")
    println(s"    $nodes e-node evaluations audited across whole e-graphs: every e-class denotes exactly one integer")
    println(f"    mean term size ${totalBefore.toDouble / n}%.2f -> ${totalAfter.toDouble / n}%.2f after extraction")
  }

  /** Inject each bogus rule and show the checkers catch it. */
  def mutationTesting(): Unit = timed("bug injection") {
    for (desc, bad) <- Rules.bogus do
      val r = Random(5)
      var caughtAt = -1
      var how = ""
      var k = 0
      while caughtAt < 0 && k < 200 do
        k += 1
        val t = Gen.term(r, 5)
        val eg = EGraph()
        val root = eg.addTerm(t)
        try
          Runner(eg, bad :: Rules.all, Limits(iters = 6, nodes = 15_000, millis = 2_000)).run()
          val a = Audit.run(eg, Gen.env(r, Gen.Vars3, 1000))
          if a.violations.nonEmpty then { caughtAt = k; how = "semantic audit" }
          else
            val (_, out) = Extractor.extract(eg, root, AstSize)
            val env = Gen.env(r, Gen.Vars3)
            if t.eval(env).isDefined && t.eval(env) != out.eval(env) then { caughtAt = k; how = "extraction differential" }
        catch case e: UnsoundMerge => { caughtAt = k; how = "constant-analysis conflict" }
      ok(caughtAt > 0, s"bogus rule '$desc' was NOT detected")
      if caughtAt > 0 then println(f"    bogus rule ${"'" + desc + "'"}%-26s caught on random term #$caughtAt by $how")
  }

  val identities: List[String] = List(
    "(a + b) * (a + b) = a*a + 2*a*b + b*b",
    "(a + b)^2 = a^2 + 2*a*b + b^2",
    "(a - b) * (a + b) = a^2 - b^2",
    "(a - b)^2 = (b - a)^2",
    "x * 15 = (x << 4) - x",
    "(x << 2) + (x << 1) = x * 6",
    "(x << 3) << 2 = x * 32",
    "a*(b - c) + a*c = a*b",
    "(a + b + c) - (c + a) = b",
    "2*(a + b) - a = a + 2*b",
    "x^3 = x * x * x",
    "x * x^3 = x^4",
    "(x + 1)^3 = x^3 + 3*x^2 + 3*x + 1",
    "-(-x) = x",
    "(a*b)*(c*d) = (d*c)*(b*a)",
    "(x + y)*(x - y) + y*y = x*x",
    "(2 + 3) * x - x * 4 = x",
    "((a << 1) + a) * 2 = 6 * a",
  )

  val nonIdentities: List[String] = List(
    "(a + b)^2 = a^2 + b^2",
    "x << 1 = x + 1",
    "a - b = b - a",
    "a * a = 2 * a",
    "(a + b) * c = a + b * c",
  )

  def proofs(): Unit = timed("proofs") {
    for s <- identities do
      val (l, rr) = Parser.parseEquation(s)
      val p = Saturn.prove(l, rr)
      ok(p.proved, s"could not prove $s (${p.report.stop})")
      val inv = p.eg.checkInvariants()
      ok(inv.isEmpty, s"invariants after proving $s")
      println(f"    proved   $s%-42s ${p.report.iters.size}%2d iters ${p.report.nodes}%7d nodes ${p.report.millis}%7.0f ms")
    val r = Random(6)
    for s <- nonIdentities do
      val (l, rr) = Parser.parseEquation(s)
      val p = Saturn.prove(l, rr, Limits(iters = 12, nodes = 40_000, millis = 4_000))
      ok(!p.proved, s"PROVED A FALSEHOOD: $s")
      val cex = Iterator.continually(Gen.env(r, Seq("a", "b", "c", "x"), 9)).take(100).find(e => l.eval(e) != rr.eval(e))
      ok(cex.isDefined, s"no counterexample for $s")
      val ce = cex.map(_.filter((k, _) => (l.vars ++ rr.vars)(k)).map((k, v) => s"$k=$v").mkString(", ")).getOrElse("")
      println(f"    refuted  $s%-42s not merged (${p.report.stop}); counterexample $ce")
  }

  def optimisation(n: Int): (Int, Int, Double, Double, Double) =
    val r = Random(7)
    var recovered = 0
    var bloat = 0L; var after = 0L; var target = 0L
    var total = 0
    for _ <- 1 to n do
      val t0 = Gen.term(r, 3)
      val small = Saturn.simplify(t0, AstSize, Limits(iters = 12, nodes = 20_000, millis = 2_000)).output
      val obf = Gen.obfuscate(r, small, 4 + r.nextInt(5))
      val res = Saturn.simplify(obf, AstSize, Limits(iters = 20, nodes = 60_000, millis = 4_000))
      total += 1
      bloat += obf.size; after += res.output.size; target += small.size
      if res.output.size <= small.size then recovered += 1
      val env = Gen.env(r, Gen.Vars3)
      ok(obf.eval(env) == res.output.eval(env), s"optimiser changed meaning of $obf")
    (recovered, total, bloat.toDouble / total, after.toDouble / total, target.toDouble / total)

  def optimisationSuite(n: Int): Unit = timed("optimisation") {
    val (rec, tot, b, a, t) = optimisation(n)
    println(f"    $tot obfuscated terms: mean size $b%.1f -> $a%.1f (hidden original $t%.1f); recovered to <= original size in $rec/$tot (${100.0 * rec / tot}%.1f%%)")
    ok(rec.toDouble / tot >= 0.9, "recovery rate below 90%")
  }

  def runAll(quick: Boolean): Boolean =
    failures = 0
    val s = if quick then 0.2 else 1.0
    println("saturn verification suite")
    parserRoundTrip((20_000 * s).toInt)
    congruenceVsOracle((3_000 * s).toInt)
    ematchVsBruteForce((400 * s).toInt)
    soundness((300 * s).toInt)
    mutationTesting()
    proofs()
    optimisationSuite((200 * s).toInt)
    if failures == 0 then println("ALL CHECKS PASSED") else println(s"$failures CHECK(S) FAILED")
    failures == 0
