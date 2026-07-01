# frozen_string_literal: true

module Rjq
  module Path
    module_function

    def get(value, path)
      path.reduce(value) { |current, key| read_index(current, key) }
    end

    def read_index(value, index)
      case value
      when NilClass
        raise TypeError, cannot_index_message(value, index) unless index.is_a?(String) || index.is_a?(Numeric)

        nil
      when Array
        raise TypeError, cannot_index_message(value, index) unless index.is_a?(Numeric)

        read_array(value, index)
      when Hash
        raise TypeError, cannot_index_message(value, index) unless index.is_a?(String)

        value[index]
      when String
        raise TypeError, cannot_index_message(value, index)
      else
        raise TypeError, cannot_index_message(value, index)
      end
    end

    def set(value, path, new_value)
      return new_value if path.empty?

      value = container_for(path.first) if value.nil?
      parent = ensure_parent(value, path)
      key = normalize_array_key(parent, path.last)
      case parent
      when Array
        raise TypeError, 'Cannot set array element at NaN index' if key.respond_to?(:nan?) && key.nan?
        raise TypeError, 'array index must be an integer' unless key.is_a?(Numeric)

        key = key.floor
        parent[key] = new_value
      when Hash
        raise TypeError, cannot_index_message(parent, key) if key.is_a?(Numeric)

        parent[key.to_s] = new_value
      else
        raise TypeError, cannot_index_message(parent, key)
      end
      value
    end

    def delete(value, path)
      return nil if path.empty?

      parent = get(value, path[0...-1])
      key = path.last
      case parent
      when Array
        if key.is_a?(Numeric) && !(key.respond_to?(:nan?) && key.nan?)
          key = key.floor
          key = parent.length + key if key.negative?
          parent.delete_at(key) unless key.negative?
        end
      when Hash
        parent.delete(key.to_s)
      end
      value
    end

    def paths(value, leaves_only: false)
      out = []
      visit = lambda do |current, path|
        scalar = !(current.is_a?(Array) || current.is_a?(Hash))
        out << path if path.empty? || !leaves_only || scalar
        case current
        when Array
          current.each_with_index { |item, index| visit.call(item, path + [index]) }
        when Hash
          current.each { |key, item| visit.call(item, path + [key]) }
        end
      end
      visit.call(value, [])
      out
    end

    def ensure_parent(value, path)
      current = value
      path[0...-1].each_with_index do |key, index|
        next_key = path[index + 1]
        case current
        when Array
          raise TypeError, 'Cannot set array element at NaN index' if key.respond_to?(:nan?) && key.nan?
          raise TypeError, 'array index must be an integer' unless key.is_a?(Numeric)

          key = key.floor
          key = normalize_array_key(current, key)
          current[key] = container_for(next_key) if current[key].nil?
          current = current[key]
        when Hash
          raise TypeError, cannot_index_message(current, key) if key.is_a?(Numeric)

          current[key.to_s] = container_for(next_key) if current[key.to_s].nil?
          current = current[key.to_s]
        else
          raise TypeError, cannot_index_message(current, key)
        end
      end
      current
    end
    private_class_method :ensure_parent

    def container_for(next_key)
      next_key.is_a?(Integer) ? [] : {}
    end
    private_class_method :container_for

    def normalize_array_key(parent, key)
      return key unless parent.is_a?(Array) && key.is_a?(Integer) && key.negative?

      normalized = parent.length + key
      raise RuntimeError, 'Out of bounds negative array index' if normalized.negative?

      normalized
    end
    private_class_method :normalize_array_key

    def read_array(array, key)
      return nil if key.respond_to?(:nan?) && key.nan?

      index = key.floor
      index = array.length + index if index.negative?
      index.negative? ? nil : array[index]
    end
    private_class_method :read_array

    def cannot_index_message(value, key)
      key_text = key.is_a?(String) ? "string #{key.inspect}" : Value.type_of(key)
      "Cannot index #{Value.type_of(value)} with #{key_text}"
    end
    private_class_method :cannot_index_message
  end
end
