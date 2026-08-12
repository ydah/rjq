# frozen_string_literal: true

module Rjq
  module Value
    TYPE_ORDER = {
      'null' => 0,
      'boolean' => 1,
      'number' => 2,
      'string' => 3,
      'array' => 4,
      'object' => 5
    }.freeze

    module_function

    def type_of(value)
      case value
      when NilClass
        'null'
      when TrueClass, FalseClass
        'boolean'
      when Numeric
        'number'
      when String
        'string'
      when Array
        'array'
      when Hash
        'object'
      else
        raise TypeError, "unsupported value type: #{value.class}"
      end
    end

    def truthy?(value)
      !(value.nil? || value == false)
    end

    def equal?(left, right)
      left_type = type_of(left)
      right_type = type_of(right)
      return numeric_equal?(left, right) if left_type == 'number' && right_type == 'number'
      return false unless left_type == right_type

      case left_type
      when 'array'
        left.length == right.length && left.zip(right).all? { |a, b| equal?(a, b) }
      when 'object'
        left.keys.sort == right.keys.sort && left.all? { |key, value| right.key?(key) && equal?(value, right[key]) }
      else
        left == right
      end
    end

    def compare(left, right)
      left_type = type_of(left)
      right_type = type_of(right)
      type_cmp = TYPE_ORDER.fetch(left_type) <=> TYPE_ORDER.fetch(right_type)
      return type_cmp unless type_cmp.zero?

      case left_type
      when 'null'
        0
      when 'boolean'
        bool_rank(left) <=> bool_rank(right)
      when 'number'
        numeric_compare(left, right)
      when 'string'
        left <=> right
      when 'array'
        compare_arrays(left, right)
      when 'object'
        compare_objects(left, right)
      end
    end

    def deep_copy(value)
      case value
      when Array
        value.map { |item| deep_copy(item) }
      when Hash
        value.each_with_object({}) { |(key, item), out| out[key] = deep_copy(item) }
      else
        value
      end
    end

    def numeric_equal?(left, right)
      return false if nan_number?(left) || nan_number?(right)

      numeric_compare(left, right).zero?
    end
    private_class_method :numeric_equal?

    def unsafe_integer?(value)
      value.is_a?(Integer) && value.abs > (2**53)
    end
    private_class_method :unsafe_integer?

    def bool_rank(value)
      value ? 1 : 0
    end
    private_class_method :bool_rank

    def numeric_compare(left, right)
      left_nan = nan_number?(left)
      right_nan = nan_number?(right)
      return 0 if left_nan && right_nan
      return -1 if left_nan
      return 1 if right_nan

      return left.decimal_compare(right) if left.is_a?(Number) && right.is_a?(Number)
      return left.decimal_compare(Number.parse(right.to_s)) if left.is_a?(Number) && right.is_a?(Integer)
      return -right.decimal_compare(Number.parse(left.to_s)) if left.is_a?(Integer) && right.is_a?(Number)

      comparable_number(left) <=> comparable_number(right)
    end
    private_class_method :numeric_compare

    def nan_number?(value)
      value.respond_to?(:nan?) && value.nan?
    end
    private_class_method :nan_number?

    def comparable_number(value)
      return value.to_f if value.is_a?(Number) || unsafe_integer?(value)

      value
    end
    private_class_method :comparable_number

    def compare_arrays(left, right)
      max = [left.length, right.length].min
      max.times do |index|
        cmp = compare(left[index], right[index])
        return cmp unless cmp.zero?
      end
      left.length <=> right.length
    end
    private_class_method :compare_arrays

    def compare_objects(left, right)
      left_keys = left.keys.sort
      right_keys = right.keys.sort
      key_cmp = compare_arrays(left_keys, right_keys)
      return key_cmp unless key_cmp.zero?

      left_keys.each do |key|
        value_cmp = compare(left[key], right[key])
        return value_cmp unless value_cmp.zero?
      end
      0
    end
    private_class_method :compare_objects
  end
end
