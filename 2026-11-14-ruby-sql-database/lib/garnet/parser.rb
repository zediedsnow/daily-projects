# frozen_string_literal: true

require "strscan"

module Garnet
  class SyntaxError < Error; end

  # Hand-written lexer and recursive-descent parser for Garnet's SQL dialect.
  # Expressions become nested arrays such as [:bin, "+", [:col, nil, "a"], [:lit, 1]].
  class Parser
    KEYWORDS = %w[
      SELECT FROM WHERE GROUP BY HAVING ORDER ASC DESC LIMIT OFFSET DISTINCT ALL AS
      JOIN INNER LEFT OUTER CROSS ON AND OR NOT NULL IS IN LIKE BETWEEN CASE WHEN THEN
      ELSE END EXISTS CAST INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE INDEX
      UNIQUE PRIMARY KEY DROP IF BEGIN COMMIT ROLLBACK TRANSACTION EXPLAIN UNION
      EXCEPT INTERSECT DEFAULT
    ].to_h { |k| [k, true] }

    Token = Struct.new(:type, :value, :pos)

    def self.parse(sql) = new(sql).parse_script

    def initialize(sql)
      @sql = sql
      @toks = tokenize(sql)
      @i = 0
    end

    def parse_script
      stmts = []
      loop do
        skip_semis
        break if peek.type == :eof
        start = peek.pos
        st = statement
        stmts << [st, @sql[start...peek.pos].strip]
        break if peek.type == :eof
        expect_op(";")
      end
      stmts
    end

    private

    # ---------------------------------------------------------------- lexer

    def tokenize(sql)
      s = StringScanner.new(sql)
      out = []
      until s.eos?
        pos = s.pos
        if s.skip(/\s+/) || s.skip(/--[^\n]*/) || s.skip(%r{/\*.*?\*/}m)
          next
        elsif (m = s.scan(/\d+\.\d*(?:[eE][-+]?\d+)?|\.\d+(?:[eE][-+]?\d+)?|\d+[eE][-+]?\d+/))
          out << Token.new(:num, m.to_f, pos)
        elsif (m = s.scan(/0x[0-9a-fA-F]+/))
          out << Token.new(:num, m.to_i(16), pos)
        elsif (m = s.scan(/\d+/))
          v = m.to_i
          out << Token.new(:num, v.bit_length > 63 ? m.to_f : v, pos)
        elsif s.scan(/'((?:[^']|'')*)'/)
          out << Token.new(:str, s[1].gsub("''", "'"), pos)
        elsif s.scan(/"((?:[^"]|"")*)"/) || s.scan(/`([^`]*)`/) || s.scan(/\[([^\]]*)\]/)
          out << Token.new(:id, s[1].gsub('""', '"'), pos)
        elsif (m = s.scan(/[A-Za-z_][A-Za-z0-9_$]*/))
          up = m.upcase
          out << (KEYWORDS[up] ? Token.new(:kw, up, pos) : Token.new(:id, m, pos))
        elsif (m = s.scan(/<>|!=|==|<=|>=|\|\||[-+*\/%(),.;=<>]/))
          out << Token.new(:op, m == "==" ? "=" : (m == "<>" ? "!=" : m), pos)
        else
          raise SyntaxError, "unrecognized token near #{sql[pos, 10].inspect} at offset #{pos}"
        end
      end
      out << Token.new(:eof, nil, sql.size)
    end

    # ------------------------------------------------------------- helpers

    def peek(k = 0) = @toks[@i + k]
    def advance = (@i += 1; @toks[@i - 1])
    def kw?(*names) = peek.type == :kw && names.include?(peek.value)
    def op?(o) = peek.type == :op && peek.value == o
    def accept_kw(name) = kw?(name) ? advance : nil
    def accept_op(o) = op?(o) ? advance : nil

    def expect_kw(name)
      accept_kw(name) || error("expected #{name}")
    end

    def expect_op(o)
      accept_op(o) || error("expected '#{o}'")
    end

    def error(msg)
      t = peek
      near = t.type == :eof ? "end of input" : @sql[t.pos, 15].inspect
      raise SyntaxError, "#{msg} near #{near}"
    end

    def skip_semis = (advance while op?(";"))

    def ident
      t = peek
      return advance.value if t.type == :id
      # allow a few keywords as names in practice (e.g. a column called "key")
      return advance.value.downcase if t.type == :kw && %w[KEY DEFAULT].include?(t.value)
      error("expected a name")
    end

    def if_not_exists
      return false unless accept_kw("IF")
      expect_kw("NOT")
      expect_kw("EXISTS")
      true
    end

    def if_exists
      return false unless accept_kw("IF")
      expect_kw("EXISTS")
      true
    end

    # ---------------------------------------------------------- statements

    def statement
      case
      when accept_kw("EXPLAIN") then [:explain, statement]
      when kw?("SELECT") || op?("(") then [:select, compound_select]
      when accept_kw("INSERT") then insert_stmt
      when accept_kw("UPDATE") then update_stmt
      when accept_kw("DELETE") then delete_stmt
      when accept_kw("CREATE") then create_stmt
      when accept_kw("DROP") then drop_stmt
      when accept_kw("BEGIN") then accept_kw("TRANSACTION"); [:begin]
      when accept_kw("COMMIT") || accept_kw("END") then accept_kw("TRANSACTION"); [:commit]
      when accept_kw("ROLLBACK") then accept_kw("TRANSACTION"); [:rollback]
      else error("expected a statement")
      end
    end

    def create_stmt
      unique = !!accept_kw("UNIQUE")
      if accept_kw("INDEX")
        ine = if_not_exists
        name = ident
        expect_kw("ON")
        table = ident
        expect_op("(")
        col = ident
        expect_op(")")
        return [:create_index, name, table, col, unique, ine]
      end
      error("expected INDEX") if unique
      expect_kw("TABLE")
      ine = if_not_exists
      name = ident
      expect_op("(")
      cols = []
      table_pk = nil
      loop do
        if accept_kw("PRIMARY")
          expect_kw("KEY")
          expect_op("(")
          table_pk = ident
          expect_op(")")
        else
          cols << column_def
        end
        break unless accept_op(",")
      end
      expect_op(")")
      if table_pk
        c = cols.find { |cd| cd[:name].casecmp?(table_pk) } or error("unknown column #{table_pk} in PRIMARY KEY")
        c[:pk] = true
      end
      [:create_table, name, cols, ine]
    end

    def column_def
      name = ident
      type = +""
      while peek.type == :id
        type << " " unless type.empty?
        type << advance.value
      end
      if accept_op("(") # VARCHAR(20) etc: sizes are ignored, as in SQLite
        advance until op?(")") || peek.type == :eof
        expect_op(")")
      end
      col = { name: name, type: type.upcase, pk: false, notnull: false, unique: false, default: nil }
      loop do
        if accept_kw("PRIMARY")
          expect_kw("KEY")
          accept_kw("ASC") || accept_kw("DESC")
          col[:pk] = true
        elsif accept_kw("NOT")
          expect_kw("NULL")
          col[:notnull] = true
        elsif accept_kw("NULL")
        elsif accept_kw("UNIQUE")
          col[:unique] = true
        elsif accept_kw("DEFAULT")
          col[:default] = accept_op("(") ? expr.tap { expect_op(")") } : unary
        else
          break
        end
      end
      col
    end

    def drop_stmt
      if accept_kw("TABLE")
        ie = if_exists
        [:drop_table, ident, ie]
      else
        expect_kw("INDEX")
        ie = if_exists
        [:drop_index, ident, ie]
      end
    end

    def insert_stmt
      expect_kw("INTO")
      table = ident
      cols = nil
      if op?("(") && !(peek(1).type == :kw && peek(1).value == "SELECT")
        advance
        cols = [ident]
        cols << ident while accept_op(",")
        expect_op(")")
      end
      if accept_kw("VALUES")
        rows = []
        loop do
          expect_op("(")
          row = [expr]
          row << expr while accept_op(",")
          expect_op(")")
          rows << row
          break unless accept_op(",")
        end
        [:insert, table, cols, rows]
      elsif accept_kw("DEFAULT")
        expect_kw("VALUES")
        [:insert, table, [], [[]]]
      else
        [:insert, table, cols, compound_select]
      end
    end

    def update_stmt
      table = ident
      expect_kw("SET")
      sets = []
      loop do
        c = ident
        expect_op("=")
        sets << [c, expr]
        break unless accept_op(",")
      end
      where = accept_kw("WHERE") ? expr : nil
      [:update, table, sets, where]
    end

    def delete_stmt
      expect_kw("FROM")
      table = ident
      where = accept_kw("WHERE") ? expr : nil
      [:delete, table, where]
    end

    # -------------------------------------------------------------- SELECT

    def compound_select
      left = select_core
      while kw?("UNION", "EXCEPT", "INTERSECT")
        op = advance.value
        op = "UNION ALL" if op == "UNION" && accept_kw("ALL")
        right = select_core
        left = { compound: op, left: left, right: right }
      end
      if accept_kw("ORDER")
        expect_kw("BY")
        left[:order] = order_list
      end
      if accept_kw("LIMIT")
        left[:limit] = expr
        if accept_kw("OFFSET")
          left[:offset] = expr
        elsif accept_op(",")
          left[:offset] = left[:limit]
          left[:limit] = expr
        end
      end
      left
    end

    def order_list
      list = []
      loop do
        e = expr
        desc = accept_kw("DESC") ? true : (accept_kw("ASC") && false)
        list << [e, desc]
        break unless accept_op(",")
      end
      list
    end

    def select_core
      if accept_op("(")
        s = compound_select
        expect_op(")")
        return s
      end
      expect_kw("SELECT")
      distinct = !!accept_kw("DISTINCT")
      accept_kw("ALL")
      cols = []
      loop do
        if accept_op("*")
          cols << [[:star, nil], nil]
        elsif peek.type == :id && peek(1).type == :op && peek(1).value == "." && peek(2).type == :op && peek(2).value == "*"
          t = advance.value
          advance
          advance
          cols << [[:star, t], nil]
        else
          e = expr
          as = if accept_kw("AS") then ident
               elsif peek.type == :id then advance.value
               end
          cols << [e, as]
        end
        break unless accept_op(",")
      end
      from = []
      if accept_kw("FROM")
        from << table_ref(:first)
        loop do
          if accept_op(",")
            from << table_ref(:cross)
          elsif accept_kw("CROSS")
            expect_kw("JOIN")
            from << table_ref(:cross)
          elsif kw?("JOIN", "INNER", "LEFT")
            kind = :inner
            if accept_kw("LEFT")
              accept_kw("OUTER")
              kind = :left
            else
              accept_kw("INNER")
            end
            expect_kw("JOIN")
            t = table_ref(kind)
            t[:on] = expr if accept_kw("ON")
            from << t
          else
            break
          end
        end
      end
      where = accept_kw("WHERE") ? expr : nil
      group = nil
      having = nil
      if accept_kw("GROUP")
        expect_kw("BY")
        group = [expr]
        group << expr while accept_op(",")
      end
      having = expr if accept_kw("HAVING")
      { distinct: distinct, cols: cols, from: from, where: where, group: group, having: having }
    end

    def table_ref(kind)
      if op?("(")
        advance
        sub = compound_select
        expect_op(")")
        accept_kw("AS")
        return { sub: sub, alias: ident, join: kind }
      end
      name = ident
      as = if accept_kw("AS") then ident
           elsif peek.type == :id then advance.value
           end
      { table: name, alias: as || name, join: kind }
    end

    # --------------------------------------------------------- expressions

    def expr = or_expr

    def or_expr
      e = and_expr
      e = [:bin, "or", e, and_expr] while accept_kw("OR")
      e
    end

    def and_expr
      e = not_expr
      e = [:bin, "and", e, not_expr] while accept_kw("AND")
      e
    end

    def not_expr
      return [:not, not_expr] if accept_kw("NOT")
      equality
    end

    def equality
      e = relational
      loop do
        if op?("=") || op?("!=")
          op = advance.value
          e = [:bin, op, e, relational]
        elsif accept_kw("IS")
          neg = !!accept_kw("NOT")
          e = [:is, e, relational, neg]
        elsif kw?("NOT") && peek(1).type == :kw && %w[IN LIKE BETWEEN NULL].include?(peek(1).value)
          advance
          e = postfix(e, true)
        elsif kw?("IN", "LIKE", "BETWEEN")
          e = postfix(e, false)
        else
          return e
        end
      end
    end

    def postfix(e, neg)
      if accept_kw("NULL") # NOT NULL
        return [:is, e, [:lit, nil], true]
      elsif accept_kw("IN")
        expect_op("(")
        if kw?("SELECT")
          s = compound_select
          expect_op(")")
          return [:insub, e, s, neg]
        end
        list = []
        unless op?(")")
          list << expr
          list << expr while accept_op(",")
        end
        expect_op(")")
        [:in, e, list, neg]
      elsif accept_kw("LIKE")
        [:like, e, relational, neg]
      else
        expect_kw("BETWEEN")
        lo = relational
        expect_kw("AND")
        [:between, e, lo, relational, neg]
      end
    end

    def relational
      e = additive
      while peek.type == :op && %w[< <= > >=].include?(peek.value)
        op = advance.value
        e = [:bin, op, e, additive]
      end
      e
    end

    def additive
      e = multiplicative
      while op?("+") || op?("-")
        op = advance.value
        e = [:bin, op, e, multiplicative]
      end
      e
    end

    def multiplicative
      e = concat
      while op?("*") || op?("/") || op?("%")
        op = advance.value
        e = [:bin, op, e, concat]
      end
      e
    end

    def concat
      e = unary
      e = [:bin, "||", e, unary] while accept_op("||")
      e
    end

    def unary
      if accept_op("-")
        inner = unary
        return [:lit, -inner[1]] if inner[0] == :lit && inner[1].is_a?(Numeric)
        return [:neg, inner]
      end
      return unary if accept_op("+")
      primary
    end

    def primary
      t = peek
      case t.type
      when :num then advance; [:lit, t.value]
      when :str then advance; [:lit, t.value]
      when :op
        error("expected an expression") unless t.value == "("
        advance
        if kw?("SELECT")
          s = compound_select
          expect_op(")")
          return [:subq, s]
        end
        e = expr
        expect_op(")")
        e
      when :kw
        case t.value
        when "NULL" then advance; [:lit, nil]
        when "CASE" then advance; case_expr
        when "EXISTS"
          advance
          expect_op("(")
          s = compound_select
          expect_op(")")
          [:exists, s]
        when "CAST"
          advance
          expect_op("(")
          e = expr
          expect_kw("AS")
          type = ident.upcase
          expect_op(")")
          [:cast, e, type]
        when "KEY", "DEFAULT" then [:col, nil, ident]
        else error("unexpected #{t.value}")
        end
      when :id
        name = advance.value
        if accept_op("(")
          fn = name.downcase
          if accept_op("*")
            expect_op(")")
            return [:fn, fn, [], false, true]
          end
          distinct = !!accept_kw("DISTINCT")
          args = []
          unless op?(")")
            args << expr
            args << expr while accept_op(",")
          end
          expect_op(")")
          [:fn, fn, args, distinct, false]
        elsif accept_op(".")
          [:col, name, ident]
        else
          [:col, nil, name]
        end
      else
        error("expected an expression")
      end
    end

    def case_expr
      base = kw?("WHEN") ? nil : expr
      whens = []
      while accept_kw("WHEN")
        w = expr
        expect_kw("THEN")
        whens << [w, expr]
      end
      error("CASE needs at least one WHEN") if whens.empty?
      els = accept_kw("ELSE") ? expr : nil
      expect_kw("END")
      [:case, base, whens, els]
    end
  end
end
