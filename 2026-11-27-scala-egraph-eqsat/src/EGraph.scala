package saturn

import scala.collection.mutable

/** An e-node: an operator applied to e-class ids. Structural equality over the child array. */
final class ENode(val op: Op, val kids: Array[Int]):
  override def hashCode: Int = op.hashCode * 31 + java.util.Arrays.hashCode(kids)
  override def equals(o: Any): Boolean = o match
    case n: ENode => (n eq this) || (op == n.op && java.util.Arrays.equals(kids, n.kids))
    case _        => false
  inline def mapKids(f: Int => Int): ENode =
    if kids.length == 0 then this
    else
      val k = new Array[Int](kids.length)
      var i = 0
      while i < kids.length do { k(i) = f(kids(i)); i += 1 }
      ENode(op, k)
  override def toString: String =
    if kids.isEmpty then op.sym else s"(${op.sym} ${kids.mkString(" ")})"

object ENode:
  def leaf(op: Op): ENode = ENode(op, Array.emptyIntArray)

/** An equivalence class of e-nodes plus its constant-folding analysis value. */
final class EClass(val id: Int):
  var nodes: mutable.ArrayBuffer[ENode] = mutable.ArrayBuffer()
  var parents: mutable.ArrayBuffer[(ENode, Int)] = mutable.ArrayBuffer()
  var const: Option[BigInt] = None

/** Raised when the analysis proves two merged classes have different constant values:
  * the only way that can happen is an unsound rewrite rule. */
final case class UnsoundMerge(a: Int, b: Int, va: BigInt, vb: BigInt)
    extends Exception(s"unsound merge: class $a = $va but class $b = $vb")

/** egg-style e-graph: hashcons + union-find, deferred congruence-closure "rebuild",
  * and an e-class analysis (constant folding) that is propagated upward and
  * materialised as Num nodes. */
