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

    def validate!(value)
      active = {}
      stack = [[:value, value]]
      until stack.empty?
        type, item = stack.pop
        if type == :leave
          active.delete(item)
          next
        end

        case item
        when NilClass, TrueClass, FalseClass, Numeric
          next
        when String
          raise TypeError, 'invalid UTF-8 string' unless item.encoding == Encoding::UTF_8 && item.valid_encoding?
        when Array
          enter_validation_container!(item, active)
          stack << [:leave, item.object_id]
          item.reverse_each { |child| stack << [:value, child] }
        when Hash
          invalid = item.keys.find { |key| !key.is_a?(String) }
          raise TypeError, "object key must be a string, got #{invalid.class}" if invalid

          enter_validation_container!(item, active)
          stack << [:leave, item.object_id]
          item.values.reverse_each { |child| stack << [:value, child] }
        else
          raise TypeError, "unsupported value type: #{item.class}"
        end
      end
      value
    end

    def enter_validation_container!(value, active)
      raise TypeError, 'cyclic JSON value' if active[value.object_id]

      active[value.object_id] = true
    end
    private_class_method :enter_validation_container!

    def equal?(left, right)
      stack = [[left, right]]
      until stack.empty?
        left_value, right_value = stack.pop
        left_type = type_of(left_value)
        right_type = type_of(right_value)
        if left_type == 'number' && right_type == 'number'
          return false unless numeric_equal?(left_value, right_value)
          next
        end
        return false unless left_type == right_type

        case left_type
        when 'array'
          return false unless left_value.length == right_value.length

          (left_value.length - 1).downto(0) { |index| stack << [left_value[index], right_value[index]] }
        when 'object'
          left_keys = left_value.keys.sort
          return false unless left_keys == right_value.keys.sort

          left_keys.reverse_each { |key| stack << [left_value.fetch(key), right_value.fetch(key)] }
        else
          return false unless left_value == right_value
        end
      end
      true
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
      root = []
      active = {}
      stack = [[:copy, value, [:array, root, 0]]]
      until stack.empty?
        type, source, target = stack.pop
        case type
        when :leave
          active.delete(source)
        when :array_items
          original, copy, index = source
          next if index >= original.length

          stack << [:array_items, [original, copy, index + 1], nil]
          stack << [:copy, original[index], [:array, copy, index]]
        when :object_items
          original, copy, keys, index = source
          next if index >= keys.length

          key = keys[index]
          stack << [:object_items, [original, copy, keys, index + 1], nil]
          stack << [:copy, original.fetch(key), [:object, copy, key.dup]]
        when :copy
          copied = copy_scalar(source)
          if source.is_a?(Array)
            enter_copy_container!(source, active)
            copied = Array.new(source.length)
            stack << [:leave, source.object_id, nil]
            stack << [:array_items, [source, copied, 0], nil]
          elsif source.is_a?(Hash)
            validate_copy_keys!(source)
            enter_copy_container!(source, active)
            copied = {}
            stack << [:leave, source.object_id, nil]
            stack << [:object_items, [source, copied, source.keys, 0], nil]
          end
          assign_copy(target, copied)
        end
      end
      root.fetch(0)
    end

    def copy_scalar(value)
      case value
      when String then value.dup
      when NilClass, TrueClass, FalseClass, Numeric, Array, Hash then value
      else raise TypeError, "unsupported value type: #{value.class}"
      end
    end
    private_class_method :copy_scalar

    def enter_copy_container!(value, active)
      raise TypeError, 'cannot copy a cyclic JSON value' if active[value.object_id]

      active[value.object_id] = true
    end
    private_class_method :enter_copy_container!

    def validate_copy_keys!(value)
      invalid = value.keys.find { |key| !key.is_a?(String) }
      raise TypeError, "object key must be a string, got #{invalid.class}" if invalid
    end
    private_class_method :validate_copy_keys!

    def assign_copy(target, value)
      _type, container, key = target
      container[key] = value
    end
    private_class_method :assign_copy

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
