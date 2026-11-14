# frozen_string_literal: true

module Garnet
  # A name-resolution scope: the FROM sources of one SELECT, plus a link to
  # the enclosing query for correlated subqueries.
  #
  # At run time a query works on an "env" array: env[i] is the current row
  # of source i, env[n] holds aggregate results, env[n + 1] is the outer
  # query's env.
  class Scope
    Source = Struct.new(:name, :meta, :cols, :affs, :sub, keyword_init: true) do
      def ncols = cols.size
      def null_row = @null_row ||= Array.new(ncols + 1)
    end

    attr_reader :sources, :parent
    attr_accessor :correlated

    def initialize(sources, parent = nil)
      @sources = sources
      @parent = parent
      @correlated = false
    end

    def n = @sources.size

    # -> [depth, source index, column index, affinity]
    def resolve(tbl, name, depth = 0)
      hits = []
      @sources.each_with_index do |s, si|
        next if tbl && !s.name.casecmp?(tbl)
        ci = s.cols.index { |c| c.casecmp?(name) }
        if ci
          hits << [si, ci, s.affs[ci]]
        elsif s.meta && %w[rowid oid _rowid_].include?(name.downcase)
          hits << [si, s.ncols, :integer]
        end
      end
      raise Error, "ambiguous column name: #{name}" if hits.size > 1
      return [depth, *hits[0]] if hits.size == 1
      if @parent
        r = @parent.resolve(tbl, name, depth + 1)
        @correlated = true
        return r
      end
      raise Error, "no such column: #{tbl ? "#{tbl}." : ''}#{name}"
    end
  end

  # Compiles expression ASTs into Ruby lambdas over an env.
  class Compiler
    AGGREGATES = %w[count sum avg min max total group_concat].freeze

    def initialize(db)
      @db = db
    end

    def aggregate_call?(e)
      e[0] == :fn && AGGREGATES.include?(e[1]) &&
        (e[4] || (e[1] == "group_concat" ? e[2].size.between?(1, 2) : e[2].size == 1))
    end

    def contains_aggregate?(x)
      return false unless x.is_a?(Array)
      return x.any? { |y| contains_aggregate?(y) } unless x[0].is_a?(Symbol)
      return true if aggregate_call?(x)
      return contains_aggregate?(x[1]) if x[0] == :insub
      x[1..].any? { |y| contains_aggregate?(y) }
    end

    # Static affinity of an expression (nil = "no affinity").
    def affinity(e, sc)
      case e[0]
      when :col then sc.resolve(e[1], e[2])[3]
      when :cast then Ops.affinity_of(e[2])
      end
    end

    # Which sources of the current scope does this expression read?
    # Subqueries are treated conservatively as reading everything.
    def mask(x, sc, acc = {})
      return acc unless x.is_a?(Array)
      unless x[0].is_a?(Symbol)
        x.each { |y| mask(y, sc, acc) }
        return acc
      end
      case x[0]
      when :col
        d, s = sc.resolve(x[1], x[2])
        acc[s] = true if d.zero?
      when :subq, :exists, :insub
        mask(x[1], sc, acc) if x[0] == :insub
        sc.n.times { |i| acc[i] = true }
      else
        x[1..].each { |y| mask(y, sc, acc) }
      end
      acc
    end

    # aggs: nil when aggregates are not allowed, otherwise an array that
    # collects aggregate specs; their results live in env[n].
    def compile(e, sc, aggs = nil)
      case e[0]
      when :lit
        v = e[1]
        ->(_) { v }
      when :col
        d, s, c = sc.resolve(e[1], e[2])
        return ->(env) { env[s][c] } if d.zero?
        hops = []
        x = sc
        d.times do
          hops << x.n + 1
          x = x.parent
        end
        ->(env) { hops.each { |h| env = env[h] }; env[s][c] }
      when :neg
        f = compile(e[1], sc, aggs)
        ->(env) { Ops.arith("-", 0, f.(env)) }
      when :not
        f = compile(e[1], sc, aggs)
        ->(env) { t = Ops.truthy(f.(env)); t.nil? ? nil : (t ? 0 : 1) }
      when :bin then compile_bin(e, sc, aggs)
      when :is
        l = compile(e[1], sc, aggs)
        r = compile(e[2], sc, aggs)
        cl, cr = Ops.comparison_coercions(affinity(e[1], sc), affinity(e[2], sc))
        neg = e[3]
        lambda do |env|
          a = l.(env)
          b = r.(env)
          eq = if a.nil? || b.nil? then a.nil? && b.nil?
               else Values.cmp(Ops.coerce(cl, a), Ops.coerce(cr, b)).zero?
               end
          eq ^ neg ? 1 : 0
        end
      when :between
        x = compile(e[1], sc, aggs)
        lo = compile(e[2], sc, aggs)
        hi = compile(e[3], sc, aggs)
        xa = affinity(e[1], sc)
        c1 = Ops.comparison_coercions(xa, affinity(e[2], sc))
        c2 = Ops.comparison_coercions(xa, affinity(e[3], sc))
        neg = e[4]
        lambda do |env|
          v = x.(env)
          a = lo.(env)
          b = hi.(env)
          r1 = v.nil? || a.nil? ? nil : Values.cmp(Ops.coerce(c1[0], v), Ops.coerce(c1[1], a)) >= 0
          r2 = v.nil? || b.nil? ? nil : Values.cmp(Ops.coerce(c2[0], v), Ops.coerce(c2[1], b)) <= 0
          r = if r1 == false || r2 == false then false
              elsif r1.nil? || r2.nil? then nil
              else true
              end
          r.nil? ? nil : (r ^ neg ? 1 : 0)
        end
      when :in
        x = compile(e[1], sc, aggs)
        xa = affinity(e[1], sc)
        items = e[2].map { |it| [compile(it, sc, aggs), Ops.comparison_coercions(xa, affinity(it, sc))] }
        neg = e[3]
        lambda do |env|
          v = x.(env)
          next nil if v.nil?
          found = false
          saw_null = false
          items.each do |f, (cl, cr)|
            w = f.(env)
            if w.nil?
              saw_null = true
            elsif Values.cmp(Ops.coerce(cl, v), Ops.coerce(cr, w)).zero?
              found = true
              break
            end
          end
          r = found ? true : (saw_null ? nil : false)
          r.nil? ? nil : (r ^ neg ? 1 : 0)
        end
      when :insub
        x = compile(e[1], sc, aggs)
        q = @db.plan_query(e[2], sc)
        raise Error, "sub-select returns #{q.columns.size} columns - expected 1" if q.columns.size != 1
        cl, cr = Ops.comparison_coercions(affinity(e[1], sc), q.column_affs[0])
        neg = e[3]
        cache = nil
        lambda do |env|
          set = cache
          unless set
            set = {}
            q.rows(env).each { |row| set[row[0].nil? ? :null : Ops.norm(Ops.coerce(cr, row[0]))] = true }
            cache = set unless q.correlated
          end
          v = x.(env)
          next(set.empty? ? (neg ? 1 : 0) : nil) if v.nil?
          r = set.key?(Ops.norm(Ops.coerce(cl, v))) ? true : (set.key?(:null) ? nil : false)
          r.nil? ? nil : (r ^ neg ? 1 : 0)
        end
      when :like
        x = compile(e[1], sc, aggs)
        neg = e[3]
        if e[2][0] == :lit && e[2][1].is_a?(String)
          re = Ops.like_regex(e[2][1])
          ->(env) { v = x.(env); v.nil? ? nil : (re.match?(Ops.to_text(v)) ^ neg ? 1 : 0) }
        else
          pf = compile(e[2], sc, aggs)
          lambda do |env|
            v = x.(env)
            pat = pf.(env)
            next nil if v.nil? || pat.nil?
            Ops.like_regex(Ops.to_text(pat)).match?(Ops.to_text(v)) ^ neg ? 1 : 0
          end
        end
      when :case
        base = e[1] && compile(e[1], sc, aggs)
        whens = e[2].map { |w, t| [compile(w, sc, aggs), compile(t, sc, aggs)] }
        els = e[3] ? compile(e[3], sc, aggs) : ->(_) {}
        lambda do |env|
          if base
            b = base.(env)
            unless b.nil?
              whens.each { |w, t| (wv = w.(env)).nil? || !Values.cmp(b, wv).zero? || (return t.(env)) }
            end
          else
            whens.each { |w, t| return t.(env) if Ops.truthy(w.(env)) }
          end
          els.(env)
        end
      when :cast
        x = compile(e[1], sc, aggs)
        type = e[2]
        aff = Ops.affinity_of(type)
        lambda do |env|
          v = x.(env)
          next nil if v.nil?
          case aff
          when :integer then (n = Ops.to_num(v)).is_a?(Float) ? n.truncate : n
          when :real then Ops.to_num(v).to_f
          when :text, :blob then Ops.to_text(v)
          else Ops.apply_affinity(v.is_a?(String) ? Ops.to_num(v) : v, :numeric)
          end
        end
      when :subq
        q = @db.plan_query(e[1], sc)
        cache = nil
        done = false
        lambda do |env|
          next cache if done
          r = nil
          q.rows(env, 1).each { |row| r = row[0]; break }
          unless q.correlated
            cache = r
            done = true
          end
          r
        end
      when :exists
        q = @db.plan_query(e[1], sc)
        cache = nil
        lambda do |env|
          next cache if cache
          r = q.rows(env, 1).empty? ? 0 : 1
          cache = r unless q.correlated
          r
        end
      when :fn then compile_fn(e, sc, aggs)
      when :star then raise Error, "* is not allowed here"
      else raise Error, "cannot compile #{e[0]}"
      end
    end

    COMPARE = {
      "=" => ->(c) { c.zero? }, "!=" => ->(c) { !c.zero? }, "<" => ->(c) { c.negative? },
      "<=" => ->(c) { c <= 0 }, ">" => ->(c) { c.positive? }, ">=" => ->(c) { c >= 0 }
    }.freeze

    def compile_bin(e, sc, aggs)
      op = e[1]
      l = compile(e[2], sc, aggs)
      r = compile(e[3], sc, aggs)
      case op
      when "and"
        lambda do |env|
          a = Ops.truthy(l.(env))
          return 0 if a == false
          b = Ops.truthy(r.(env))
          return 0 if b == false
          a.nil? || b.nil? ? nil : 1
        end
      when "or"
        lambda do |env|
          a = Ops.truthy(l.(env))
          return 1 if a
          b = Ops.truthy(r.(env))
          return 1 if b
          a.nil? || b.nil? ? nil : 0
        end
      when "||"
        lambda do |env|
          a = l.(env)
          b = r.(env)
          a.nil? || b.nil? ? nil : "#{Ops.to_text(a)}#{Ops.to_text(b)}"
        end
      when "+", "-", "*", "/", "%"
        ->(env) { Ops.arith(op, l.(env), r.(env)) }
      else
        test = COMPARE.fetch(op)
        cl, cr = Ops.comparison_coercions(affinity(e[2], sc), affinity(e[3], sc))
        if cl.nil? && cr.nil?
          lambda do |env|
            a = l.(env)
            return nil if a.nil?
            b = r.(env)
            return nil if b.nil?
            test.(Values.cmp(a, b)) ? 1 : 0
          end
        else
          lambda do |env|
            a = l.(env)
            return nil if a.nil?
            b = r.(env)
            return nil if b.nil?
            test.(Values.cmp(Ops.coerce(cl, a), Ops.coerce(cr, b))) ? 1 : 0
          end
        end
      end
    end

    def compile_fn(e, sc, aggs)
      _, name, args, distinct, star = e
      if aggregate_call?(e)
        raise Error, "misuse of aggregate function #{name}()" if aggs.nil?
        raise Error, "aggregate functions cannot be nested" if args.any? { |a| contains_aggregate?(a) }
        argf = args.map { |a| compile(a, sc, nil) }
        k = aggs.size
        aggs << { name: name, distinct: distinct, star: star, args: argf }
        n = sc.n
        return ->(env) { env[n][k] }
      end
      f = args.map { |a| compile(a, sc, aggs) }
      arity = ->(*ok) { ok.include?(f.size) or raise Error, "wrong number of arguments to function #{name}()" }
      case name
      when "abs"
        arity.(1)
        ->(env) { v = f[0].(env); v.nil? ? nil : (v.is_a?(String) ? Ops.to_num(v).to_f.abs : v.abs) }
      when "length"
        arity.(1)
        ->(env) { v = f[0].(env); v.nil? ? nil : Ops.to_text(v).length }
      when "upper"
        arity.(1)
        ->(env) { v = f[0].(env); v.nil? ? nil : Ops.to_text(v).upcase(:ascii) }
      when "lower"
        arity.(1)
        ->(env) { v = f[0].(env); v.nil? ? nil : Ops.to_text(v).downcase(:ascii) }
      when "coalesce", "ifnull"
        raise Error, "wrong number of arguments to function #{name}()" if f.size < 2 || (name == "ifnull" && f.size != 2)
        ->(env) { f.each { |g| v = g.(env); return v unless v.nil? }; nil }
      when "nullif"
        arity.(2)
        ->(env) { a = f[0].(env); b = f[1].(env); !a.nil? && !b.nil? && Values.cmp(a, b).zero? ? nil : a }
      when "iif"
        arity.(3)
        ->(env) { Ops.truthy(f[0].(env)) ? f[1].(env) : f[2].(env) }
      when "min", "max"
        raise Error, "wrong number of arguments to function #{name}()" if f.size < 2
        want = name == "min" ? -1 : 1
        lambda do |env|
          best = nil
          f.each_with_index do |g, i|
            v = g.(env)
            return nil if v.nil?
            best = v if i.zero? || Values.cmp(v, best) == want
          end
          best
        end
      when "typeof"
        arity.(1)
        ->(env) { { NilClass => "null", Integer => "integer", Float => "real", String => "text" }[f[0].(env).class] }
      when "round"
        arity.(1, 2)
        lambda do |env|
          v = f[0].(env)
          return nil if v.nil?
          d = f[1] ? Ops.to_num(f[1].(env)).to_i : 0
          x = Ops.to_num(v).to_f
          (x.abs * 10**d + 0.5).floor.fdiv(10**d) * (x.negative? ? -1 : 1)
        end
      when "substr", "substring"
        arity.(2, 3)
        lambda do |env|
          s = f[0].(env)
          st = f[1].(env)
          len = f[2]&.(env)
          return nil if s.nil? || st.nil? || (f[2] && len.nil?)
          s = Ops.to_text(s)
          st = Ops.to_num(st).to_i
          len = len.nil? ? s.length + 1 : Ops.to_num(len).to_i
          st = s.length + st + 1 if st.negative?
          if len.negative?
            st += len
            len = -len
          end
          if st < 1
            len += st - 1
            st = 1
          end
          len.positive? ? s[st - 1, len] || "" : ""
        end
      when "instr"
        arity.(2)
        ->(env) { a = f[0].(env); b = f[1].(env); a.nil? || b.nil? ? nil : (Ops.to_text(a).index(Ops.to_text(b)) || -1) + 1 }
      when "replace"
        arity.(3)
        lambda do |env|
          a, b, c = f.map { |g| g.(env) }
          return nil if a.nil? || b.nil? || c.nil?
          b = Ops.to_text(b)
          b.empty? ? Ops.to_text(a) : Ops.to_text(a).gsub(b, Ops.to_text(c))
        end
      when "trim", "ltrim", "rtrim"
        arity.(1)
        ->(env) { v = f[0].(env); v.nil? ? nil : Ops.to_text(v).then { |s| name == "trim" ? s.strip : (name == "ltrim" ? s.lstrip : s.rstrip) } }
      when "random"
        arity.(0)
        ->(_) { rand(-2**63...2**63) }
      else
        raise Error, "no such function: #{name}"
      end
    end
  end

  # Aggregate accumulators.
  class Accumulator
    def initialize(spec)
      @spec = spec
      @name = spec[:name]
      @seen = spec[:distinct] ? {} : nil
      @count = 0
      @sum = 0
      @float = false
      @best = nil
      @parts = []
    end

    def step(env)
      if @spec[:star]
        @count += 1
        return
      end
      v = @spec[:args][0].(env)
      return if v.nil?
      if @seen
        k = Ops.norm(v)
        return if @seen.key?(k)
        @seen[k] = true
      end
      @count += 1
      case @name
      when "sum", "avg", "total"
        # like SQLite: integer-looking text sums as an integer; any other
        # text is read as a real number from its numeric prefix
        n = v.is_a?(String) ? ((x = Ops.strict_number(v)).is_a?(Integer) ? x : Ops.to_num(v).to_f) : v
        @float ||= n.is_a?(Float)
        @sum += n
      when "min" then @best = v if @best.nil? || Values.cmp(v, @best).negative?
      when "max" then @best = v if @best.nil? || Values.cmp(v, @best).positive?
      when "group_concat"
        sep = @spec[:args][1] ? Ops.to_text(@spec[:args][1].(env)) : ","
        @parts << sep unless @parts.empty?
        @parts << Ops.to_text(v)
      end
    end

    def result
      case @name
      when "count" then @count
      when "sum" then @count.zero? ? nil : (@float ? @sum.to_f : Ops.fix_int(@sum))
      when "total" then @sum.to_f
      when "avg" then @count.zero? ? nil : @sum.to_f / @count
      when "min", "max" then @best
      when "group_concat" then @count.zero? ? nil : @parts.join
      end
    end
  end
end