final class EGraph:
  private val uf = mutable.ArrayBuffer[Int]()
  private val ufSize = mutable.ArrayBuffer[Int]()
  val memo = mutable.HashMap[ENode, Int]()
  val classes = mutable.LinkedHashMap[Int, EClass]()
  private val pending = mutable.ArrayBuffer[(ENode, Int)]()
  private val analysisPending = mutable.ArrayBuffer[(ENode, Int)]()
  var unionCount = 0L
  var totalNodes = 0
  var analysisEnabled = true

  def idsAllocated: Int = uf.size
  def classCount: Int = classes.size

  def find(x: Int): Int =
    var a = x
    while uf(a) != a do
      uf(a) = uf(uf(a))
      a = uf(a)
    a

  def canon(n: ENode): ENode = n.mapKids(find)
  def lookup(n: ENode): Option[Int] = memo.get(canon(n)).map(find)
  def constOf(id: Int): Option[BigInt] = classes(find(id)).const
  def apply(id: Int): EClass = classes(find(id))

  private def makeConst(n: ENode): Option[BigInt] =
    if !analysisEnabled then
      n.op match { case Op.Num(v) => Some(v); case _ => None }
    else n.op match
      case Op.Num(v) => Some(v)
      case Op.Var(_) => None
      case op =>
        val vs = new Array[BigInt](n.kids.length)
        var i = 0
        var ok = true
        while ok && i < vs.length do
          classes(find(n.kids(i))).const match
            case Some(v) => vs(i) = v
            case None    => ok = false
          i += 1
        if ok then Op.eval(op, vs) else None

  private def mergeConst(ida: Int, a: Option[BigInt], idb: Int, b: Option[BigInt]): Option[BigInt] = (a, b) match
    case (Some(x), Some(y)) if x != y => throw UnsoundMerge(ida, idb, x, y)
    case _                            => a.orElse(b)

  def add(n0: ENode): Int =
    val n = canon(n0)
    memo.get(n) match
      case Some(id) => find(id)
      case None =>
        val id = uf.size
        uf += id; ufSize += 1
        val c = EClass(id)
        c.nodes += n
        totalNodes += 1
        classes(id) = c
        var i = 0
        while i < n.kids.length do
          val k = n.kids(i)
          // register as parent once per distinct child
          var dup = false
          var j = 0
          while j < i do { if n.kids(j) == k then dup = true; j += 1 }
          if !dup then classes(k).parents += ((n, id))
          i += 1
        memo(n) = id
        c.const = makeConst(n)
        modify(id)
        find(id)

  def addTerm(t: Term): Int = add(ENode(t.op, t.kids.map(addTerm).toArray))

  /** Analysis hook: a class with a known constant also gets the literal Num node. */
  private def modify(id0: Int): Unit =
    val id = find(id0)
    val c = classes(id)
    c.const match
      case Some(v) =>
        val lit = Op.Num(v)
        if !c.nodes.exists(_.op == lit) then
          val nid = add(ENode.leaf(lit))
          union(id, nid)
        // prune: once a class is known to be a constant, its operator nodes add nothing
        // but matching work (egg's constant-folding trick). Leaves are kept.
        val k = classes(find(id))
        if k.nodes.exists(_.kids.nonEmpty) then
          val before = k.nodes.size
          k.nodes.filterInPlace(_.kids.isEmpty)
          totalNodes -= before - k.nodes.size
      case None =>

  def union(a0: Int, b0: Int): Boolean =
    var a = find(a0)
    var b = find(b0)
    if a == b then return false
    if ufSize(a) < ufSize(b) then { val t = a; a = b; b = t }
    val ca = classes(a)
    val cb = classes(b)
    val merged = mergeConst(a, ca.const, b, cb.const)
    uf(b) = a
    ufSize(a) += ufSize(b)
    unionCount += 1
    pending ++= cb.parents
    if merged != ca.const then analysisPending ++= ca.parents
    if merged != cb.const then analysisPending ++= cb.parents
    ca.const = merged
    ca.nodes ++= cb.nodes
    ca.parents ++= cb.parents
    classes.remove(b)
    modify(a)
    true

  /** Restore the hashcons and congruence invariants after a batch of unions. */
  def rebuild(): Int =
    var repairs = 0
    while pending.nonEmpty || analysisPending.nonEmpty do
      while pending.nonEmpty do
        val (node, cls) = pending.remove(pending.size - 1)
        val cn = canon(node)
        memo.put(cn, cls) match
          case Some(old) => if union(old, cls) then repairs += 1
          case None      =>
      while analysisPending.nonEmpty do
        val (node, cls0) = analysisPending.remove(analysisPending.size - 1)
        val cls = find(cls0)
        val c = classes(cls)
        val merged = mergeConst(cls, c.const, cls, makeConst(canon(node)))
        if merged != c.const then
          c.const = merged
          analysisPending ++= c.parents
          modify(cls)
    rebuildClasses()
    repairs

  private def rebuildClasses(): Unit =
    var total = 0
    for c <- classes.valuesIterator do
      val seen = mutable.LinkedHashSet[ENode]()
      c.nodes.foreach(n => seen += canon(n))
      c.nodes = mutable.ArrayBuffer.from(seen)
      total += c.nodes.size
      val ps = mutable.LinkedHashSet[(ENode, Int)]()
      c.parents.foreach((n, p) => ps += ((canon(n), find(p))))
      c.parents = mutable.ArrayBuffer.from(ps)
    totalNodes = total

  /** Classes that contain at least one node with operator `op`, for e-matching. */
  def opIndex(): mutable.HashMap[Op, mutable.ArrayBuffer[Int]] =
    val idx = mutable.HashMap[Op, mutable.ArrayBuffer[Int]]()
    for c <- classes.valuesIterator do
      val ops = mutable.HashSet[Op]()
      c.nodes.foreach(n => ops += n.op)
      ops.foreach(op => idx.getOrElseUpdate(op, mutable.ArrayBuffer()) += c.id)
    idx

  /** Full invariant audit (used by the test suite): returns a list of violations. */
  def checkInvariants(): List[String] =
    val errs = mutable.ListBuffer[String]()
    val owner = mutable.HashMap[ENode, Int]()
    for c <- classes.valuesIterator do
      if find(c.id) != c.id then errs += s"class ${c.id} is not canonical"
      for n <- c.nodes do
        if canon(n) != n then errs += s"node $n in class ${c.id} not canonical"
        owner.put(n, c.id) match
          case Some(o) if o != c.id => errs += s"congruence violated: $n in both $o and ${c.id}"
          case _ =>
        memo.get(n).map(find) match
          case Some(m) if m == c.id =>
          case other => errs += s"memo maps $n to $other, expected ${c.id}"
        for k <- n.kids.distinct do
          if !classes.contains(k) then errs += s"dangling child $k"
          else if !classes(k).parents.exists((pn, pc) => pn == n && find(pc) == c.id) then
            errs += s"missing parent edge $n -> class $k"
        if analysisEnabled then
          makeConst(n) match
            case Some(v) if !c.const.contains(v) => errs += s"analysis stale: $n folds to $v but class has ${c.const}"
            case _ =>
      c.const.foreach(v => if !c.nodes.exists(_.op == Op.Num(v)) then errs += s"class ${c.id} const $v not materialised")
    errs.toList

  /** Graphviz rendering: one cluster per e-class, edges from e-nodes to child classes. */
  def toDot(highlight: Set[Int] = Set.empty): String =
    val sb = StringBuilder()
    sb ++= "digraph egraph {\n  compound=true; rankdir=TB; newrank=true;\n"
    sb ++= "  node [shape=box, style=\"rounded,filled\", fillcolor=\"#ffffff\", fontname=\"Helvetica\", fontsize=13];\n"
    sb ++= "  edge [color=\"#4a5568\", arrowsize=0.6];\n"
    for c <- classes.valuesIterator do
      val fill = if highlight.contains(c.id) then "#fde68a" else "#e8eef9"
      sb ++= s"  subgraph cluster_${c.id} {\n    style=\"rounded,filled\"; color=\"#94a3b8\"; fillcolor=\"$fill\"; label=\"e${c.id}\"; fontname=\"Helvetica\"; fontsize=10;\n"
      c.nodes.zipWithIndex.foreach((n, i) => sb ++= s"    n${c.id}_$i [label=\"${n.op.sym}\"];\n")
      if c.nodes.isEmpty then sb ++= s"    n${c.id}_0 [label=\"\", style=invis];\n"
      sb ++= "  }\n"
    for c <- classes.valuesIterator; (n, i) <- c.nodes.zipWithIndex; (k, j) <- n.kids.zipWithIndex do
      val kc = find(k)
      val lab = if n.kids.length > 1 then s", taillabel=\"${j}\", labelfontsize=8" else ""
      sb ++= s"  n${c.id}_$i -> n${kc}_0 [lhead=cluster_$kc$lab];\n"
    sb ++= "}\n"
    sb.toString
