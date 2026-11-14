# frozen_string_literal: true

# Builds a 100,000-row database and shows what the planner's access paths
# are worth: the same questions answered with and without indexes.
#
#   ruby examples/bench.rb [rows]

require "tmpdir"
require_relative "../lib/garnet"

N = (ARGV[0] || 100_000).to_i
USERS = N / 20
path = File.join(Dir.mktmpdir("garnet-bench"), "bench.db")
db = Garnet::Database.new(path)
rnd = Random.new(42)

def timed(label)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  r = yield
  ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
  printf("  %-46s %9.1f ms\n", label, ms)
  r
end

cities = %w[Tbilisi Oslo Lima Kyoto Accra Quito Hanoi Porto Riga Cusco]
puts "Loading #{USERS} users and #{N} orders..."
db.execute(<<~SQL)
  CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, city TEXT, born INTEGER);
  CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER, amount REAL, sku TEXT, day INTEGER);
SQL
timed("insert #{USERS + N} rows (one transaction)") do
  db.execute("BEGIN")
  USERS.times.each_slice(500) do |ids|
    vals = ids.map { |i| "('user#{i}', '#{cities[rnd.rand(cities.size)]}', #{1950 + rnd.rand(55)})" }
    db.execute("INSERT INTO users (name, city, born) VALUES #{vals.join(',')}")
  end
  N.times.each_slice(500) do |ids|
    vals = ids.map { |i| "(#{1 + rnd.rand(USERS)}, #{(rnd.rand * 200).round(2)}, 'sku#{rnd.rand(2000)}', #{i % 365})" }
    db.execute("INSERT INTO orders (user_id, amount, sku, day) VALUES #{vals.join(',')}")
  end
  db.execute("COMMIT")
end
st = db.page_stats
puts "  file: #{st[:pages]} pages (#{(st[:file_bytes] / 1024.0 / 1024).round(1)} MB); " \
     "orders B+tree depth #{st[:tables]['orders'][:depth]}"

queries = {
  "point lookup by sku" => "SELECT count(*) FROM orders WHERE sku = 'sku777'",
  "range on amount" => "SELECT count(*) FROM orders WHERE amount BETWEEN 10 AND 10.5",
  "join users->orders for one city" =>
    "SELECT count(*), round(sum(o.amount), 2) FROM users u JOIN orders o ON o.user_id = u.id WHERE u.city = 'Oslo' AND u.born = 1980"
}

puts "\nWithout secondary indexes:"
before = queries.to_h { |label, sql| [label, timed(label) { db.query(sql) }] }
puts "  plan for the join:"
db.query("EXPLAIN #{queries['join users->orders for one city']}").each { |(l)| puts "    #{l}" }

timed("CREATE INDEX x3 (build from existing rows)") do
  db.execute("CREATE INDEX orders_sku ON orders(sku); CREATE INDEX orders_amount ON orders(amount); CREATE INDEX orders_user ON orders(user_id)")
end

puts "\nWith indexes:"
queries.each do |label, sql|
  r = timed(label) { db.query(sql) }
  raise "answer changed for #{label}!" unless r == before[label]
end
puts "  plan for the join:"
db.query("EXPLAIN #{queries['join users->orders for one city']}").each { |(l)| puts "    #{l}" }
timed("1000 primary-key lookups") { 1000.times { |i| db.query("SELECT amount FROM orders WHERE id = #{1 + i * 97}") } }
puts "\nintegrity check: #{db.integrity_check.empty? ? 'ok' : 'FAILED'}"
