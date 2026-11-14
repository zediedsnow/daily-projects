# Garnet: a SQL database in pure Ruby

Garnet is a small relational database engine, written from scratch in about 2,600 lines of Ruby with no gems. It stores everything in one file as a B+tree of 4 KB pages. It survives `kill -9` in the middle of a commit and answers SQL with a query planner that chooses between table scans, index lookups, range scans and hash joins.

Its behaviour is checked against SQLite: a differential fuzzer runs random schemas, data, updates and queries through both engines and compares every answer.

```
$ bin/garnet tour.db < examples/tour.sql
...
┌───────────────────┬───────┬────────────┬───────┐
│ name              │ books │ avg_rating │ first │
├───────────────────┼───────┼────────────┼───────┤
│ Ursula K. Le Guin │     3 │       4.27 │  1968 │
│ Italo Calvino     │     2 │        4.2 │  1972 │
│ Liu Cixin         │     2 │       4.25 │  2008 │
│ Octavia Butler    │     2 │       4.45 │  1979 │
│ Stanislaw Lem     │     2 │        4.1 │  1961 │
│ Nobody Yet        │     0 │       NULL │  NULL │
└───────────────────┴───────┴────────────┴───────┘
(6 rows)
...
Error: UNIQUE constraint failed: books.id

$ bin/garnet tour.db -c "EXPLAIN SELECT a.name, b.title FROM authors a JOIN books b ON b.author_id = a.id
    WHERE b.rating = (SELECT max(rating) FROM books WHERE author_id = a.id)
      AND a.country IN (SELECT country FROM authors GROUP BY country HAVING count(*) > 1) ORDER BY 1"
┌───────────────────────────────────────────────────────┐
│ plan                                                  │
├───────────────────────────────────────────────────────┤
│ SCAN a                                                │
│ SEARCH b USING INDEX books_author (author_id=?)       │
│ SORT RESULTS FOR ORDER BY                             │
│ SUBQUERY                                              │
│   SEARCH books USING INDEX books_author (author_id=?) │
│   CORRELATED: re-run for every outer row              │
│ SUBQUERY                                              │
│   SCAN authors                                        │
│   USE HASH TABLE FOR GROUP BY                         │
└───────────────────────────────────────────────────────┘
```

## Why it's interesting

- **A real on-disk B+tree.** Tables are B+trees keyed by rowid. Indexes are B+trees keyed by `(value, rowid)`. Leaves are chained for range scans. Nodes split by *encoded byte size*, not by key count, so short and long rows both pack well. Values larger than about 1 KB spill into chains of overflow pages, and dropped or deleted pages go onto a freelist and are reused.
- **Crash-safe commits with a rollback journal**, the same design as SQLite's default mode. Before a commit overwrites any page, it writes the page's original bytes and a CRC to `<db>-journal` and fsyncs that file. Deleting the journal is the commit point. The test suite kills a child process at six different points while it is writing pages. In every case, reopening the file restores exactly the last committed state, with no half-created table and no torn index. A torn journal (a crash *while writing the journal*) is detected by its CRC and ignored.
- **Transactions and statement atomicity.** `BEGIN` / `COMMIT` / `ROLLBACK` are supported. Inside a transaction, a failing statement is undone on its own, as in SQLite. For example, a multi-row `INSERT` that hits a `UNIQUE` violation on its third row leaves no rows behind, and earlier statements in the transaction are kept. This uses an in-memory statement journal of page snapshots.
- **A query planner you can inspect with `EXPLAIN`.** For each table in the join, the planner breaks `WHERE`/`ON` into conjuncts and pushes each one to the earliest point where all of its columns are bound. It then picks the cheapest access path: rowid lookup, then unique index, index equality, rowid range, index range, hash join and finally full scan. Correlated subqueries are detected and re-run per outer row. Uncorrelated ones run once and are cached.
- **SQLite's type semantics, including the odd parts**: dynamic typing with column *affinity* (`'12'` stored in an `INTEGER` column becomes `12`), the comparison-affinity rules (`text_col = 10` compares as text), `NULL < numbers < text` ordering, three-valued logic, truncating integer division, `%` with the sign of the dividend, `sum()` returning an integer or a real depending on its inputs, `1 = 1.0` in `GROUP BY` and `DISTINCT`, and SQLite 3.4x's REAL-to-TEXT formatting.
- **Checked against SQLite.** `test/fuzz.rb` generates random schemas, including unique indexes, `INTEGER PRIMARY KEY` and mixed-type data. It then runs random `INSERT`/`UPDATE`/`DELETE` statements and queries with inner, left and cross joins, `GROUP BY`/`HAVING`, `DISTINCT`, `ORDER BY ... LIMIT/OFFSET`, `UNION`/`INTERSECT`/`EXCEPT`, `IN`/`EXISTS`/scalar subqueries (correlated or not), `CASE`, `LIKE`, `BETWEEN` and more. It requires the same rows from both engines, and the same errors. The last full run:

  ```
  3000 cases, 209,985 statements, 143,448 queries compared (1,305,476 result rows), 0 mismatches
  ```

  The fuzzer caught several real semantic bugs during development. Examples: `abs('x')` is `0.0`, not `0`. `sum()` over `'10'` and `'x'` gives `10.0`. `x IN (SELECT real_col ...)` takes the subquery column's affinity. When `UNION` collapses `0` and `0.0`, the *last* copy survives. SQLite prints `1/3.0` as `0.33333333333333332`.

