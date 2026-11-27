package saturn

/** Operators of the expression language: exact (arbitrary precision) integer arithmetic. */
enum Op:
  case Num(v: BigInt)
  case Var(name: String)
  case Add, Sub, Mul, Neg, Shl, Pow

  def arity: Int = this match
    case Num(_) | Var(_) => 0
    case Neg             => 1
    case _               => 2

  def sym: String = this match
    case Num(v)  => v.toString
    case Var(n)  => n
    case Add     => "+"
    case Sub     => "-"
    case Mul     => "*"
    case Neg     => "neg"
    case Shl     => "<<"
    case Pow     => "^"

object Op:
  /** Exponent / shift bounds keep every evaluation finite and cheap. */
  val MaxShift = 256
  val MaxPow = 64
  val MaxBits = 8192

  /** Semantics of one operator applied to already-evaluated arguments; None = undefined. */
  def eval(op: Op, a: Array[BigInt]): Option[BigInt] = op match
    case Num(v) => Some(v)
    case Var(_) => None
    case Add    => Some(a(0) + a(1))
    case Sub    => Some(a(0) - a(1))
    case Mul    => Some(a(0) * a(1))
    case Neg    => Some(-a(0))
    case Shl    =>
      val k = a(1)
      if k >= 0 && k <= MaxShift && a(0).bitLength + k.toInt <= MaxBits then Some(a(0) << k.toInt) else None
    case Pow    =>
      val k = a(1)
      if k >= 0 && k <= MaxPow && a(0).bitLength.toLong * k.toLong <= MaxBits then Some(a(0).pow(k.toInt)) else None

/** A plain expression tree. */
final case class Term(op: Op, kids: List[Term]):
  def size: Int = 1 + kids.map(_.size).sum
  def depth: Int = 1 + (if kids.isEmpty then 0 else kids.map(_.depth).max)
  def vars: Set[String] = op match
    case Op.Var(n) => Set(n)
    case _         => kids.flatMap(_.vars).toSet

  def eval(env: Map[String, BigInt]): Option[BigInt] = op match
    case Op.Num(v) => Some(v)
    case Op.Var(n) => env.get(n)
    case _ =>
      val vs = kids.map(_.eval(env))
      if vs.exists(_.isEmpty) then None else Op.eval(op, vs.map(_.get).toArray)

  override def toString: String = Printer.show(this)

object Term:
  def num(v: BigInt): Term = Term(Op.Num(v), Nil)
  def v(n: String): Term = Term(Op.Var(n), Nil)
  def apply(op: Op, kids: Term*): Term = Term(op, kids.toList)

/** Infix printer that emits the minimum parentheses needed to re-parse to the same tree. */
object Printer:
  private def prec(t: Term): Int = t.op match
    case Op.Shl          => 0
    case Op.Add | Op.Sub => 1
    case Op.Mul          => 2
    case Op.Neg          => 3
    case Op.Pow          => 4
    case Op.Num(v)       => if v < 0 then 3 else 5
    case Op.Var(_)       => 5

  def show(t: Term): String = t.op match
    case Op.Num(v) => v.toString
    case Op.Var(n) => n
    case Op.Neg =>
      val c = t.kids.head
      val s = show(c)
      if prec(c) < 4 || s.head.isDigit || s.head == '-' then s"-($s)" else s"-$s"
    case op =>
      val p = prec(t)
      val List(a, b) = t.kids: @unchecked
      val rightAssoc = op == Op.Pow
      // left operand: needs parens if it binds looser (or equal, for right-assoc ^)
      val la = show(a)
      val ls = if prec(a) < p || (rightAssoc && prec(a) == p) then s"($la)" else la
      val rb = show(b)
      val rs = if prec(b) < p || (!rightAssoc && prec(b) == p) then s"($rb)" else rb
      s"$ls ${op.sym} $rs"

/** Pratt parser for the infix syntax: + - * << ^ unary -, parentheses, integers, identifiers. */
object Parser:
  final case class ParseError(msg: String) extends Exception(msg)

  private def tokenize(s: String): Vector[String] =
    val out = Vector.newBuilder[String]
    var i = 0
    while i < s.length do
      val c = s(i)
      if c.isWhitespace then i += 1
      else if c.isDigit then
        val j = s.indexWhere(!_.isDigit, i) match { case -1 => s.length; case j => j }
        out += s.substring(i, j); i = j
      else if c.isLetter || c == '_' then
        val j = s.indexWhere(ch => !(ch.isLetterOrDigit || ch == '_'), i) match { case -1 => s.length; case j => j }
        out += s.substring(i, j); i = j
      else if s.startsWith("<<", i) then { out += "<<"; i += 2 }
      else if "+-*^()=".contains(c) then { out += c.toString; i += 1 }
      else throw ParseError(s"unexpected character '$c' at $i")
    out.result()

  def parse(s: String): Term =
    val toks = tokenize(s)
    var pos = 0
    def peek = if pos < toks.length then toks(pos) else ""
    def next() = { val t = peek; pos += 1; t }
    def binPrec(t: String): Int = t match
      case "<<"       => 0
      case "+" | "-"  => 1
      case "*"        => 2
      case "^"        => 4
      case _          => -1
    def opOf(t: String): Op = t match
      case "<<" => Op.Shl; case "+" => Op.Add; case "-" => Op.Sub; case "*" => Op.Mul; case "^" => Op.Pow
    def prefix(): Term =
      val t = next()
      if t == "(" then
        val e = expr(0)
        if next() != ")" then throw ParseError("expected ')'")
        e
      else if t == "-" then
        if peek.nonEmpty && peek.head.isDigit then Term.num(-BigInt(next()))
        else Term(Op.Neg, expr(4))
      else if t.nonEmpty && t.head.isDigit then Term.num(BigInt(t))
      else if t.nonEmpty && (t.head.isLetter || t.head == '_') then Term.v(t)
      else throw ParseError(s"unexpected token '${t}'")
    def expr(minPrec: Int): Term =
      var lhs = prefix()
      var done = false
      while !done do
        val p = binPrec(peek)
        if p < 0 || p < minPrec then done = true
        else
          val op = opOf(next())
          val rhs = if op == Op.Pow then expr(p) else expr(p + 1)
          lhs = Term(op, lhs, rhs)
      lhs
    val e = expr(0)
    if pos != toks.length then throw ParseError(s"trailing input at '${peek}'")
    e

  /** "lhs = rhs" */
  def parseEquation(s: String): (Term, Term) =
    val i = s.indexOf('=')
    if i < 0 then throw ParseError("expected 'lhs = rhs'")
    (parse(s.substring(0, i)), parse(s.substring(i + 1)))
