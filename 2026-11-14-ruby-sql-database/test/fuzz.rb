# frozen_string_literal: true

# Differential fuzzer: generates random schemas, data, DML and queries, runs
# them in Garnet and in SQLite (through test/sqlite_oracle.py) and checks
# that both give the same answers and fail on the same statements.
#
#   ruby test/fuzz.rb [cases] [seed]

require "json"
require "open3"
require "tmpdir"
require_relative "../lib/garnet"

class Fuzzer
  INTS = [-3, -1, 0, 1, 2, 3, 5, 7, 10].freeze
  TEXTS = ["x", "y", "ab", "B", "abc", "10", "", "x%"].freeze
  REALS = [0.5, 1.0, -2.25, 3.0, 1.5].freeze

  def initialize(seed)
    @r = Random.new(seed)
  end

  def pick(a) = a[@r.rand(a.size)]
  def chance(p) = @r.rand < p

  def lit_for(type)
    return "NULL" if chance(0.15)
    case type
    when :int then chance(0.05) ? "'#{pick(INTS)}'" : pick(INTS).to_s
    when :text then "'#{pick(TEXTS)}'"
    else pick(REALS).to_s
    end
  end

  def schema
    @tables = (0...@r.rand(2..3)).map do |t|
      cols = [["a", :int], ["b", :int], ["c", :text]]
      cols << ["d", :real] if chance(0.5)
      { name: "t#{t}", pk: chance(0.6), cols: cols }
    end
    stmts = @tables.map do |t|
      defs = t[:cols].map { |n, ty| "#{n} #{{ int: 'INTEGER', text: 'TEXT', real: 'REAL' }[ty]}" }
      defs.unshift("id INTEGER PRIMARY KEY") if t[:pk]
      "CREATE TABLE #{t[:name]} (#{defs.join(', ')})"
    end
    @tables.each_with_index do |t, i|
      @r.rand(0..2).times do |j|
        col = pick(t[:cols])[0]
        uniq = chance(0.2) ? "UNIQUE " : ""
        stmts << "CREATE #{uniq}INDEX ix#{i}_#{j} ON #{t[:name]}(#{col})"
      end
    end
    stmts
  end

  def inserts
    @tables.flat_map do |t|
      (0...@r.rand(0..4)).map do
        rows = (0...@r.rand(1..8)).map do
          vals = t[:cols].map { |_, ty| lit_for(ty) }
          vals.unshift(chance(0.3) ? pick([1, 2, 3, 4, 50]).to_s : "NULL") if t[:pk]
          "(#{vals.join(', ')})"
        end
        "INSERT INTO #{t[:name]} VALUES #{rows.join(', ')}"
      end
    end
  end

  # ------------------------------------------------------------ expressions

  def colref(scope)
    al, t = pick(scope)
    n, ty = pick(t[:cols] + (t[:pk] ? [["id", :int]] : []))
    ["#{al}.#{n}", ty]
  end

  def scalar(scope, depth = 0)
    return colref(scope)[0] if !scope.empty? && chance(depth > 1 ? 0.7 : 0.4)
    return lit_for(pick(%i[int int text real])) if depth > 2 || chance(0.25)
    case @r.rand(12)
    when 0..2 then "(#{scalar(scope, depth + 1)} #{pick(%w[+ - * / %])} #{scalar(scope, depth + 1)})"
    when 3 then "CASE WHEN #{cond(scope, depth + 1)} THEN #{scalar(scope, depth + 1)} ELSE #{scalar(scope, depth + 1)} END"
    when 4 then "coalesce(#{scalar(scope, depth + 1)}, #{scalar(scope, depth + 1)})"
    when 5 then "abs(#{scalar(scope, depth + 1)})"
    when 6 then "length(#{scalar(scope, depth + 1)})"
    when 7 then "(#{scalar(scope, depth + 1)} || #{scalar(scope, depth + 1)})"
    when 8 then "-#{scalar(scope, depth + 1)}"
    when 9 then "typeof(#{scalar(scope, depth + 1)})"
    when 10 then "nullif(#{scalar(scope, depth + 1)}, #{scalar(scope, depth + 1)})"
    else "upper(#{scalar(scope, depth + 1)})"
    end
  end

  def subquery_cond(scope, depth)
    t = pick(@tables)
    al = "s#{depth}#{@r.rand(100)}"
    inner = [[al, t]]
    corr = !scope.empty? && chance(0.5) ? " AND #{colref(inner)[0]} = #{colref(scope)[0]}" : ""
    where = "#{cond(inner, depth + 2)}#{corr}"
    case @r.rand(3)
    when 0 then "#{chance(0.2) ? 'NOT ' : ''}EXISTS (SELECT 1 FROM #{t[:name]} #{al} WHERE #{where})"
    when 1 then "#{scalar(scope, depth + 1)} #{chance(0.3) ? 'NOT ' : ''}IN (SELECT #{colref(inner)[0]} FROM #{t[:name]} #{al} WHERE #{where})"
    else "#{scalar(scope, depth + 1)} #{pick(%w[= < >=])} (SELECT #{pick(%w[max min count])}(#{colref(inner)[0]}) FROM #{t[:name]} #{al} WHERE #{where})"
    end
  end

  def cond(scope, depth = 0)
    if depth < 2 && chance(0.3)
      return "(#{cond(scope, depth + 1)} #{pick(%w[AND OR])} #{cond(scope, depth + 1)})"
    end
    return "NOT #{cond(scope, depth + 1)}" if depth < 2 && chance(0.08)
    return subquery_cond(scope, depth) if depth < 2 && chance(0.08)
    case @r.rand(9)
    when 0..3
      c, ty = scope.empty? ? [scalar(scope, depth + 1), :int] : colref(scope)
      other = chance(0.6) ? lit_for(ty) : scalar(scope, depth + 1)
      "#{c} #{pick(%w[= != < <= > >=])} #{other}"
    when 4 then "#{scalar(scope, depth + 1)} IS #{chance(0.5) ? 'NOT ' : ''}NULL"
    when 5
      c, ty = scope.empty? ? ["1", :int] : colref(scope)
      "#{c} #{chance(0.2) ? 'NOT ' : ''}BETWEEN #{lit_for(ty)} AND #{lit_for(ty)}"
    when 6
      c, ty = scope.empty? ? ["1", :int] : colref(scope)
      "#{c} #{chance(0.2) ? 'NOT ' : ''}IN (#{(0..@r.rand(3)).map { lit_for(ty) }.join(', ')})"
    when 7 then "#{scalar(scope, depth + 1)} #{chance(0.2) ? 'NOT ' : ''}LIKE '#{pick(%w[x% %b% a_ % _ 1%])}'"
    else "#{scalar(scope, depth + 1)} #{pick(%w[= < >])} #{scalar(scope, depth + 1)}"
    end
  end

  # ---------------------------------------------------------------- queries

  def from_clause
    scope = []
    parts = []
    @r.rand(1..3).times do |i|
      t = pick(@tables)
      al = "q#{i}"
      if i.zero?
        parts << "#{t[:name]} #{al}"
        scope << [al, t]
        next
      end
      kind = pick(["JOIN", "LEFT JOIN", "LEFT JOIN", ","])
      scope << [al, t]
      if kind == ","
        parts << ", #{t[:name]} #{al}"
      else
        on = chance(0.75) ? "#{colref([[al, t]])[0]} = #{colref(scope[0..-2])[0]}" : cond(scope, 1)
        on += " AND #{cond(scope, 1)}" if chance(0.25)
        parts << " #{kind} #{t[:name]} #{al} ON #{on}"
      end
    end
    [parts.join, scope]
  end

  def select_core(want_cols = nil)
    from, scope = from_clause
    where = chance(0.7) ? " WHERE #{cond(scope)}" : ""
    if chance(0.3)
      groups = (0...@r.rand(0..2)).map { colref(scope)[0] }.uniq
      aggs = (0...@r.rand(1..3)).map do
        f = pick(%w[count sum min max avg total count])
        arg = chance(0.2) ? scalar(scope, 1) : colref(scope)[0]
        f == "count" && chance(0.3) ? "count(*)" : "#{f}(#{chance(0.15) ? 'DISTINCT ' : ''}#{arg})"
      end
      cols = groups + aggs
      cols = cols.first(want_cols) if want_cols
      cols << "1" while want_cols && cols.size < want_cols
      group = groups.empty? ? "" : " GROUP BY #{groups.join(', ')}"
      having = !groups.empty? && chance(0.3) ? " HAVING #{aggs[0]} #{pick(%w[> < =])} #{pick([0, 1, 2])}" : ""
      return ["SELECT #{cols.join(', ')} FROM #{from}#{where}#{group}#{having}", cols.size]
    end
    n = want_cols || @r.rand(1..4)
    cols = (0...n).map { chance(0.6) ? colref(scope)[0] : scalar(scope, 1) }
    cols = ["*"] if want_cols.nil? && chance(0.1)
    distinct = chance(0.15) ? "DISTINCT " : ""
    ["SELECT #{distinct}#{cols.join(', ')} FROM #{from}#{where}", cols == ["*"] ? nil : cols.size]
  end

  def query
    if chance(0.12)
      n = @r.rand(1..2)
      a, = select_core(n)
      b, = select_core(n)
      op = pick(["UNION", "UNION ALL", "EXCEPT", "INTERSECT"])
      sql = "#{a} #{op} #{b}"
      sql += " ORDER BY #{(1..n).to_a.join(', ')} LIMIT #{@r.rand(0..6)}" if chance(0.3)
      return [sql, !sql.include?("ORDER")]
    end
    sql, n = select_core
    if n && chance(0.35)
      dirs = (1..n).map { |i| "#{i}#{chance(0.5) ? ' DESC' : ''}" }
      sql += " ORDER BY #{dirs.join(', ')}"
      sql += " LIMIT #{@r.rand(0..5)}#{chance(0.3) ? " OFFSET #{@r.rand(0..3)}" : ''}" if chance(0.6)
      return [sql, false]
    end
    [sql, true]
  end

  def dml
    t = pick(@tables)
    scope = [[t[:name], t]]
    case @r.rand(3)
    when 0
      sets = t[:cols].sample(@r.rand(1..2), random: @r).map { |n, ty| "#{n} = #{chance(0.5) ? lit_for(ty) : scalar(scope, 1)}" }
      "UPDATE #{t[:name]} SET #{sets.join(', ')}#{chance(0.8) ? " WHERE #{cond(scope, 1)}" : ''}"
    when 1 then "DELETE FROM #{t[:name]} WHERE #{cond(scope, 1)}"
    else inserts.first || "SELECT 1"
    end
  end
