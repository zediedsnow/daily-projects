package saturn

object Main:
  private val usage =
    """saturn - an e-graph equality saturation engine
      |
      |usage:
      |  saturn simplify "<expr>" [--cost size|latency] [--trace]
      |  saturn prove "<lhs> = <rhs>"
      |  saturn dot "<expr>" [--iters N]       Graphviz of the saturated e-graph
      |  saturn demo                           showcase
      |  saturn bench                          obfuscation-recovery benchmark
      |  saturn test [--quick]                 full verification suite
      |
      |syntax: integers, identifiers, + - * << ^ (constant exponent), unary -, parentheses""".stripMargin

  def main(args: Array[String]): Unit =
    try run(args.toList)
    catch
      case e: Parser.ParseError => System.err.println(s"parse error: ${e.msg}"); sys.exit(2)

  private def flag(args: List[String], name: String): Option[String] =
    args.sliding(2).collectFirst { case List(`name`, v) => v }

  private def costModel(args: List[String]): CostModel =
    flag(args, "--cost") match
      case Some("latency") => Latency
      case _               => AstSize

  private def run(args: List[String]): Unit = args match
    case "simplify" :: e :: rest =>
      val cm = costModel(rest)
      val t = Parser.parse(e)
      val res = Saturn.simplify(t, cm, Limits(iters = 30, nodes = 100_000, millis = 10_000))
      if rest.contains("--trace") then printTrace(res.report)
      println(s"input : ${res.input}   (${cm.name} ${res.costBefore})")
      println(s"output: ${res.output}   (${cm.name} ${res.costAfter})")
      println(f"stop  : ${res.report.stop} after ${res.report.iters.size} iterations, ${res.report.nodes} e-nodes in ${res.report.classes} e-classes, ${res.report.millis}%.0f ms")
    case "prove" :: e :: _ =>
      val (l, r) = Parser.parseEquation(e)
      val p = Saturn.prove(l, r)
      printTrace(p.report)
      println(if p.proved then s"PROVED: $l = $r" else s"NOT PROVED (${p.report.stop}): $l = $r")
      if !p.proved then sys.exit(1)
    case "dot" :: e :: rest =>
      val n = flag(rest, "--iters").map(_.toInt).getOrElse(3)
      val t = Parser.parse(e)
      val res = Saturn.simplify(t, AstSize, Limits(iters = n, nodes = 2_000))
      println(res.eg.toDot(Set(res.root)))
    case "demo" :: _ | Nil => demo()
    case "bench" :: _ => bench()
    case "test" :: rest => if !Verify.runAll(rest.contains("--quick")) then sys.exit(1)
    case _ => println(usage)

  private def printTrace(r: Report): Unit =
    println("  iter   e-nodes  e-classes   matches  unions  banned      ms")
    r.iters.foreach(s => println(f"  ${s.iter}%4d  ${s.nodes}%8d  ${s.classes}%9d  ${s.matches}%8d  ${s.unions}%6d  ${s.banned}%6d  ${s.millis}%6.0f"))

  private def demo(): Unit =
    println("== simplification (cost = AST size) ==")
    for e <- List(
      "(a * 2 + a * 6) - (8 * a - b)",
      "(x + 0) * (1 * y) + (x - x) * 1000",
      "((a + b) * (a - b) + b ^ 2) - a ^ 2 + c",
      "(x << 3) + (x << 1) - 10 * x + y * (3 - 2)",
      "-(-(a * (b + c))) - a * c",
      "(2 + 3) * (x ^ 2 * x) - x ^ 3 * 4",
    ) do
      val r = Saturn.simplify(Parser.parse(e), AstSize, Limits(iters = 30, nodes = 100_000, millis = 10_000))
      println(f"  ${r.input.toString}%-46s ==> ${r.output}   [${r.report.stop}, ${r.report.nodes} nodes, ${r.report.millis}%.0f ms]")
    println("\n== strength reduction (cost = ALU latency: mul 4, add/sub/shl 1) ==")
    for e <- List("x * 15", "x * 9", "x * 64 + x * 8", "y * 31 - y", "(a * 7) * 2") do
      val r = Saturn.simplify(Parser.parse(e), Latency, Limits(iters = 30, nodes = 100_000, millis = 10_000))
      println(f"  ${r.input.toString}%-22s ==> ${r.output.toString}%-22s latency ${r.costBefore} -> ${r.costAfter}")
    println("\n== proofs by saturation ==")
    for s <- List("(a + b)^2 = a^2 + 2*a*b + b^2", "(x + 1)^3 = x^3 + 3*x^2 + 3*x + 1", "(x + y)*(x - y) + y*y = x*x", "(a + b)^2 = a^2 + b^2") do
      val (l, r) = Parser.parseEquation(s)
      val p = Saturn.prove(l, r, Limits(iters = 60, nodes = 200_000, millis = 15_000))
      val verdict = if p.proved then "PROVED    " else "not proved"
      println(f"  $verdict $s%-40s ${p.report.iters.size}%2d iterations, ${p.report.nodes}%6d e-nodes, ${p.report.millis}%5.0f ms")

  private def bench(): Unit =
    val t0 = System.nanoTime()
    val (rec, tot, b, a, t) = Verify.optimisation(500)
    println(f"$tot obfuscated terms: mean size $b%.1f -> $a%.1f (hidden original $t%.1f)")
    println(f"recovered to <= original size: $rec/$tot (${100.0 * rec / tot}%.1f%%) in ${(System.nanoTime() - t0) / 1e9}%.1f s")
