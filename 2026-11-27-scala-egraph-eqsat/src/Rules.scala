package saturn

import Rewrite.*

/** The rewrite system: ring axioms, power and shift laws, and analysis-driven strength
  * reduction. Every rule is sound over the integers (checked by `saturn test`). */
object Rules:
  private def const(eg: EGraph, s: Subst, v: String): Option[BigInt] = eg.constOf(s(v))
  private def constIn(eg: EGraph, s: Subst, v: String, lo: Int, hi: Int): Option[Int] =
    const(eg, s, v).filter(c => c >= lo && c <= hi).map(_.toInt)
  private def num(eg: EGraph, v: BigInt): Int = eg.add(ENode.leaf(Op.Num(v)))
  private def node(eg: EGraph, op: Op, kids: Int*): Int = eg.add(ENode(op, kids.toArray))
  private def log2Exact(c: BigInt): Option[Int] = if c > 0 && c.bitCount == 1 then Some(c.bitLength - 1) else None

  val algebra: List[Rewrite] = List(
    rule("comm-add", "(+ ?a ?b)", "(+ ?b ?a)"),
    rule("comm-mul", "(* ?a ?b)", "(* ?b ?a)"),
  ) ++ bi("assoc-add", "(+ ?a (+ ?b ?c))", "(+ (+ ?a ?b) ?c)")
    ++ bi("assoc-mul", "(* ?a (* ?b ?c))", "(* (* ?a ?b) ?c)")
    ++ bi("sub-canon", "(- ?a ?b)", "(+ ?a (* -1 ?b))")
    ++ bi("neg-canon", "(neg ?a)", "(* -1 ?a)")
    ++ List(
    rule("add-0", "(+ ?a 0)", "?a"),
    rule("mul-0", "(* ?a 0)", "0"),
    rule("mul-1", "(* ?a 1)", "?a"),
    rule("sub-self", "(- ?a ?a)", "0"),
    rule("distribute", "(* ?a (+ ?b ?c))", "(+ (* ?a ?b) (* ?a ?c))"),
    rule("factor", "(+ (* ?a ?b) (* ?a ?c))", "(* ?a (+ ?b ?c))"),
    rule("factor-1", "(+ ?a (* ?a ?b))", "(* ?a (+ 1 ?b))"),
    rule("double", "(+ ?a ?a)", "(* 2 ?a)"),
  )

  val powers: List[Rewrite] = List(
    rule("pow-0", "(^ ?a 0)", "1"),
    rule("pow-1", "(^ ?a 1)", "?a"),
    rule("pow-sq", "(* ?a ?a)", "(^ ?a 2)"),
    dynamic("pow-unfold", "(^ ?a ?n)") { (eg, s) =>
      constIn(eg, s, "?n", 2, 8).map(n => node(eg, Op.Mul, s("?a"), node(eg, Op.Pow, s("?a"), num(eg, n - 1))))
    },
    ruleIf("pow-mul", "(* (^ ?a ?n) (^ ?a ?m))", "(^ ?a (+ ?n ?m))") { (eg, s) =>
      constIn(eg, s, "?n", 0, Op.MaxPow).isDefined && constIn(eg, s, "?m", 0, Op.MaxPow).isDefined
    },
    ruleIf("pow-mul-1", "(* ?a (^ ?a ?n))", "(^ ?a (+ ?n 1))") { (eg, s) =>
      constIn(eg, s, "?n", 0, Op.MaxPow - 1).isDefined
    },
  )

  val shifts: List[Rewrite] = List(
    dynamic("shl-to-mul", "(<< ?a ?k)") { (eg, s) =>
      constIn(eg, s, "?k", 0, 64).map(k => node(eg, Op.Mul, s("?a"), num(eg, BigInt(1) << k)))
    },
    dynamic("mul-to-shl", "(* ?a ?c)") { (eg, s) =>
      const(eg, s, "?c").filter(_ >= 2).flatMap(log2Exact).map(k => node(eg, Op.Shl, s("?a"), num(eg, k)))
    },
    dynamic("mul-shl-sub", "(* ?a ?c)") { (eg, s) =>       // a*(2^k-1) = (a<<k) - a
      const(eg, s, "?c").filter(_ >= 3).flatMap(c => log2Exact(c + 1)).map { k =>
        node(eg, Op.Sub, node(eg, Op.Shl, s("?a"), num(eg, k)), s("?a"))
      }
    },
    dynamic("mul-shl-add", "(* ?a ?c)") { (eg, s) =>       // a*(2^k+1) = (a<<k) + a
      const(eg, s, "?c").filter(_ >= 3).flatMap(c => log2Exact(c - 1)).map { k =>
        node(eg, Op.Add, node(eg, Op.Shl, s("?a"), num(eg, k)), s("?a"))
      }
    },
    ruleIf("shl-shl", "(<< (<< ?a ?j) ?k)", "(<< ?a (+ ?j ?k))") { (eg, s) =>
      constIn(eg, s, "?j", 0, 64).isDefined && constIn(eg, s, "?k", 0, 64).isDefined
    },
  )

  val all: List[Rewrite] = algebra ++ powers ++ shifts

  /** Deliberately wrong rules, used to show that the soundness audit has teeth. */
  val bogus: List[(String, Rewrite)] = List(
    "a*(b+c) -> a*b + c"   -> rule("bad-distribute", "(* ?a (+ ?b ?c))", "(+ (* ?a ?b) ?c)"),
    "a - b -> b - a"       -> rule("bad-sub-comm", "(- ?a ?b)", "(- ?b ?a)"),
    "a << k -> a * k"      -> rule("bad-shl", "(<< ?a ?k)", "(* ?a ?k)"),
    "a^n -> a*n (n const)" -> ruleIf("bad-pow", "(^ ?a ?n)", "(* ?a ?n)")((eg, s) => eg.constOf(s("?n")).isDefined),
  )
