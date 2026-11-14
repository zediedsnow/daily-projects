# frozen_string_literal: true

module Garnet
  # SQL scalar semantics, modelled closely on SQLite: dynamic typing with
  # column affinity, three-valued logic, integer vs real arithmetic.
  module Ops
    module_function

    INT_MIN = -(2**63)
    INT_MAX = 2**63 - 1
    STRICT_NUM = /\A\s*([-+]?(?:\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?)\s*\z/
    PREFIX_NUM = /\A\s*([-+]?(?:\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?)/
    NUMERICISH = { integer: true, real: true, numeric: true }.freeze

    # Column type name -> affinity, using SQLite's rules (section 3.1 of
    # "Datatypes In SQLite").
    def affinity_of(type)
      t = type.to_s.upcase
      return :integer if t.include?("INT")
      return :text if t.include?("CHAR") || t.include?("CLOB") || t.include?("TEXT")
      return :blob if t.include?("BLOB") || t.empty?
      return :real if t.include?("REAL") || t.include?("FLOA") || t.include?("DOUB")
      :numeric
    end

    def numericish?(aff) = NUMERICISH.key?(aff)

    def fix_int(i) = (i < INT_MIN || i > INT_MAX ? i.to_f : i)

    # Parse a whole string as a number, or nil.
    def strict_number(s)
      m = STRICT_NUM.match(s) or return nil
      if m[2] || m[3]
        m[1].to_f
      else
        fix_int(m[1].to_i)
      end
    end

    def apply_affinity(v, aff)
      case aff
      when :integer, :numeric
        v = strict_number(v) || v if v.is_a?(String)
        v.is_a?(Float) && v.finite? && v == v.floor && v.abs < 9.2e18 ? v.to_i : v
      when :real
        v = strict_number(v) || v if v.is_a?(String)
        v.is_a?(Integer) ? v.to_f : v
      when :text
        v.is_a?(Numeric) ? to_text(v) : v
      else
        v
      end
    end

    # Coercion used inside comparisons (numeric affinity keeps integral
    # reals as reals, which compare equal to integers anyway).
    def coerce_numeric(v) = v.is_a?(String) ? (strict_number(v) || v) : v
    def coerce_text(v) = v.is_a?(Numeric) ? to_text(v) : v

    # SQLite's comparison-affinity rule: returns [coerce_left, coerce_right].
    def comparison_coercions(la, ra)
      if numericish?(la) && !numericish?(ra) then [nil, :num]
      elsif numericish?(ra) && !numericish?(la) then [:num, nil]
      elsif la == :text && ra.nil? then [nil, :text]
      elsif ra == :text && la.nil? then [:text, nil]
      else [nil, nil]
      end
    end

    def coerce(kind, v)
      case kind
      when :num then coerce_numeric(v)
      when :text then coerce_text(v)
      else v
      end
    end

    # REAL -> TEXT the way SQLite 3.4x+ does it: 15 significant digits if
    # that round-trips, otherwise 17 (obtained by rounding an 18-digit
    # expansion, which is why SQLite prints 1/3.0 as 0.33333333333333332).
    # Plain notation is used for decimal exponents -4..16.
    def float_text(f)
      return f.positive? ? "Inf" : "-Inf" if f.infinite?
      return "0.0" if f.zero?
      neg = f.negative?
      m, e = format("%.14e", f.abs).split("e")
      if "#{m}e#{e}".to_f != f.abs
        m, e = format("%.17e", f.abs).split("e")
        digs = m.delete(".")
        d17 = digs[0, 17].to_i + (digs[17].to_i >= 5 ? 1 : 0)
        exp = e.to_i
        if d17 >= 10**17
          d17 /= 10
          exp += 1
        end
        digits = d17.to_s
      else
        digits = m.delete(".")
        exp = e.to_i
      end
      digits = digits.sub(/0+\z/, "")
      digits = "0" if digits.empty?
      body = if exp < -4 || exp > 16
               "#{digits[0]}.#{digits[1..].empty? ? '0' : digits[1..]}e#{exp.negative? ? '-' : '+'}#{format('%02d', exp.abs)}"
             elsif exp.negative?
               "0.#{'0' * (-exp - 1)}#{digits}"
             elsif digits.size > exp + 1
               "#{digits[0..exp]}.#{digits[(exp + 1)..]}"
             else
               "#{digits}#{'0' * (exp + 1 - digits.size)}.0"
             end
      neg ? "-#{body}" : body
    end

    def to_text(v)
      case v
      when nil then nil
      when Integer then v.to_s
      when Float then float_text(v)
      else v
      end
    end

    # Lenient numeric conversion used by arithmetic ('12abc' -> 12).
    def to_num(v)
      return v if v.is_a?(Numeric)
      m = PREFIX_NUM.match(v) or return 0
      m[2] || m[3] ? m[1].to_f : fix_int(m[1].to_i)
    end

    def truthy(v)
      case v
      when nil then nil
      when Numeric then v != 0
      else to_num(v) != 0
      end
    end

    def arith(op, a, b)
      return nil if a.nil? || b.nil?
      a = to_num(a)
      b = to_num(b)
      if a.is_a?(Integer) && b.is_a?(Integer)
        case op
        when "+" then fix_int(a + b)
        when "-" then fix_int(a - b)
        when "*" then fix_int(a * b)
        when "/"
          return nil if b.zero?
          q = a.abs / b.abs
          fix_int((a.negative? ^ b.negative?) ? -q : q)
        when "%"
          return nil if b.zero?
          r = a.abs % b.abs
          a.negative? ? -r : r
        end
      else
        a = a.to_f
        b = b.to_f
        case op
        when "+" then a + b
        when "-" then a - b
        when "*" then a * b
        when "/" then b.zero? ? nil : a / b
        when "%"
          ai = a.truncate
          bi = b.truncate
          return nil if bi.zero?
          r = ai.abs % bi.abs
          (ai.negative? ? -r : r).to_f
        end
      end
    end

    def like_regex(pat)
      body = +""
      pat.each_char do |ch|
        body << case ch
                when "%" then ".*"
                when "_" then "."
                else Regexp.escape(ch)
                end
      end
      Regexp.new("\\A#{body}\\z", Regexp::IGNORECASE | Regexp::MULTILINE)
    end

    # Key used for GROUP BY / DISTINCT / hash joins: 1 and 1.0 are the same.
    def norm(v)
      v.is_a?(Float) && v.finite? && v == v.floor && v.abs < 9.2e18 ? v.to_i : v
    end
  end
end
