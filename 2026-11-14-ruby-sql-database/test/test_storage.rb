# frozen_string_literal: true

# Storage-layer tests: persistence, transactions, statement atomicity,
# overflow pages, page reuse, and crash recovery via the rollback journal.
#
#   ruby test/test_storage.rb

require "tmpdir"
require_relative "../lib/garnet"

$checks = 0
def check(desc, cond)
  $checks += 1
  return if cond
  puts "FAIL: #{desc}"
  exit 1
end

def raises?(&blk)
  blk.call
  false
rescue Garnet::Error
  true
end

dir = Dir.mktmpdir("garnet-test")
path = File.join(dir, "t.db")
rnd = Random.new(7)

# --- persistence across reopen, with a secondary index ---------------------
db = Garnet::Database.new(path)
db.execute("CREATE TABLE kv (id INTEGER PRIMARY KEY, k TEXT, v INTEGER); CREATE INDEX kv_k ON kv(k)")
model = {}
db.execute("BEGIN")
20_000.times do |i|
  k = "key#{rnd.rand(50_000)}"
  db.execute("INSERT INTO kv (k, v) VALUES ('#{k}', #{i})")
  model[i + 1] = [k, i]
end
db.execute("COMMIT")
1_000.times do
  id = rnd.rand(1..20_000)
  next unless model.key?(id)
  if rnd.rand < 0.5
    db.execute("DELETE FROM kv WHERE id = #{id}")
    model.delete(id)
  else
    db.execute("UPDATE kv SET v = v + 1000000 WHERE id = #{id}")
    model[id][1] += 1_000_000
  end
end
db.close
db = Garnet::Database.new(path)
check "row count after reopen", db.query("SELECT count(*) FROM kv") == [[model.size]]
check "full contents after reopen", db.query("SELECT id, k, v FROM kv").map { |id, k, v| [id, [k, v]] } == model.sort
sample = model.values.sample(random: rnd)[0]
check "index lookup agrees with model",
      db.query("SELECT count(*) FROM kv WHERE k = '#{sample}'") == [[model.values.count { |k, _| k == sample }]]
check "integrity", db.integrity_check.empty?
check "tree has more than one level", db.page_stats[:tables]["kv"][:depth] >= 2

# --- transactions and statement atomicity -----------------------------------
db.execute("CREATE TABLE u (x INTEGER UNIQUE)")
db.execute("BEGIN; INSERT INTO u VALUES (1), (2)")
check "duplicate inside multi-row insert fails", raises? { db.execute("INSERT INTO u VALUES (3), (4), (1), (5)") }
check "failed statement rolled back alone", db.query("SELECT x FROM u ORDER BY x") == [[1], [2]]
db.execute("INSERT INTO u VALUES (9); ROLLBACK")
check "rollback discards the transaction", db.query("SELECT count(*) FROM u") == [[0]]
check "autocommit statement is atomic", raises? { db.execute("INSERT INTO u VALUES (7), (7)") }
check "nothing from failed autocommit statement", db.query("SELECT count(*) FROM u") == [[0]]
check "NOT NULL enforced", raises? { db.execute("CREATE TABLE nn (a TEXT NOT NULL); INSERT INTO nn VALUES (NULL)") }
check "unique index creation fails on duplicates",
      raises? { db.execute("INSERT INTO u VALUES (1); CREATE TABLE d (a INTEGER); INSERT INTO d VALUES (1), (1); CREATE UNIQUE INDEX d_a ON d(a)") }

# --- overflow pages and page reuse ------------------------------------------
db.execute("CREATE TABLE blobs (id INTEGER PRIMARY KEY, body TEXT)")
big = (0...60_000).map { (97 + rnd.rand(26)).chr }.join
db.execute("INSERT INTO blobs (body) VALUES ('#{big}')")
check "60 KB value round-trips", db.query("SELECT body FROM blobs") == [[big]]
check "length of overflow value", db.query("SELECT length(body) FROM blobs WHERE id = 1") == [[60_000]]
pages_before = db.page_stats[:pages]
db.execute("UPDATE blobs SET body = upper(body)")
check "update of overflow row", db.query("SELECT substr(body, 1, 5) FROM blobs") == [[big[0, 5].upcase]]
db.execute("DELETE FROM blobs")
free = db.page_stats[:free_pages]
check "overflow pages returned to the freelist", free >= 14
db.execute("INSERT INTO blobs (body) VALUES ('#{big}')")
check "freed pages are reused", db.page_stats[:pages] <= pages_before + 1
db.execute("DROP TABLE blobs")
check "drop table frees its pages", db.page_stats[:free_pages] > free
db.close

# --- crash recovery ---------------------------------------------------------
# A child process starts a large transaction and is killed part-way through
# writing pages into the database file. Reopening must restore exactly the
# last committed state.
[0, 1, 3, 10, 40, 120].each do |kill_at|
  db = Garnet::Database.new(path)
  before = db.query("SELECT id, k, v FROM kv")
  db.close
  pid = fork do
    d = Garnet::Database.new(path)
    d.execute("BEGIN")
    d.execute("UPDATE kv SET v = -v WHERE id % 3 = 0")
    d.execute("DELETE FROM kv WHERE id % 7 = 0")
    500.times { |i| d.execute("INSERT INTO kv (k, v) VALUES ('crash#{i}', #{i})") }
    d.execute("CREATE TABLE junk (a INTEGER); INSERT INTO junk VALUES (1)")
    d.pager.crash_after_pages = kill_at
    d.execute("COMMIT") # the process dies inside this commit
    exit!(0)
  end
  Process.wait(pid)
  check "child died mid-commit (#{kill_at})", $?.exitstatus == 42
  check "journal left behind (#{kill_at})", File.exist?("#{path}-journal")
  db = Garnet::Database.new(path)
  check "journal rolled back (#{kill_at})", db.pager.stats[:recovered] == 1 && !File.exist?("#{path}-journal")
  check "data identical after crash at page #{kill_at}", db.query("SELECT id, k, v FROM kv") == before
  check "no half-created table (#{kill_at})", raises? { db.query("SELECT * FROM junk") }
  check "integrity after crash (#{kill_at})", db.integrity_check.empty?
  db.close
end

# A torn journal (crash while the journal itself was being written) must be
# ignored, because the database file was not touched yet.
File.binwrite("#{path}-journal", "GRNTJRNL" + ("\x01" * 100))
db = Garnet::Database.new(path)
check "torn journal discarded", db.pager.stats[:recovered].zero? && !File.exist?("#{path}-journal")
check "database intact after torn journal", db.integrity_check.empty?
db.close

puts "storage tests: #{$checks} checks passed"
