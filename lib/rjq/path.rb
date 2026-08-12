# frozen_string_literal: true

module Rjq
  module Path
    module_function

    def get(value, path)
      path.reduce(value) { |current, key| read_index(current, key) }
    end

    def read_index(value, index)
      return read_slice(value, index) if slice_component?(index)

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
      key = path.last
      if slice_component?(key)
        replace_slice(parent, key, new_value)
        return value
      end
      key = normalize_array_key(parent, key)
      case parent
      when Array
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
      if slice_component?(key)
        replacement = parent.is_a?(String) ? '' : []
        replace_slice(parent, key, replacement)
        return value
      end
      case parent
      when Array
        if key.is_a?(Numeric) && !(key.respond_to?(:nan?) && key.nan?)
          key = key.floor
          key = parent.length + key if key.negative?
          parent.delete_at(key) unless key.negative?
        end
      when Hash
        raise TypeError, cannot_index_message(parent, key) if key.is_a?(Numeric)

        parent.delete(key)
      end
      value
    end

    def paths(value, leaves_only: false)
      out = []
      stack = [[value, nil]]
      until stack.empty?
        current, path_node = stack.pop
        scalar = !(current.is_a?(Array) || current.is_a?(Hash))
        out << materialize_path(path_node) if path_node.nil? || !leaves_only || scalar
        children = if current.is_a?(Array)
                     current.each_with_index.map { |item, index| [item, [path_node, index]] }
                   elsif current.is_a?(Hash)
                     current.map { |key, item| [item, [path_node, key]] }
                   else
                     []
                   end
        stack.concat(children.reverse)
      end
      out
    end

    def materialize_path(node)
      path = []
      while node
        node, key = node
        path << key
      end
      path.reverse
    end
    private_class_method :materialize_path

    def ensure_parent(value, path)
      current = value
      path[0...-1].each_with_index do |key, index|
        next_key = path[index + 1]
        case current
        when Array
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
      next_key.is_a?(Numeric) ? [] : {}
    end
    private_class_method :container_for

    def normalize_array_key(parent, key)
      return key unless parent.is_a?(Array)
      raise TypeError, 'array index must be an integer' unless key.is_a?(Numeric)
      raise TypeError, 'Cannot set array element at NaN index' if key.respond_to?(:nan?) && key.nan?
      raise TypeError, 'Cannot set array element at non-finite index' if key.respond_to?(:finite?) && !key.finite?

      key = key.floor
      return key unless key.negative?

      normalized = parent.length + key
      raise RuntimeError, 'Out of bounds negative array index' if normalized.negative?

      normalized
    end
    private_class_method :normalize_array_key

    def read_array(array, key)
      return nil if (key.respond_to?(:nan?) && key.nan?) || (key.respond_to?(:finite?) && !key.finite?)

      index = key.floor
      index = array.length + index if index.negative?
      index.negative? ? nil : array[index]
    end
    private_class_method :read_array

    def slice_component?(key)
      key.is_a?(Hash) && key.keys.all? { |name| %w[start end].include?(name) } &&
        (key.key?('start') || key.key?('end'))
    end
    private_class_method :slice_component?

    def read_slice(value, component)
      return nil if value.nil?

      case value
      when Array
        value[slice_range(value.length, component)] || []
      when String
        characters = value.each_char.to_a
        characters[slice_range(characters.length, component)].to_a.join
      else
        raise TypeError, "cannot slice #{Value.type_of(value)}"
      end
    end
    private_class_method :read_slice

    def replace_slice(value, component, replacement)
      case value
      when Array
        raise TypeError, 'can only assign an array to an array slice' unless replacement.is_a?(Array)

        value[slice_range(value.length, component)] = Value.deep_copy(replacement)
      when String
        raise TypeError, 'can only assign a string to a string slice' unless replacement.is_a?(String)

        characters = value.each_char.to_a
        characters[slice_range(characters.length, component)] = replacement.each_char.to_a
        value.replace(characters.join)
      else
        raise TypeError, "cannot slice #{Value.type_of(value)}"
      end
    end
    private_class_method :replace_slice

    def slice_range(length, component)
      from = slice_boundary(component['start'], length, :floor, 0)
      to = slice_boundary(component['end'], length, :ceil, length)
      from...to
    end
    private_class_method :slice_range

    def slice_boundary(value, length, rounding, default)
      return default if value.nil? || (value.respond_to?(:nan?) && value.nan?)
      raise TypeError, 'slice index must be a number' unless value.is_a?(Numeric)

      index = rounding == :ceil ? value.ceil : value.floor
      index = length + index if index.negative?
      [[index, 0].max, length].min
    end
    private_class_method :slice_boundary

    def cannot_index_message(value, key)
      key_text = key.is_a?(String) ? "string #{key.inspect}" : Value.type_of(key)
      "Cannot index #{Value.type_of(value)} with #{key_text}"
    end
    private_class_method :cannot_index_message
  end
end