end

def norm_value(v)
  case v
  when Float then [:r, v.zero? ? 0.0 : v.round(9 - Math.log10(v.abs).floor)]
  when Integer then [:i, v]
  # SQLite's REAL->TEXT conversion picks 15 or 17 digits with a heuristic
  # Garnet only approximates (see README), so compare long decimals at 12.
  when String then [:s, v.gsub(/\d+\.\d{12,}(?:e[-+]\d+)?/) { |m| format("%.12g", m.to_f) }]
  else [:n]
  end
end

def norm_rows(rows, unordered)
  r = rows.map { |row| row.map { |v| norm_value(v) } }
  unordered ? r.sort_by(&:inspect) : r
end

cases = (ARGV[0] || 300).to_i
seed0 = (ARGV[1] || 1).to_i
stdin, stdout, = Open3.popen2("python3", File.join(__dir__, "sqlite_oracle.py"))
oracle = lambda do |req|
  stdin.puts(JSON.generate(req))
  JSON.parse(stdout.gets)
end

stats = Hash.new(0)
failures = 0
dir = Dir.mktmpdir("garnet-fuzz")
t0 = Time.now
cases.times do |ci|
  seed = seed0 + ci
  fz = Fuzzer.new(seed)
  path = File.join(dir, "case#{ci}.db")
  db = Garnet::Database.new(path)
  oracle.(reset: true)
  stmts = fz.schema.map { |s| [s, :ddl] } + fz.inserts.map { |s| [s, :dml] }
  60.times { stmts << (fz.chance(0.2) ? [fz.dml, :dml] : [*fz.query, :query].then { |s, u, _| [s, u ? :unordered : :ordered] }) }
  stmts.each do |sql, kind|
    expect = oracle.(sql: sql)
    got = begin
      { "rows" => db.query(sql) }
    rescue Garnet::Error => e
      { "error" => e.message }
    end
    stats[:statements] += 1
    if expect["error"] || got["error"]
      if expect["error"] && got["error"]
        stats[:both_errored] += 1
        next
      end
      failures += 1
      puts "MISMATCH (seed #{seed}): #{sql}\n  sqlite: #{expect['error'] || "#{expect['rows'].size} rows"}\n  garnet: #{got['error'] || got['rows'].inspect[0, 200]}"
      next
    end
    next unless kind == :ordered || kind == :unordered
    stats[:queries] += 1
    stats[:rows] += expect["rows"].size
    a = norm_rows(expect["rows"], kind == :unordered)
    b = norm_rows(got["rows"], kind == :unordered)
    next if a == b
    failures += 1
    puts "MISMATCH (seed #{seed}): #{sql}\n  sqlite: #{expect['rows'].inspect[0, 300]}\n  garnet: #{got['rows'].inspect[0, 300]}"
  end
  db.close
  File.delete(path)
  exit 1 if failures > 15
end
puts format("%d cases, %d statements, %d queries compared (%d result rows), %d statements rejected by both; %d mismatches (%.1fs)",
            cases, stats[:statements], stats[:queries], stats[:rows], stats[:both_errored], failures, Time.now - t0)
exit(failures.zero? ? 0 : 1)
