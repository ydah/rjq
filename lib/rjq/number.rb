# frozen_string_literal: true

module Rjq
  class Number < Numeric
    include Comparable

    NUMBER_PATTERN = /\A-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?\z/

    attr_reader :literal

    def self.parse(literal)
      new(literal)
    end

    def initialize(literal)
      @literal = literal.to_s.freeze
      raise ArgumentError, 'invalid number literal' unless NUMBER_PATTERN.match?(@literal)

      @value = Float(@literal)
      parse_decimal_components
      freeze
    end

    def dump
      return literal unless literal.match?(/[eE]/)

      render_exponent_literal
    end

    def to_f
      @value
    end

    def to_i
      @value.to_i
    end

    def to_int
      to_i
    end

    def to_s
      dump
    end

    def inspect
      "#<#{self.class} #{literal}>"
    end

    def <=>(other)
      return decimal_compare(other) if other.is_a?(Number)

      @value <=> numeric_value(other)
    end

    def ==(other)
      return decimal_compare(other).zero? if other.is_a?(Number)

      other.is_a?(Numeric) && @value == numeric_value(other)
    end

    def eql?(other)
      other.is_a?(Numeric) && self == other
    end

    def hash
      @value.hash
    end

    def coerce(other)
      [numeric_value(other), @value]
    end

    def +(other) = @value + numeric_value(other)
    def -(other) = @value - numeric_value(other)
    def *(other) = @value * numeric_value(other)
    def /(other) = @value / numeric_value(other)
    def %(other) = @value % numeric_value(other)
    def **(other) = @value**numeric_value(other)
    def remainder(other) = @value.remainder(numeric_value(other))
    def -@ = -@value
    def +@ = @value

    def abs = @value.abs
    def ceil = @value.ceil
    def floor = @value.floor
    def round(...) = @value.round(...)
    def truncate = @value.truncate
    def finite? = @value.finite?
    def infinite? = @value.infinite?
    def nan? = @value.nan?
    def negative? = @value.negative?
    def positive? = @value.positive?
    def zero? = @value.zero?

    def decimal_compare(other)
      sign_comparison = @decimal_sign <=> other.instance_variable_get(:@decimal_sign)
      return sign_comparison unless sign_comparison.zero?
      return 0 if @decimal_sign.zero?

      other_digits = other.instance_variable_get(:@decimal_digits)
      other_exponent = other.instance_variable_get(:@decimal_exponent)
      magnitude_comparison = (@decimal_digits.length + @decimal_exponent) <=> (other_digits.length + other_exponent)
      return magnitude_comparison * @decimal_sign unless magnitude_comparison.zero?

      coefficient_comparison = compare_coefficients(@decimal_digits, other_digits)
      coefficient_comparison * @decimal_sign
    end

    private

    def numeric_value(value)
      return value.to_f if value.is_a?(Number)
      return value if value.is_a?(Numeric)

      raise TypeError, "#{value.class} can't be coerced into #{self.class}"
    end

    def parse_decimal_components
      sign, integer, fraction, exponent = literal.match(
        /\A(-?)(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?\z/
      ).captures
      fraction ||= ''
      digits = (integer + fraction).sub(/\A0+/, '')
      if digits.empty?
        @decimal_sign = 0
        @decimal_digits = '0'.freeze
        @decimal_exponent = 0
        return
      end

      trailing_zeros = digits[/0+\z/]&.length.to_i
      @decimal_sign = sign == '-' ? -1 : 1
      @decimal_digits = digits[0, digits.length - trailing_zeros].freeze
      @decimal_exponent = (exponent ? Integer(exponent, 10) : 0) - fraction.length + trailing_zeros
    end

    def compare_coefficients(left, right)
      length = [left.length, right.length].max
      length.times do |index|
        comparison = (left.getbyte(index) || 48) <=> (right.getbyte(index) || 48)
        return comparison unless comparison.zero?
      end
      0
    end

    def render_exponent_literal
      sign, integer, fraction, exponent = literal.match(
        /\A(-?)(\d+)(?:\.(\d+))?[eE]([+-]?\d+)\z/
      ).captures
      fraction ||= ''
      exponent = Integer(exponent, 10)
      digits = integer + fraction
      first_significant = digits.index(/[1-9]/)
      return render_zero(sign, fraction.length, exponent) unless first_significant

      decimal_position = integer.length + exponent
      scientific_exponent = decimal_position - first_significant - 1
      significant = digits[first_significant..]
      if scientific_exponent.positive? || scientific_exponent < -6
        coefficient = significant.length == 1 ? significant : "#{significant[0]}.#{significant[1..]}"
        return "#{sign}#{coefficient}E#{format_exponent(scientific_exponent)}"
      end

      "#{sign}#{render_decimal(digits, decimal_position)}"
    end

    def render_zero(sign, fraction_length, exponent)
      scientific_exponent = exponent - fraction_length
      return "#{sign}0E#{format_exponent(scientific_exponent)}" if scientific_exponent.positive? || scientific_exponent < -6

      sign + render_decimal('0' * (fraction_length + 1), 1 + exponent)
    end

    def render_decimal(digits, decimal_position)
      if decimal_position <= 0
        "0.#{'0' * -decimal_position}#{digits}"
      elsif decimal_position >= digits.length
        digits + ('0' * (decimal_position - digits.length))
      else
        "#{digits[0...decimal_position]}.#{digits[decimal_position..]}"
      end.sub(/\A0+(?=\d)/, '')
    end

    def format_exponent(exponent)
      exponent.positive? ? "+#{exponent}" : exponent.to_s
    end
  end
end
