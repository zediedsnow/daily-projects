# frozen_string_literal: true

module Garnet
  # SQL value ordering (same as SQLite): NULL < numbers < text.
  module Values
    module_function

    def rank(v)
      case v
      when nil then 0
      when Numeric then 1
      else 2
      end
    end

    def cmp(a, b)
      ra = rank(a)
      rb = rank(b)
      return ra <=> rb if ra != rb
      return 0 if ra.zero?
      a <=> b
    end

    # Index keys are [value, rowid]; :min / :max are sentinels for seeking.
    def cmp_key(a, b)
      if a.is_a?(Array)
        c = cmp(a[0], b[0])
        return c unless c.zero?
        x = a[1]
        y = b[1]
        return 0 if x.equal?(y)
        return -1 if x == :min || y == :max
        return 1 if x == :max || y == :min
        x <=> y
      else
        a <=> b
      end
    end
  end

  # A B+tree stored in pager pages. Leaves hold (key, value) pairs and are
  # chained left to right for range scans; internal nodes hold separator
  # keys. The root page id never changes: when the root splits, its contents
  # move to a fresh page and the root becomes a new internal node. Nodes are
  # split by *encoded size*, not by count, so variable-length rows pack well.
  class BTree
    attr_reader :root

    def self.create(pager)
      pager.allocate({ leaf: true, keys: [], vals: [], next: nil })
    end

    def initialize(pager, root)
      @pager = pager
      @root = root
    end

    def get(key)
      node = @pager.read(@root)
      node = @pager.read(node[:kids][upper(node[:keys], key)]) until node[:leaf]
      i = lower(node[:keys], key)
      i < node[:keys].size && Values.cmp_key(node[:keys][i], key).zero? ? [true, node[:vals][i]] : [false, nil]
    end

    # Insert or replace. Returns true if the key was new.
    def put(key, val)
      fresh, split = insert(@root, key, val)
      if split
        sep, right = split
        old = @pager.read(@root)
        left = @pager.allocate(old)
        @pager.replace(@root, { leaf: false, keys: [sep], kids: [left, right] })
      end
      fresh
    end

    def delete(key)
      id = @root
      node = @pager.read(id)
      until node[:leaf]
        id = node[:kids][upper(node[:keys], key)]
        node = @pager.read(id)
      end
      i = lower(node[:keys], key)
      return false unless i < node[:keys].size && Values.cmp_key(node[:keys][i], key).zero?
      node = @pager.mutable(id)
      node[:keys].delete_at(i)
      node[:vals].delete_at(i)
      true
    end

    # Yields [key, val] in order starting at the first key >= from.
    def each(from = nil)
      return enum_for(:each, from) unless block_given?
      node = @pager.read(@root)
      if from.nil?
        node = @pager.read(node[:kids][0]) until node[:leaf]
        i = 0
      else
        node = @pager.read(node[:kids][upper(node[:keys], from)]) until node[:leaf]
        i = lower(node[:keys], from)
      end
      loop do
        keys = node[:keys]
        vals = node[:vals]
        while i < keys.size
          yield keys[i], vals[i]
          i += 1
        end
        nxt = node[:next] or break
        node = @pager.read(nxt)
        i = 0
      end
    end

    def last_key
      node = @pager.read(@root)
      node = @pager.read(node[:kids].last) until node[:leaf]
      while node[:keys].empty?
        # rightmost leaf emptied by deletes: fall back to a full scan
        last = nil
        each { |k, _| last = k }
        return last
      end
      node[:keys].last
    end

    def pages(id = @root, acc = [])
      acc << id
      node = @pager.read(id)
      node[:kids].each { |k| pages(k, acc) } unless node[:leaf]
      acc
    end

    def depth
      d = 1
      node = @pager.read(@root)
      until node[:leaf]
        node = @pager.read(node[:kids][0])
        d += 1
      end
      d
    end

    private

    # first index with keys[i] >= key
    def lower(keys, key)
      lo = 0
      hi = keys.size
      while lo < hi
        mid = (lo + hi) >> 1
        if Values.cmp_key(keys[mid], key).negative? then lo = mid + 1 else hi = mid end
      end
      lo
    end

    # first index with keys[i] > key
    def upper(keys, key)
      lo = 0
      hi = keys.size
      while lo < hi
        mid = (lo + hi) >> 1
        if Values.cmp_key(keys[mid], key) <= 0 then lo = mid + 1 else hi = mid end
      end
      lo
    end

    def insert(id, key, val)
      node = @pager.mutable(id)
      if node[:leaf]
        i = lower(node[:keys], key)
        if i < node[:keys].size && Values.cmp_key(node[:keys][i], key).zero?
          node[:vals][i] = val
          fresh = false
        else
          node[:keys].insert(i, key)
          node[:vals].insert(i, val)
          fresh = true
        end
        return [fresh, nil] if fits_after_add?(node, key, val)
        [fresh, split_leaf(node)]
      else
        i = upper(node[:keys], key)
        fresh, split = insert(node[:kids][i], key, val)
        return [fresh, nil] unless split
        node = @pager.mutable(id)
        node[:keys].insert(i, split[0])
        node[:kids].insert(i + 1, split[1])
        return [fresh, nil] if fits_after_add?(node, split[0], split[1])
        [fresh, split_internal(node)]
      end
    end

    LIMIT = Pager::PAGE_SIZE - 4

    # Encoding a whole page on every insert would dominate the cost, so each
    # node carries an upper-bound estimate of its encoded size (:sz). Only
    # when the estimate crosses the page size is the node encoded exactly.
    def fits_after_add?(node, key, val)
      est = node[:sz]
      est = est ? est + Marshal.dump(key).bytesize + Marshal.dump(val).bytesize : LIMIT + 1
      if est > LIMIT
        node[:sz] = 65_535 # same encoded width as any real estimate
        est = Marshal.dump(node).bytesize
      end
      node[:sz] = est
      est <= LIMIT
    end

    # Index where the cumulative encoded size first passes half.
    def balance_point(items)
      sizes = items.map { |x| Marshal.dump(x).bytesize }
      half = sizes.sum / 2
      acc = 0
      sizes.each_with_index do |s, i|
        acc += s
        return i.clamp(1, items.size - 1) if acc >= half
      end
      items.size / 2
    end

    def split_leaf(node)
      m = balance_point(node[:keys].zip(node[:vals]))
      right = { leaf: true, keys: node[:keys].slice!(m..), vals: node[:vals].slice!(m..), next: node[:next], sz: nil }
      node[:sz] = nil
      rid = @pager.allocate(right)
      node[:next] = rid
      [right[:keys][0], rid]
    end

    def split_internal(node)
      m = balance_point(node[:keys])
      sep = node[:keys][m]
      right = { leaf: false, keys: node[:keys].slice!((m + 1)..), kids: node[:kids].slice!((m + 1)..), sz: nil }
      node[:sz] = nil
      node[:keys].pop # remove sep
      [sep, @pager.allocate(right)]
    end
  end
end
