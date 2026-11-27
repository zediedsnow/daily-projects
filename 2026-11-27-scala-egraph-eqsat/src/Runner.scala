package saturn

import scala.collection.mutable

final case class Limits(iters: Int = 30, nodes: Int = 60_000, millis: Long = 5_000, matchLimit: Int = 1_000, banLength: Int = 5)

enum Stop:
  case Saturated, IterLimit, NodeLimit, TimeLimit, Goal

final case class IterStat(iter: Int, nodes: Int, classes: Int, matches: Int, unions: Long, banned: Int, millis: Double)

final case class Report(stop: Stop, iters: Vector[IterStat], millis: Double):
  def nodes: Int = iters.lastOption.map(_.nodes).getOrElse(0)
  def classes: Int = iters.lastOption.map(_.classes).getOrElse(0)

/** Equality-saturation driver with egg's backoff scheduler: a rule whose match count
  * explodes past its threshold is banned for an exponentially growing number of
  * iterations, which keeps associativity/commutativity from swamping everything else. */
final class Runner(eg: EGraph, rules: Seq[Rewrite], limits: Limits = Limits(), goal: EGraph => Boolean = _ => false):
  private final class RuleStat(var bannedUntil: Int = 0, var timesBanned: Int = 0, var applied: Long = 0)
  private val stats = rules.map(r => r -> RuleStat()).toMap
  def appliedCounts: Seq[(String, Long)] = rules.map(r => r.name -> stats(r).applied)

  def run(): Report =
    val t0 = System.nanoTime()
    def ms = (System.nanoTime() - t0) / 1e6
    val iters = Vector.newBuilder[IterStat]
    eg.rebuild()
    var stop: Option[Stop] = if goal(eg) then Some(Stop.Goal) else None
    var i = 0
    while stop.isEmpty do
      if i >= limits.iters then stop = Some(Stop.IterLimit)
      else
        val index = eg.opIndex()
        val found = mutable.ArrayBuffer[(Rewrite, Int, Subst)]()
        var banned = 0
        for r <- rules do
          val st = stats(r)
          if i < st.bannedUntil then banned += 1
          else
            val threshold = limits.matchLimit.toLong << st.timesBanned
            val ms = Matcher.search(eg, r.lhs, index, threshold.min(Int.MaxValue).toInt)
            if ms.size > threshold then
              st.bannedUntil = i + (limits.banLength << st.timesBanned)
              st.timesBanned += 1
              banned += 1
            else ms.foreach((c, s) => found += ((r, c, s)))
        val before = eg.unionCount
        val it = found.iterator
        while it.hasNext && eg.idsAllocated < limits.nodes * 2 do
          val (r, c, s) = it.next()
          r.apply(eg, s).foreach { id => if eg.union(c, id) then stats(r).applied += 1 }
        eg.rebuild()
        i += 1
        val changed = eg.unionCount != before
        iters += IterStat(i, eg.totalNodes, eg.classCount, found.size, eg.unionCount - before, banned, ms)
        if goal(eg) then stop = Some(Stop.Goal)
        else if eg.totalNodes > limits.nodes then stop = Some(Stop.NodeLimit)
        else if ms > limits.millis then stop = Some(Stop.TimeLimit)
        else if !changed then
          if banned == 0 then stop = Some(Stop.Saturated)
          else stats.valuesIterator.foreach(st => if st.bannedUntil > i then st.bannedUntil = i) // fast-forward bans
    Report(stop.get, iters.result(), ms)

/** Cost models for extraction. */
trait CostModel:
  def name: String
  def cost(op: Op): Long

object AstSize extends CostModel:
  val name = "size"
  def cost(op: Op): Long = 1

/** Rough integer-ALU latency: multiplies are expensive, shifts and adds are cheap. */
object Latency extends CostModel:
  val name = "latency"
  def cost(op: Op): Long = op match
    case Op.Num(_) | Op.Var(_) => 0
    case Op.Add | Op.Sub | Op.Neg | Op.Shl => 1
    case Op.Mul => 4
    case Op.Pow => 12

/** Bottom-up fixed-point extraction of the cheapest tree in each e-class. */
object Extractor:
  def costs(eg: EGraph, cm: CostModel): mutable.HashMap[Int, (Long, ENode)] =
    val best = mutable.HashMap[Int, (Long, ENode)]()
    var changed = true
    while changed do
      changed = false
      for c <- eg.classes.valuesIterator; n <- c.nodes do
        var sum = cm.cost(n.op)
        var ok = true
        var i = 0
        while ok && i < n.kids.length do
          best.get(eg.find(n.kids(i))) match
            case Some((k, _)) => sum += k
            case None         => ok = false
          i += 1
        if ok then
          val better = best.get(c.id) match
            case None          => true
            case Some((old, on)) => sum < old || (sum == old && depthHint(n) < depthHint(on))
          if better then { best(c.id) = (sum, n); changed = true }
    best

  // prefer leaves over operators on ties (keeps output canonical and short)
  private def depthHint(n: ENode): Int = n.kids.length

  def extract(eg: EGraph, root: Int, cm: CostModel): (Long, Term) =
    val best = costs(eg, cm)
    def build(id: Int): Term =
      val n = best(eg.find(id))._2
      Term(n.op, n.kids.toList.map(build))
    (best(eg.find(root))._1, build(root))

  def cost(t: Term, cm: CostModel): Long = cm.cost(t.op) + t.kids.map(cost(_, cm)).sum
