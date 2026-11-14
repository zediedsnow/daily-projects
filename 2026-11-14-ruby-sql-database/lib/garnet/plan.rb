# frozen_string_literal: true

module Garnet
  # Shared helpers for query plans.
  module PlanHelpers
    def truthy?(f, env) = Ops.truthy(f.(env)) == true

    def eval_count(expr, label)
      return nil unless expr
      v = @db.compiler.compile(expr, Scope.new([]), nil).(nil)
      return nil if v.nil?
      n = Ops.to_num(v)
      raise Error, "datatype mismatch in #{label}" unless n.is_a?(Integer) || n == n.to_i
      n.to_i
    end

    # rows: [[out, keys], ...]; descs[k] tells whether keys[k] sorts descending.
    def sort_rows!(rows, descs)
      return rows if descs.empty?
      rows.each_with_index { |r, i| r << i }
      rows.sort! do |a, b|
        c = 0
        descs.each_with_index do |desc, k|
          c = Values.cmp(a[1][k], b[1][k])
          c = -c if desc
          break unless c.zero?
        end
        c.zero? ? a[-1] <=> b[-1] : c
      end
    end

    def explain(lines = [], indent = 0)
      @notes.each { |l| lines << ("  " * indent) + l }
      @children.each do |kind, child|
        lines << ("  " * indent) + kind
        child.explain(lines, indent + 1)
      end
      lines
    end

    def add_child(kind, plan) = @children << [kind, plan]
  end

  # Plan for a single SELECT core (FROM ... WHERE ... GROUP BY ...).
  class SelectPlan
    include PlanHelpers
    attr_reader :columns, :column_affs, :correlated, :scope

    Step = Struct.new(:src, :kind, :access, :filters, :match, :post, keyword_init: true)

    def initialize(db, sel, parent_scope)
      @db = db
      @notes = []
      @children = []
      c = db.compiler
      db.building(self) do
        sources = sel[:from].map do |f|
          if f[:sub]
            sub = db.plan_query(f[:sub], parent_scope, "SUBQUERY #{f[:alias]}")
            Scope::Source.new(name: f[:alias], meta: nil, cols: sub.columns, affs: sub.column_affs, sub: sub)
          else
            meta = db.table_meta(f[:table])
            Scope::Source.new(name: f[:alias], meta: meta, cols: meta[:cols].map { |x| x[:name] },
                              affs: meta[:cols].map { |x| x[:aff] }, sub: nil)
          end
        end
        names = sources.map { |s| s.name.downcase }
        dup = names.find { |nm| names.count(nm) > 1 }
        raise Error, "ambiguous table name: #{dup}" if dup
        @scope = sc = Scope.new(sources, parent_scope)
        @n = sc.n

        # expand * and t.*
        items = []
        sel[:cols].each do |e, as|
          if e[0] == :star
            raise Error, "no tables specified" if sources.empty?
            hit = false
            sources.each_with_index do |s, si|
              next if e[1] && !s.name.casecmp?(e[1])
              hit = true
              s.cols.each { |cn| items << [[:col, s.name, cn], cn] }
            end
            raise Error, "no such table: #{e[1]}" unless hit
          else
            items << [e, as || (e[0] == :col ? e[2] : Unparse.expr(e))]
          end
        end
        @columns = items.map { |_, nm| nm }
        @column_affs = items.map { |e, _| c.affinity(e, sc) }

        @agg_mode = !sel[:group].nil? || items.any? { |e, _| c.contains_aggregate?(e) } ||
                    (sel[:having] && c.contains_aggregate?(sel[:having])) ||
                    (sel[:order] || []).any? { |e, _| c.contains_aggregate?(e) }
        raise Error, "a GROUP BY clause is required before HAVING" if sel[:having] && !@agg_mode
        raise Error, "misuse of aggregate in WHERE" if sel[:where] && c.contains_aggregate?(sel[:where])

        build_steps(sel, sc)

        @aggs = @agg_mode ? [] : nil
        @out = items.map { |e, _| c.compile(e, sc, @aggs) }
        @having = sel[:having] && c.compile(sel[:having], sc, @aggs)
        @group = (sel[:group] || []).map do |g|
          raise Error, "aggregate functions are not allowed in GROUP BY" if c.contains_aggregate?(g)
          if g[0] == :lit && g[1].is_a?(Integer)
            raise Error, "GROUP BY term out of range" unless g[1].between?(1, items.size)
            c.compile(items[g[1] - 1][0], sc, nil)
          else
            c.compile(g, sc, nil)
          end
        end
        # ORDER BY: ordinal, output alias, or an expression
        @order = (sel[:order] || []).map do |e, desc|
          if e[0] == :lit && e[1].is_a?(Integer)
            raise Error, "ORDER BY term out of range" unless e[1].between?(1, items.size)
            [e[1] - 1, desc]
          elsif e[0] == :col && e[1].nil? && (k = items.index { |_, nm| nm.casecmp?(e[2]) })
            [k, desc]
          else
            [c.compile(e, sc, @aggs), desc]
          end
        end
        @distinct = sel[:distinct]
        @limit = eval_count(sel[:limit], "LIMIT")
        @offset = eval_count(sel[:offset], "OFFSET") || 0
        @correlated = sc.correlated || sources.any? { |s| s.sub&.correlated }

        @notes << "USE HASH TABLE FOR GROUP BY" if @group.any?
        @notes << "USE HASH TABLE FOR DISTINCT" if @distinct
        @notes << "SORT RESULTS FOR ORDER BY" if @order.any?
        @notes << "CORRELATED: re-run for every outer row" if sc.correlated
      end
    end

    # ---------------------------------------------------------- planning

    def conjuncts(e, acc = [])
      return acc if e.nil?
      if e[0] == :bin && e[1] == "and"
        conjuncts(e[2], acc)
        conjuncts(e[3], acc)
      else
        acc << e
      end
      acc
    end

    FLIP = { "=" => "=", "<" => ">", "<=" => ">=", ">" => "<", ">=" => "<=" }.freeze

    # Find an access path for source i using the given condition ASTs.
    def choose_access(i, conds, sc)
      c = @db.compiler
      src = sc.sources[i]
      cands = []
      conds.each do |e|
        forms = []
        if e[0] == :bin && FLIP.key?(e[1])
          forms << [e[2], e[1], e[3]] << [e[3], FLIP[e[1]], e[2]]
        elsif e[0] == :between && !e[4]
          forms << [e[1], ">=", e[2]] << [e[1], "<=", e[3]]
        end
        forms.each do |col, op, other|
          next unless col[0] == :col
          d, s, ci, caff = sc.resolve(col[1], col[2])
          next unless d.zero? && s == i
          om = c.mask(other, sc)
          next if om.key?(i)
          cl, cr = Ops.comparison_coercions(caff, c.affinity(other, sc))
          next if cl # the column side would be converted: an index cannot help
          f = c.compile(other, sc)
          meta = src.meta
          if meta && (ci == src.ncols || ci == meta[:pk])
            cands << [op == "=" ? 0 : 3, :rowid, ci, op, f, cr, nil]
          elsif meta && (ix = meta[:indexes].find { |x| x[:col] == ci })
            cands << [op == "=" ? (ix[:unique] ? 1 : 2) : 4, :index, ci, op, f, cr, ix]
          elsif op == "=" && !om.empty? && (meta || !src.sub.correlated)
            cands << [5, :hash, ci, op, f, cr, nil]
          end
        end
      end
      best = cands.min_by { |x| x[0] }
      return scan_access(i, src) unless best
      _, kind, ci, op, f, cr, ix = best
      colname = ci == src.ncols ? "rowid" : src.cols[ci]
      case kind
      when :hash then hash_access(i, src, ci, f, cr, colname)
      when :rowid, :index
        if op == "="
          kind == :rowid ? rowid_eq(src, f, cr, colname) : index_eq(src, ix, f, cr, colname)
        else
          # gather all range bounds on this column
          lo = hi = nil
          cands.each do |_, k2, c2, op2, f2, cr2|
            next unless k2 == kind && c2 == ci
            lo ||= [f2, cr2, op2] if op2.start_with?(">")
            hi ||= [f2, cr2, op2] if op2.start_with?("<")
          end
          range_access(src, kind, ix, lo, hi, colname)
        end
      end
    end

    def table_rows(src)
      tree = BTree.new(@db.pager, src.meta[:root])
      ->(&blk) { tree.each { |_, v| blk.(@db.load_row(v)) } }
    end

    def scan_access(i, src)
      if src.sub
        @notes << "SCAN SUBQUERY #{src.name}"
        sub = src.sub
        cache = nil
        n = @n
        return lambda do |env, &blk|
          rows = cache || sub.rows(env[n + 1])
          cache = rows unless sub.correlated
          rows.each(&blk)
        end
      end
      @notes << "SCAN #{src.name}"
      tree = BTree.new(@db.pager, src.meta[:root])
      db = @db
      ->(_env, &blk) { tree.each { |_, v| blk.(db.load_row(v)) } }
    end

    def rowid_eq(src, f, cr, colname)
      @notes << "SEARCH #{src.name} USING INTEGER PRIMARY KEY (#{colname}=?)"
      tree = BTree.new(@db.pager, src.meta[:root])
      db = @db
      lambda do |env, &blk|
        v = Ops.coerce(cr, f.(env))
        next unless v.is_a?(Numeric)
        next if v.is_a?(Float) && v != v.floor
        found, row = tree.get(v.to_i)
        blk.(db.load_row(row)) if found
      end
    end

    def index_eq(src, ix, f, cr, colname)
      @notes << "SEARCH #{src.name} USING #{ix[:unique] ? 'UNIQUE ' : ''}INDEX #{ix[:name]} (#{colname}=?)"
      tree = BTree.new(@db.pager, src.meta[:root])
      itree = BTree.new(@db.pager, ix[:root])
      db = @db
      lambda do |env, &blk|
        v = Ops.coerce(cr, f.(env))
        next if v.nil?
        itree.each([v, :min]) do |k, _|
          break unless Values.cmp(k[0], v).zero?
          blk.(db.load_row(tree.get(k[1])[1]))
        end
      end
    end

    def range_access(src, kind, ix, lo, hi, colname)
      bounds = [lo && "#{colname}#{lo[2]}?", hi && "#{colname}#{hi[2]}?"].compact.join(" AND ")
      @notes << if kind == :rowid
                  "SEARCH #{src.name} USING INTEGER PRIMARY KEY (#{bounds})"
                else
                  "SEARCH #{src.name} USING INDEX #{ix[:name]} (#{bounds})"
                end
      tree = BTree.new(@db.pager, src.meta[:root])
      itree = ix && BTree.new(@db.pager, ix[:root])
      db = @db
      lambda do |env, &blk|
        lv = lo && Ops.coerce(lo[1], lo[0].(env))
        hv = hi && Ops.coerce(hi[1], hi[0].(env))
        next if (lo && lv.nil?) || (hi && hv.nil?)
        if kind == :rowid
          # rowids are integers: a text bound makes the range trivial,
          # so fall back to a scan and let the filters decide
          if (lo && !lv.is_a?(Numeric)) || (hi && !hv.is_a?(Numeric))
            tree.each { |_, v| blk.(db.load_row(v)) }
            next
          end
          start = lo ? lv.floor : nil
          tree.each(start) do |k, v|
            break if hi && k > hv
            blk.(db.load_row(v))
          end
        else
          itree.each(lo ? [lv, :min] : [nil, :max]) do |k, _|
            break if hi && Values.cmp(k[0], hv).positive?
            blk.(db.load_row(tree.get(k[1])[1]))
          end
        end
      end
    end

    def hash_access(i, src, ci, f, cr, colname)
      @notes << "HASH JOIN #{src.name} (#{colname}=?)"
      base = scan_access(i, src)
      @notes.pop
      table = nil
      lambda do |env, &blk|
        unless table
          table = Hash.new { |h, k| h[k] = [] }
          base.(env) { |row| (v = row[ci]).nil? || table[Ops.norm(v)] << row }
        end
        v = Ops.coerce(cr, f.(env))
        next if v.nil?
        rows = table.fetch(Ops.norm(v), nil)
        rows&.each(&blk)
      end
    end

    def build_steps(sel, sc)
      c = @db.compiler
      pending = [] # [ast, mask(max index)]
      add = lambda do |e|
        m = c.mask(e, sc).keys
        pending << [e, m.max || 0]
      end
      conjuncts(sel[:where]).each(&add)
      sel[:from].each { |f| conjuncts(f[:on]).each(&add) if f[:join] != :left }
      @steps = sel[:from].each_with_index.map do |f, i|
        here = pending.select { |_, m| m == i }.map(&:first)
        if f[:join] == :left
          on = conjuncts(f[:on])
          access = choose_access(i, on, sc)
          @notes[-1] = "LEFT JOIN: #{@notes[-1]}"
          Step.new(src: i, kind: :left, access: access, match: on.map { |e| c.compile(e, sc) },
                   post: here.map { |e| c.compile(e, sc) })
        else
          access = choose_access(i, here, sc)
          Step.new(src: i, kind: :inner, access: access, filters: here.map { |e| c.compile(e, sc) })
        end
      end
      @const_filters = @steps.empty? ? pending.map { |e, _| c.compile(e, sc) } : []
    end

    # ---------------------------------------------------------- execution

    def each_env(outer, &blk)
      env = Array.new(@n + 2)
      env[@n + 1] = outer
      if @steps.empty?
        yield env if @const_filters.all? { |f| truthy?(f, env) }
      else
        descend(0, env, &blk)
      end
    end

    def descend(k, env, &blk)
      if k == @steps.size
        yield env
        return
      end
      st = @steps[k]
      i = st.src
      if st.kind == :left
        matched = false
        st.access.(env) do |row|
          env[i] = row
          next unless st.match.all? { |f| truthy?(f, env) }
          matched = true
          descend(k + 1, env, &blk) if st.post.all? { |f| truthy?(f, env) }
        end
        unless matched
          env[i] = @scope.sources[i].null_row
          descend(k + 1, env, &blk) if st.post.all? { |f| truthy?(f, env) }
        end
      else
        st.access.(env) do |row|
          env[i] = row
          descend(k + 1, env, &blk) if st.filters.all? { |f| truthy?(f, env) }
        end
      end
    end

    # Run the query; returns an array of output rows.
    def rows(outer = nil, hint = nil)
      results = []
      keyf = lambda do |out, env|
        @order.map { |src, _| src.is_a?(Integer) ? out[src] : src.(env) }
      end
      cap = nil
      cap = @limit + @offset if @limit && @limit >= 0
      cap = [cap || hint, hint].min if hint
      seen = @distinct ? {} : nil
      if @agg_mode
        groups = {}
        each_env(outer) do |env|
          key = @group.map { |g| Ops.norm(g.(env)) }
          entry = groups[key] ||= [nil, @aggs.map { |a| Accumulator.new(a) }]
          entry[0] = env.dup
          entry[1].each { |acc| acc.step(env) }
        end
        if groups.empty? && @group.empty?
          env = Array.new(@n + 2)
          @scope.sources.each_with_index { |s, i| env[i] = s.null_row }
          env[@n + 1] = outer
          groups[[]] = [env, @aggs.map { |a| Accumulator.new(a) }]
        end
        groups.each_value do |env, accs|
          env[@n] = accs.map(&:result)
          next if @having && !truthy?(@having, env)
          out = @out.map { |f| f.(env) }
          if seen
            k = out.map { |v| Ops.norm(v) }
            next if seen.key?(k)
            seen[k] = true
          end
          results << [out, keyf.(out, env)]
        end
      else
        early = @order.empty? && cap
        catch(:enough) do
          each_env(outer) do |env|
            out = @out.map { |f| f.(env) }
            if seen
              k = out.map { |v| Ops.norm(v) }
              next if seen.key?(k)
              seen[k] = true
            end
            results << [out, keyf.(out, env)]
            throw :enough if early && results.size >= cap
          end
        end
      end
      sort_rows!(results, @order.map(&:last))
      rows = results.map(&:first)
      rows = rows.drop(@offset) if @offset.positive?
      rows = rows.first(@limit) if @limit && @limit >= 0
      rows
    end
  end

  # UNION / UNION ALL / INTERSECT / EXCEPT, with ORDER BY / LIMIT applied to
  # the combined result.
  class CompoundPlan
    include PlanHelpers
    attr_reader :columns, :column_affs, :correlated

    def initialize(db, sel, parent_scope)
      @db = db
      @notes = []
      @children = []
      @op = sel[:compound]
      db.building(self) do
        @left = db.plan_query(sel[:left], parent_scope, "LEFT")
        @right = db.plan_query(sel[:right], parent_scope, "#{@op} RIGHT")
      end
      if @left.columns.size != @right.columns.size
        raise Error, "SELECTs to the left and right of #{@op} do not have the same number of result columns"
      end
      @columns = @left.columns
      @column_affs = @left.column_affs
      @correlated = @left.correlated || @right.correlated
      @order = (sel[:order] || []).map do |e, desc|
        k = if e[0] == :lit && e[1].is_a?(Integer) then e[1] - 1
            elsif e[0] == :col then @columns.index { |nm| nm.casecmp?(e[2]) }
            end
        raise Error, "ORDER BY term does not match any column in the result set" unless k&.between?(0, @columns.size - 1)
        [k, desc]
      end
      @limit = eval_count(sel[:limit], "LIMIT")
      @offset = eval_count(sel[:offset], "OFFSET") || 0
      @notes << "SORT RESULTS FOR ORDER BY" if @order.any?
    end

    def rows(outer = nil, _hint = nil)
      l = @left.rows(outer)
      r = @right.rows(outer)
      key = ->(row) { row.map { |v| Ops.norm(v) } }
      out = case @op
            when "UNION ALL" then l + r
            when "UNION"
              # duplicates collapse to the last copy seen (SQLite keeps 0.0 over 0)
              seen = {}
              (l + r).each { |row| seen[key.(row)] = row }
              seen.values
            when "INTERSECT"
              rk = r.to_h { |row| [key.(row), true] }
              seen = {}
              l.select { |row| rk.key?(k = key.(row)) && !seen.key?(k) && (seen[k] = true) }
            when "EXCEPT"
              rk = r.to_h { |row| [key.(row), true] }
              seen = {}
              l.select { |row| !rk.key?(k = key.(row)) && !seen.key?(k) && (seen[k] = true) }
            end
      unless @order.empty?
        wrapped = out.map { |row| [row, @order.map { |k, _| row[k] }] }
        sort_rows!(wrapped, @order.map(&:last))
        out = wrapped.map(&:first)
      end
      out = out.drop(@offset) if @offset.positive?
      out = out.first(@limit) if @limit && @limit >= 0
      out
    end
  end

  # Turns an expression AST back into SQL text (for result column names).
  module Unparse
    module_function

    def expr(e)
      case e[0]
      when :lit
        v = e[1]
        v.nil? ? "NULL" : (v.is_a?(String) ? "'#{v.gsub("'", "''")}'" : Ops.to_text(v))
      when :col then e[1] ? "#{e[1]}.#{e[2]}" : e[2]
      when :bin then "#{expr(e[2])} #{e[1].upcase} #{expr(e[3])}"
      when :neg then "-#{expr(e[1])}"
      when :not then "NOT #{expr(e[1])}"
      when :is then "#{expr(e[1])} IS #{e[3] ? 'NOT ' : ''}#{expr(e[2])}"
      when :fn then "#{e[1]}(#{e[4] ? '*' : (e[3] ? 'DISTINCT ' : '') + e[2].map { |a| expr(a) }.join(', ')})"
      when :between then "#{expr(e[1])} #{e[4] ? 'NOT ' : ''}BETWEEN #{expr(e[2])} AND #{expr(e[3])}"
      when :in then "#{expr(e[1])} #{e[3] ? 'NOT ' : ''}IN (#{e[2].map { |a| expr(a) }.join(', ')})"
      when :insub then "#{expr(e[1])} #{e[3] ? 'NOT ' : ''}IN (SELECT ...)"
      when :like then "#{expr(e[1])} #{e[3] ? 'NOT ' : ''}LIKE #{expr(e[2])}"
      when :case then "CASE ... END"
      when :cast then "CAST(#{expr(e[1])} AS #{e[2]})"
      when :subq then "(SELECT ...)"
      when :exists then "EXISTS (SELECT ...)"
      else e[0].to_s
      end
    end
  end
end
