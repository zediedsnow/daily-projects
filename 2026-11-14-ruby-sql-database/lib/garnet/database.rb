# frozen_string_literal: true

module Garnet
  Result = Struct.new(:columns, :rows, :message)

  # The public entry point: owns the pager, the catalog, and statement
  # execution (DDL, DML, transactions).
  class Database
    MAX_INLINE_ROW = 1000   # larger rows spill to overflow pages
    MAX_INDEX_KEY = 800
    OVERFLOW_CHUNK = 4000

    attr_reader :pager, :compiler

    def initialize(path)
      @pager = Pager.new(path)
      @compiler = Compiler.new(self)
      @explicit = false
      @building = []
    end

    def close = @pager.close
    def in_transaction? = @explicit

    # Execute one or more statements; returns an array of Results.
    def execute(sql)
      Parser.parse(sql).map { |st, text| run(st, text) }
    end

    # Convenience: rows of the last statement.
    def query(sql) = execute(sql).last&.rows

    def tables = @pager.header[:tables]

    def table_meta(name)
      tables[name.downcase] or raise Error, "no such table: #{name}"
    end

    # Walks every table and index and cross-checks them. Returns a list of
    # problems (empty when the file is consistent).
    def integrity_check
      problems = []
      tables.each_value do |meta|
        ncols = meta[:cols].size
        rows = []
        prev = nil
        BTree.new(@pager, meta[:root]).each do |rowid, v|
          problems << "#{meta[:name]}: rowids out of order at #{rowid}" if prev && prev >= rowid
          prev = rowid
          row = load_row(v)
          problems << "#{meta[:name]}: row #{rowid} has #{row.size - 1} columns" if row.size != ncols + 1
          problems << "#{meta[:name]}: row #{rowid} stores rowid #{row[ncols]}" if row[ncols] != rowid
          rows << row
        end
        meta[:indexes].each do |ix|
          want = rows.map { |r| [r[ix[:col]], r[ncols]] }.sort { |a, b| Values.cmp_key(a, b) }
          got = BTree.new(@pager, ix[:root]).each.map { |k, _| k }
          problems << "index #{ix[:name]}: #{got.size} entries, expected #{want.size}" if got.size != want.size
          problems << "index #{ix[:name]}: entries do not match table #{meta[:name]}" if got != want
        end
      end
      problems
    end

    def page_stats
      h = @pager.header
      { pages: h[:page_count], free_pages: h[:freelist].size, file_bytes: h[:page_count] * Pager::PAGE_SIZE,
        tables: tables.transform_values { |m| { depth: BTree.new(@pager, m[:root]).depth, pages: BTree.new(@pager, m[:root]).pages.size } } }
    end

    # ---- used by plans ----

    def building(plan)
      @building.last&.add_child(@pending_kind || "SUBQUERY", plan) if @building.any?
      @building.push(plan)
      yield
    ensure
      @building.pop
    end

    def plan_query(sel, parent_scope, kind = nil)
      @pending_kind = kind || (parent_scope ? "SUBQUERY" : nil)
      sel.key?(:compound) ? CompoundPlan.new(self, sel, parent_scope) : SelectPlan.new(self, sel, parent_scope)
    end

    def load_row(v)
      return v unless v.is_a?(Hash)
      data = +"".b
      id = v[:ovf]
      while id
        pg = @pager.read(id)
        data << pg[:data]
        id = pg[:next]
      end
      Marshal.load(data)
    end

    private

    def run(st, text)
      case st[0]
      when :begin
        raise Error, "cannot start a transaction within a transaction" if @explicit
        @explicit = true
        Result.new([], [], "BEGIN")
      when :commit
        raise Error, "cannot commit - no transaction is active" unless @explicit
        @pager.commit
        @explicit = false
        Result.new([], [], "COMMIT")
      when :rollback
        raise Error, "cannot rollback - no transaction is active" unless @explicit
        @pager.rollback
        @explicit = false
        Result.new([], [], "ROLLBACK")
      else
        begin
          # autocommit failures discard every dirty page anyway, so the
          # statement journal is only needed inside BEGIN ... COMMIT
          @pager.begin_statement if @explicit
          res = exec_stmt(st, text)
          @pager.end_statement
          @pager.commit unless @explicit
          res
        rescue StandardError
          if @explicit
            @pager.rollback_statement
          else
            @pager.end_statement
            @pager.rollback
          end
          raise
        end
      end
    end

    def exec_stmt(st, text)
      case st[0]
      when :select
        plan = plan_query(st[1], nil)
        Result.new(plan.columns, plan.rows)
      when :explain
        inner = st[1]
        raise Error, "EXPLAIN supports SELECT, UPDATE and DELETE" unless %i[select update delete].include?(inner[0])
        plan = case inner[0]
               when :select then plan_query(inner[1], nil)
               else dml_plan(table_meta(inner[1]), inner[0] == :update ? inner[3] : inner[2])[0]
               end
        Result.new(["plan"], plan.explain.map { |l| [l] })
      when :create_table then create_table(*st[1..])
      when :create_index then create_index(*st[1..])
      when :drop_table then drop_table(*st[1..])
      when :drop_index then drop_index(*st[1..])
      when :insert then insert(*st[1..])
      when :update then update(*st[1..])
      when :delete then delete(*st[1..])
      else raise Error, "unsupported statement #{st[0]}"
      end
    end

    # ------------------------------------------------------------- DDL

    def create_table(name, cols, if_not_exists)
      if tables.key?(name.downcase)
        return Result.new([], [], "table #{name} already exists") if if_not_exists
        raise Error, "table #{name} already exists"
      end
      names = cols.map { |c| c[:name].downcase }
      dup = names.find { |n| names.count(n) > 1 }
      raise Error, "duplicate column name: #{dup}" if dup
      pks = cols.each_index.select { |i| cols[i][:pk] }
      raise Error, "table #{name} has more than one primary key" if pks.size > 1
      pk = pks[0] && cols[pks[0]][:type] == "INTEGER" ? pks[0] : nil
      meta = {
        name: name,
        cols: cols.map { |c| { name: c[:name], type: c[:type], aff: Ops.affinity_of(c[:type]), notnull: c[:notnull], default: c[:default] } },
        root: BTree.create(@pager), pk: pk, indexes: []
      }
      @pager.mutable(0)[:tables][name.downcase] = meta
      cols.each_with_index do |c, i|
        next unless (c[:pk] && i != pk) || c[:unique]
        create_index("autoindex_#{name}_#{c[:name]}", name, c[:name], true, false)
      end
      Result.new([], [], "table #{name} created")
    end

    def all_indexes = tables.values.flat_map { |t| t[:indexes].map { |ix| [t, ix] } }

    def create_index(iname, tname, cname, unique, if_not_exists)
      if all_indexes.any? { |_, ix| ix[:name].casecmp?(iname) }
        return Result.new([], [], "index #{iname} already exists") if if_not_exists
        raise Error, "index #{iname} already exists"
      end
      meta = @pager.mutable(0)[:tables][tname.downcase] or raise Error, "no such table: #{tname}"
      ci = meta[:cols].index { |c| c[:name].casecmp?(cname) } or raise Error, "no such column: #{cname}"
      ix = { name: iname, col: ci, root: BTree.create(@pager), unique: unique }
      itree = BTree.new(@pager, ix[:root])
      BTree.new(@pager, meta[:root]).each do |rowid, v|
        val = load_row(v)[ci]
        check_index_key(val)
        if unique && !val.nil? && unique_conflict(itree, val, nil)
          raise Error, "UNIQUE constraint failed: #{meta[:name]}.#{meta[:cols][ci][:name]}"
        end
        itree.put([val, rowid], nil)
      end
      meta[:indexes] << ix
      Result.new([], [], "index #{iname} created")
    end

    def drop_table(name, if_exists)
      meta = tables[name.downcase]
      unless meta
        return Result.new([], [], "no such table: #{name}") if if_exists
        raise Error, "no such table: #{name}"
      end
      tree = BTree.new(@pager, meta[:root])
      tree.each { |_, v| free_overflow(v) }
      pages = tree.pages
      meta[:indexes].each { |ix| pages.concat(BTree.new(@pager, ix[:root]).pages) }
      pages.each { |id| @pager.free(id) }
      @pager.mutable(0)[:tables].delete(name.downcase)
      Result.new([], [], "table #{name} dropped (#{pages.size} pages freed)")
    end

    def drop_index(name, if_exists)
      t, ix = all_indexes.find { |_, x| x[:name].casecmp?(name) }
      unless ix
        return Result.new([], [], "no such index: #{name}") if if_exists
        raise Error, "no such index: #{name}"
      end
      BTree.new(@pager, ix[:root]).pages.each { |id| @pager.free(id) }
      @pager.mutable(0)[:tables][t[:name].downcase][:indexes].reject! { |x| x[:name] == ix[:name] }
      Result.new([], [], "index #{name} dropped")
    end

    # ------------------------------------------------------------- DML

    def check_index_key(val)
      return unless val.is_a?(String) && val.bytesize > MAX_INDEX_KEY
      raise Error, "index key too large (#{val.bytesize} bytes; limit is #{MAX_INDEX_KEY})"
    end

    def unique_conflict(itree, val, except_rowid)
      itree.each([val, :min]) do |k, _|
        return false unless Values.cmp(k[0], val).zero?
        return true unless k[1] == except_rowid
      end
      false
    end

    def store_row(row)
      data = Marshal.dump(row)
      return row if data.bytesize <= MAX_INLINE_ROW
      chunks = data.b.scan(/.{1,#{OVERFLOW_CHUNK}}/mn)
      nxt = nil
      chunks.reverse_each { |ch| nxt = @pager.allocate({ data: ch, next: nxt }) }
      { ovf: nxt, size: data.bytesize }
    end

    def free_overflow(v)
      return unless v.is_a?(Hash)
      id = v[:ovf]
      while id
        nxt = @pager.read(id)[:next]
        @pager.free(id)
        id = nxt
      end
    end

    # Validate and coerce a full row of column values; returns [row, rowid].
    def prepare_row(meta, row, old_rowid)
      meta[:cols].each_with_index do |c, i|
        row[i] = Ops.apply_affinity(row[i], c[:aff])
        raise Error, "NOT NULL constraint failed: #{meta[:name]}.#{c[:name]}" if c[:notnull] && row[i].nil?
      end
      pk = meta[:pk]
      tree = BTree.new(@pager, meta[:root])
      rowid = if pk
                v = row[pk]
                if v.nil?
                  old_rowid || next_rowid(tree)
                else
                  raise Error, "datatype mismatch" unless v.is_a?(Integer)
                  v
                end
              else
                old_rowid || next_rowid(tree)
              end
      row[pk] = rowid if pk
      [row, rowid]
    end

    def next_rowid(tree)
      last = tree.last_key || 0
      raise Error, "database or disk is full (rowid space exhausted)" if last >= Ops::INT_MAX
      last + 1
    end

    def write_row(meta, row, rowid, old_rowid = nil, old_row = nil)
      tree = BTree.new(@pager, meta[:root])
      if rowid != old_rowid && tree.get(rowid)[0]
        pkname = meta[:pk] ? meta[:cols][meta[:pk]][:name] : "rowid"
        raise Error, "UNIQUE constraint failed: #{meta[:name]}.#{pkname}"
      end
      meta[:indexes].each do |ix|
        v = row[ix[:col]]
        check_index_key(v)
        next unless ix[:unique] && !v.nil?
        if unique_conflict(BTree.new(@pager, ix[:root]), v, old_rowid)
          raise Error, "UNIQUE constraint failed: #{meta[:name]}.#{meta[:cols][ix[:col]][:name]}"
        end
      end
      remove_row(meta, old_rowid, old_row) if old_rowid
      tree.put(rowid, store_row(row + [rowid]))
      meta[:indexes].each { |ix| BTree.new(@pager, ix[:root]).put([row[ix[:col]], rowid], nil) }
    end

    def remove_row(meta, rowid, row)
      tree = BTree.new(@pager, meta[:root])
      found, v = tree.get(rowid)
      return unless found
      free_overflow(v)
      tree.delete(rowid)
      meta[:indexes].each { |ix| BTree.new(@pager, ix[:root]).delete([row[ix[:col]], rowid]) }
    end

    def insert(tname, cols, src)
      meta = table_meta(tname)
      ncols = meta[:cols].size
      targets = if cols.nil? then (0...ncols).to_a
                else
                  cols.map do |c|
                    meta[:cols].index { |x| x[:name].casecmp?(c) } ||
                      (%w[rowid oid _rowid_].include?(c.downcase) ? ncols : nil) ||
                      raise(Error, "table #{meta[:name]} has no column named #{c}")
                  end
                end
      values = if src.is_a?(Hash)
                 plan = plan_query(src, nil)
                 plan.rows
               else
                 sc = Scope.new([])
                 src.map { |exprs| exprs.map { |e| @compiler.compile(e, sc).(nil) } }
               end
      defaults = meta[:cols].map { |c| c[:default] && @compiler.compile(c[:default], Scope.new([])) }
      values.each do |vals|
        if vals.size != targets.size
          raise Error, "#{vals.size} values for #{targets.size} columns" if cols || !src.is_a?(Hash)
          raise Error, "table #{meta[:name]} has #{ncols} columns but #{vals.size} values were supplied"
        end
        row = Array.new(ncols) { |i| defaults[i]&.(nil) }
        explicit_rowid = nil
        targets.each_with_index { |t, k| t == ncols ? explicit_rowid = vals[k] : row[t] = vals[k] }
        if explicit_rowid && meta[:pk].nil?
          explicit_rowid = Ops.apply_affinity(explicit_rowid, :integer)
          raise Error, "datatype mismatch" unless explicit_rowid.is_a?(Integer)
        elsif explicit_rowid
          row[meta[:pk]] = explicit_rowid
          explicit_rowid = nil
        end
        row, rowid = prepare_row(meta, row, explicit_rowid)
        write_row(meta, row, rowid)
      end
      Result.new([], [], "#{values.size} row#{values.size == 1 ? '' : 's'} inserted")
    end

    def dml_plan(meta, where)
      sel = { distinct: false, cols: [[[:col, meta[:name], "rowid"], "rowid"]],
              from: [{ table: meta[:name], alias: meta[:name], join: :first }], where: where }
      plan = plan_query(sel, nil)
      [plan, plan.scope]
    end

    def matching(meta, where)
      plan, = dml_plan(meta, where)
      found = []
      plan.each_env(nil) { |env| found << env[0] }
      found
    end

    def update(tname, sets, where)
      meta = table_meta(tname)
      ncols = meta[:cols].size
      _, sc = dml_plan(meta, nil)
      assigns = sets.map do |c, e|
        ci = meta[:cols].index { |x| x[:name].casecmp?(c) } or raise Error, "no such column: #{c}"
        [ci, @compiler.compile(e, sc)]
      end
      # apply in rowid order, so constraint checks see a predictable sequence
      rows = matching(meta, where).sort_by { |r| r[ncols] }
      env = Array.new(3)
      rows.each do |stored|
        env[0] = stored
        old_rowid = stored[ncols]
        old = stored[0...ncols]
        new_vals = assigns.map { |ci, f| [ci, f.(env)] }
        row = old.dup
        new_vals.each { |ci, v| row[ci] = v }
        row, rowid = prepare_row(meta, row, meta[:pk] ? nil : old_rowid)
        write_row(meta, row, rowid, old_rowid, old)
      end
      Result.new([], [], "#{rows.size} row#{rows.size == 1 ? '' : 's'} updated")
    end

    def delete(tname, where)
      meta = table_meta(tname)
      ncols = meta[:cols].size
      rows = matching(meta, where)
      rows.each { |stored| remove_row(meta, stored[ncols], stored[0...ncols]) }
      Result.new([], [], "#{rows.size} row#{rows.size == 1 ? '' : 's'} deleted")
    end
  end
end