## Build and run

Requires Ruby 3.1+ (tested on 3.3). Python 3 is needed only for the fuzzer's SQLite oracle.

```bash
bin/garnet my.db                      # interactive shell (.help, .tables, .schema, .check, .stats)
bin/garnet my.db < examples/tour.sql  # run a script
bin/garnet my.db -c "SELECT 1 + 1"    # one command
ruby examples/bench.rb                # 100k-row benchmark: scans vs indexes
test/run.sh                           # storage + crash tests, then 300 fuzz cases
ruby test/fuzz.rb 3000 1              # bigger differential fuzz (cases, seed)
```

As a library:

```ruby
require_relative "lib/garnet"
db = Garnet::Database.new("app.db")
db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
db.execute("INSERT INTO t (name) VALUES ('a'), ('b')")
db.query("SELECT id, upper(name) FROM t WHERE id > 1")   # => [[2, "B"]]
```

## Supported SQL

| | |
|---|---|
| DDL | `CREATE TABLE [IF NOT EXISTS]` with `INTEGER PRIMARY KEY` (rowid alias), `PRIMARY KEY`, `NOT NULL`, `UNIQUE`, `DEFAULT`; `CREATE [UNIQUE] INDEX`; `DROP TABLE`, `DROP INDEX` |
| DML | `INSERT ... VALUES` (multi-row), `INSERT ... SELECT`, `UPDATE ... SET ... WHERE`, `DELETE ... WHERE` |
| Queries | `SELECT [DISTINCT]`, `*` / `t.*`, aliases, `FROM` with `JOIN`, `LEFT JOIN`, `CROSS JOIN`, comma joins and subqueries in `FROM`; `WHERE`, `GROUP BY` (expressions or ordinals), `HAVING`, `ORDER BY` (expressions, aliases, ordinals, `ASC`/`DESC`), `LIMIT`/`OFFSET`, `UNION [ALL]`, `INTERSECT`, `EXCEPT` |
| Expressions | arithmetic, `\|\|`, comparisons, `AND`/`OR`/`NOT`, `IS [NOT]`, `IS NULL`, `[NOT] IN (list)`, `[NOT] IN (SELECT ...)`, `[NOT] EXISTS`, scalar subqueries, `BETWEEN`, `LIKE`, `CASE`, `CAST` |
| Functions | `count sum avg min max total group_concat` (with `DISTINCT`), `abs length upper lower substr instr replace trim round coalesce ifnull nullif iif min max typeof random` |
| Other | `BEGIN`/`COMMIT`/`ROLLBACK`, `EXPLAIN` for `SELECT`/`UPDATE`/`DELETE` |

