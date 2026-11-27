package saturn

final case class Simplified(input: Term, output: Term, costBefore: Long, costAfter: Long, report: Report, eg: EGraph, root: Int)
final case class Proof(lhs: Term, rhs: Term, proved: Boolean, report: Report, eg: EGraph)

object Saturn:
  def simplify(t: Term, cm: CostModel = AstSize, limits: Limits = Limits(), rules: Seq[Rewrite] = Rules.all): Simplified =
    val eg = EGraph()
    val root = eg.addTerm(t)
    val rep = Runner(eg, rules, limits).run()
    val (c, out) = Extractor.extract(eg, root, cm)
    Simplified(t, out, Extractor.cost(t, cm), c, rep, eg, eg.find(root))

  def prove(a: Term, b: Term, limits: Limits = Limits(iters = 60, nodes = 200_000, millis = 20_000), rules: Seq[Rewrite] = Rules.all): Proof =
    val eg = EGraph()
    val ia = eg.addTerm(a)
    val ib = eg.addTerm(b)
    val rep = Runner(eg, rules, limits, g => g.find(ia) == g.find(ib)).run()
    Proof(a, b, eg.find(ia) == eg.find(ib), rep, eg)
