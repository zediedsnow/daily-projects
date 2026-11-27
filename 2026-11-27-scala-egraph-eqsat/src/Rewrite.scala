package saturn

import scala.collection.mutable

type Subst = Map[String, Int]

/** Patterns: ?x variables or operator nodes. Written as s-expressions: (+ ?a (* ?b 0)) */
enum Pat:
  case PV(name: String)
  case PN(op: Op, kids: List[Pat])

  def vars: Set[String] = this match
    case PV(n)     => Set(n)
    case PN(_, ks) => ks.flatMap(_.vars).toSet

  override def toString: String = this match
    case PV(n)        => n
    case PN(op, Nil)  => op.sym
    case PN(op, ks)   => ks.mkString(s"(${op.sym} ", " ", ")")

object Pat:
  def parse(s: String): Pat =
    val toks = s.replace("(", " ( ").replace(")", " ) ").split("\\s+").filter(_.nonEmpty).toVector
    var pos = 0
    def opOf(t: String): Op = t match
      case "+" => Op.Add; case "-" => Op.Sub; case "*" => Op.Mul; case "neg" => Op.Neg
      case "<<" => Op.Shl; case "^" => Op.Pow
      case _ => throw IllegalArgumentException(s"unknown operator $t")
    def atom(t: String): Pat =
      if t.startsWith("?") then PV(t)
      else if t.matches("-?\\d+") then PN(Op.Num(BigInt(t)), Nil)
      else PN(Op.Var(t), Nil)
    def go(): Pat =
      val t = toks(pos); pos += 1
      if t == "(" then
        val op = opOf(toks(pos)); pos += 1
        val ks = mutable.ListBuffer[Pat]()
        while toks(pos) != ")" do ks += go()
        pos += 1
        require(ks.size == op.arity, s"arity mismatch in $s")
        PN(op, ks.toList)
      else atom(t)
    val p = go()
    require(pos == toks.length, s"trailing tokens in pattern $s")
    p

/** E-matching: top-down backtracking search over e-class nodes. */
object Matcher:
  import Pat.*

  def matchIn(eg: EGraph, p: Pat, cls: Int, s: Subst, out: Subst => Unit): Unit = p match
    case PV(x) =>
      s.get(x) match
        case Some(c) => if eg.find(c) == cls then out(s)
        case None    => out(s.updated(x, cls))
    case PN(op, kids) =>
      val nodes = eg.classes(cls).nodes
      var i = 0
      while i < nodes.length do
        val n = nodes(i)
        if n.op == op then matchKids(eg, kids, n.kids, 0, s, out)
        i += 1

  private def matchKids(eg: EGraph, ps: List[Pat], ids: Array[Int], i: Int, s: Subst, out: Subst => Unit): Unit =
    ps match
      case Nil       => out(s)
      case p :: rest => matchIn(eg, p, eg.find(ids(i)), s, s2 => matchKids(eg, rest, ids, i + 1, s2, out))

  /** All (root class, substitution) matches of `p` in the e-graph. */
  def search(eg: EGraph, p: Pat, index: collection.Map[Op, collection.Seq[Int]], limit: Int = Int.MaxValue): Vector[(Int, Subst)] =
    val out = Vector.newBuilder[(Int, Subst)]
    var count = 0
    val roots: Iterator[Int] = p match
      case PN(op, _) => index.getOrElse(op, Nil).iterator
      case PV(_)     => eg.classes.keysIterator
    scala.util.boundary {
      while roots.hasNext do
        val c = roots.next()
        matchIn(eg, p, c, Map.empty, s => {
          out += ((c, s)); count += 1
          if count > limit then scala.util.boundary.break()
        })
    }
    out.result()

  def instantiate(eg: EGraph, p: Pat, s: Subst): Int = p match
    case PV(x)        => s(x)
    case PN(op, kids) => eg.add(ENode(op, kids.map(instantiate(eg, _, s)).toArray))

/** A rewrite rule: a pattern on the left, and an applier that builds the right-hand side
  * (returning None when a side condition rejects the match). */
final case class Rewrite(name: String, lhs: Pat, apply: (EGraph, Subst) => Option[Int]):
  override def toString: String = name

object Rewrite:
  def rule(name: String, lhs: String, rhs: String): Rewrite =
    val l = Pat.parse(lhs); val r = Pat.parse(rhs)
    require(r.vars.subsetOf(l.vars), s"rule $name: rhs uses unbound variables")
    Rewrite(name, l, (eg, s) => Some(Matcher.instantiate(eg, r, s)))

  def ruleIf(name: String, lhs: String, rhs: String)(cond: (EGraph, Subst) => Boolean): Rewrite =
    val base = rule(name, lhs, rhs)
    base.copy(apply = (eg, s) => if cond(eg, s) then base.apply(eg, s) else None)

  def dynamic(name: String, lhs: String)(f: (EGraph, Subst) => Option[Int]): Rewrite =
    Rewrite(name, Pat.parse(lhs), f)

  /** Both directions of an equation. */
  def bi(name: String, a: String, b: String): List[Rewrite] =
    List(rule(name, a, b), rule(name + "-rev", b, a))
