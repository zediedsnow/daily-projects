# frozen_string_literal: true

require "zlib"

module Garnet
  class Error < StandardError; end

  # The pager owns the database file. The file is an array of fixed-size
  # pages; page 0 is the header and catalog, and every other page holds one
  # B+tree node. Pages are decoded into Ruby objects and cached.
  #
  # Durability uses a rollback journal, like SQLite's default mode:
  #   1. Changes are kept only in memory until COMMIT.
  #   2. COMMIT first writes the *original* contents of every page that is
  #      about to be overwritten into <db>-journal, with a CRC, and fsyncs it.
  #   3. Then it writes the new pages into the database file and fsyncs.
  #   4. Deleting the journal is the commit point.
  # If the process dies during step 3, the next open finds a valid journal,
  # copies the original pages back and truncates the file: the half-written
  # transaction disappears. If it dies during step 2, the journal's CRC does
  # not match, and since the database file was not touched yet, the journal
  # is simply discarded.
  #
  # Statement atomicity uses an in-memory "statement journal": before a page
  # is modified for the first time within a statement, a deep copy of it is
  # saved, and a failing statement restores those copies.
  class Pager
    PAGE_SIZE = 4096
    MAGIC = "Garnet format 1"
    JOURNAL_MAGIC = "GRNTJRNL"

    attr_reader :path, :stats
    attr_accessor :crash_after_pages # testing hook: die mid-commit

    def initialize(path)
      @path = path
      @journal_path = "#{path}-journal"
      @cache = {}            # page id => decoded object
      @dirty = {}            # page id => true
      @stmt_backup = nil     # page id => deep copy (or :absent)
      @stats = Hash.new(0)
      @file = File.open(path, File.exist?(path) ? "r+b" : "w+b")
      recover_journal if File.exist?(@journal_path)
      if @file.size.zero?
        @cache[0] = { magic: MAGIC, page_count: 1, freelist: [], tables: {}, schema_version: 0 }
        @dirty[0] = true
        commit
      end
      raise Error, "not a Garnet database: #{path}" unless header[:magic] == MAGIC
    end

    def header = read(0)
    def page_count = header[:page_count]

    # Read-only access to a decoded page.
    def read(id)
      @cache.fetch(id) do
        @stats[:page_reads] += 1
        @file.seek(id * PAGE_SIZE)
        raw = @file.read(PAGE_SIZE)
        raise Error, "page #{id} is beyond end of file" unless raw && raw.bytesize == PAGE_SIZE
        len = raw.unpack1("N")
        obj = Marshal.load(raw.byteslice(4, len))
        evict_clean if @cache.size > 4000
        @cache[id] = obj
      end
    end

    # Must be called before mutating a page object in place.
    def mutable(id)
      obj = read(id)
      if @stmt_backup && !@stmt_backup.key?(id)
        @stmt_backup[id] = @dirty[id] ? Marshal.dump(obj) : :clean
      end
      @dirty[id] = true
      obj
    end

    def replace(id, obj)
      mutable(id)
      @cache[id] = obj
    end

    def allocate(obj)
      h = mutable(0)
      id = h[:freelist].pop || begin
        h[:page_count] += 1
        h[:page_count] - 1
      end
      @stmt_backup[id] = :absent if @stmt_backup && !@stmt_backup.key?(id)
      @cache[id] = obj
      @dirty[id] = true
      id
    end

    def free(id)
      mutable(0)[:freelist] << id
    end

    def fits?(obj) = Marshal.dump(obj).bytesize <= PAGE_SIZE - 4

    def in_transaction? = !@dirty.empty?

    # ---- statement-level atomicity ----

    def begin_statement = (@stmt_backup = {})
    def end_statement = (@stmt_backup = nil)

    def rollback_statement
      return unless @stmt_backup
      @stmt_backup.each do |id, saved|
        case saved
        when :absent then @cache.delete(id); @dirty.delete(id)
        when :clean then @cache.delete(id); @dirty.delete(id)
        else @cache[id] = Marshal.load(saved)
        end
      end
      @stmt_backup = nil
    end

    # ---- transactions ----

    def rollback
      @dirty.each_key { |id| @cache.delete(id) }
      @dirty.clear
    end

    def commit
      return if @dirty.empty?
      ids = @dirty.keys.sort
      encoded = ids.to_h do |id|
        data = Marshal.dump(@cache[id])
        raise Error, "page #{id} overflow (#{data.bytesize} bytes)" if data.bytesize > PAGE_SIZE - 4
        [id, [data.bytesize].pack("N") + data + ("\0" * (PAGE_SIZE - 4 - data.bytesize))]
      end
      old_pages = @file.size / PAGE_SIZE
      write_journal(ids.select { |id| id < old_pages }, old_pages) if old_pages.positive?
      ids.each_with_index do |id, i|
        Process.exit!(42) if @crash_after_pages && i == @crash_after_pages
        @file.seek(id * PAGE_SIZE)
        @file.write(encoded[id])
        @stats[:page_writes] += 1
      end
      @file.flush
      @file.fsync
      File.delete(@journal_path) if File.exist?(@journal_path)
      @dirty.clear
      @stats[:commits] += 1
    end

    def close
      rollback
      @file.close
    end

    private

    def evict_clean
      @cache.delete_if { |id, _| id != 0 && !@dirty[id] && !(@stmt_backup&.key?(id)) }
    end

    def write_journal(ids, old_pages)
      body = +"".b
      body << JOURNAL_MAGIC << [old_pages, ids.size].pack("NN")
      ids.each do |id|
        @file.seek(id * PAGE_SIZE)
        body << [id].pack("N") << @file.read(PAGE_SIZE)
      end
      body << [Zlib.crc32(body)].pack("N")
      File.open(@journal_path, "wb") do |j|
        j.write(body)
        j.flush
        j.fsync
      end
    end

    def recover_journal
      data = File.binread(@journal_path)
      ok = data.bytesize >= 16 && data.start_with?(JOURNAL_MAGIC) &&
           Zlib.crc32(data.byteslice(0, data.bytesize - 4)) == data.byteslice(-4, 4).unpack1("N")
      if ok
        old_pages, n = data.byteslice(8, 8).unpack("NN")
        pos = 16
        n.times do
          id = data.byteslice(pos, 4).unpack1("N")
          @file.seek(id * PAGE_SIZE)
          @file.write(data.byteslice(pos + 4, PAGE_SIZE))
          pos += 4 + PAGE_SIZE
        end
        @file.truncate(old_pages * PAGE_SIZE)
        @file.flush
        @file.fsync
        @stats[:recovered] = 1
      end
      File.delete(@journal_path)
    end
  end
end