## Benchmark

`ruby examples/bench.rb` loads 5,000 users and 100,000 orders. It then asks the same three questions before and after creating indexes and checks that the answers do not change. Results on the build machine (pure Ruby 3.3, no JIT):

```
Loading 5000 users and 100000 orders...
  insert 105000 rows (one transaction)              9576.8 ms
  file: 2240 pages (8.8 MB); orders B+tree depth 3

Without secondary indexes:
  point lookup by sku                                161.1 ms
  range on amount                                    153.7 ms
  join users->orders for one city                     39.0 ms
  plan for the join:
    SCAN u
    HASH JOIN o (user_id=?)
  CREATE INDEX x3 (build from existing rows)        8721.9 ms

With indexes:
  point lookup by sku                                  1.2 ms
  range on amount                                      3.1 ms
  join users->orders for one city                     12.1 ms
  plan for the join:
    SCAN u
    SEARCH o USING INDEX orders_user (user_id=?)
  1000 primary-key lookups                           162.2 ms

integrity check: ok
```

## How it works

```
SQL text ─► Parser ─► AST ─► Planner ─► closures ─► rows
                                │
                     Database (DDL/DML, constraints)
                                │
                  BTree (tables + indexes, overflow chains)
                                │
             Pager (page cache, freelist, journal, fsync)
```

- **`pager.rb`**: the file is an array of 4 KB pages. Page 0 holds the header and the catalog. Pages are decoded into Ruby hashes and cached, and they are written back only at commit. `mutable(id)` is the only way to get a writable page. It records the page as dirty and, inside a transaction, snapshots it for statement rollback. Commit runs journal → fsync → write pages → fsync → delete journal. On open, a journal with a valid CRC is played back and the file is truncated to its old length.
- **`btree.rb`**: B+tree with a fixed root page id (a root split moves the old root's contents to a new page). Each node keeps an upper-bound estimate of its encoded size. The node is encoded exactly only when the estimate crosses the page size, which more than doubled bulk-insert speed. Deletes do not rebalance; empty leaves stay in the chain, as in many production engines.
- **`parser.rb`**: hand-written lexer and recursive-descent parser with SQLite's operator precedence. Expressions become nested arrays such as `[:bin, "+", [:col, nil, "a"], [:lit, 1]]`.
- **`compiler.rb`**: name resolution through a chain of scopes (correlated subqueries resolve into the outer query's scope and mark themselves correlated). Each expression is compiled into a Ruby lambda over an *env* array: one slot per joined table, one slot for aggregate results and one link to the outer query's env. Comparisons are compiled with the right affinity conversions already chosen.
- **`plan.rb`**: the planner and executor. Joins run as nested loops over access-path closures. For a `LEFT JOIN`, `ON` conditions decide matching and `WHERE` conditions filter afterwards, so null-extended rows behave correctly. Aggregation uses a hash table keyed by normalised group values. `ORDER BY` is a stable sort with SQLite's `NULLS FIRST` ordering. A `LIMIT` with no `ORDER BY` stops the scan early.
- **`ops.rb`**: SQLite's scalar semantics (affinity, arithmetic, truthiness, `LIKE`, number formatting).

## Limitations

Garnet keeps the `FROM` order as the join order, while SQLite reorders joins by cost. It has no `ALTER TABLE`, views, triggers, window functions, `WITH`, `ON CONFLICT` or BLOB literals. Indexes cover one column, and index keys are limited to 800 bytes. Only one process may open a file at a time; there is no file locking. Deleted space is reused but never compacted. Converting REAL to TEXT matches SQLite whenever 15 digits are enough. For values that need 17 digits, SQLite's exact digit choice is approximated (it matches about 96% of random doubles), and the fuzzer compares such long decimals at 12 significant digits.
