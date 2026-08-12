# frozen_string_literal: true

module Rjq
  module JSON
    module Dumper
      module_function

      def dump(value, indent: 2, sort_keys: false, ascii: false, tab: false, io: nil)
        destination = io || +''
        step = tab ? "\t" : (' ' * Integer(indent || 0))
        write(value, destination, indent.nil? ? nil : step, sort_keys, ascii)
        io || destination
      end

      def write(value, destination, indent, sort_keys, ascii)
        active = {}
        stack = [[:value, value, 0]]
        until stack.empty?
          type, item, depth = stack.pop
          case type
          when :text
            destination << item
          when :leave
            active.delete(item)
          when :array_items
            write_array_item(item, depth, destination, stack, indent)
          when :object_items
            write_object_item(item, depth, destination, stack, indent, ascii)
          when :value
            write_value(item, depth, destination, stack, active, indent, sort_keys, ascii)
          end
        end
      end
      private_class_method :write

      def write_value(value, depth, destination, stack, active, indent, sort_keys, ascii)
        case value
        when NilClass
          destination << 'null'
        when TrueClass
          destination << 'true'
        when FalseClass
          destination << 'false'
        when Number
          destination << value.dump
        when Integer
          destination << value.to_s
        when Float
          destination << dump_float(value)
        when String
          destination << dump_string(value, ascii)
        when Array
          write_array(value, depth, destination, stack, active, indent)
        when Hash
          write_object(value, depth, destination, stack, active, indent, sort_keys, ascii)
        else
          raise TypeError, "unsupported value type: #{value.class}"
        end
      end
      private_class_method :write_value

      def write_array(value, depth, destination, stack, active, indent)
        return destination << '[]' if value.empty?

        enter_container(value, active)
        destination << (indent ? "[\n" : '[')
        stack << [:leave, value.object_id, nil]
        stack << [:text, indent ? "\n#{indent * depth}]" : ']', nil]
        stack << [:array_items, [value, 0], depth]
      end
      private_class_method :write_array

      def write_array_item(payload, depth, destination, stack, indent)
        value, index = payload
        return if index >= value.length

        destination << if index.zero?
                         indent ? indent * (depth + 1) : ''
                       else
                         indent ? ",\n#{indent * (depth + 1)}" : ','
                       end
        stack << [:array_items, [value, index + 1], depth]
        stack << [:value, value[index], depth + 1]
      end
      private_class_method :write_array_item

      def write_object(value, depth, destination, stack, active, indent, sort_keys, ascii)
        return destination << '{}' if value.empty?

        validate_object_keys!(value)
        enter_container(value, active)
        destination << (indent ? "{\n" : '{')
        keys = sort_keys ? value.keys.sort : value.keys
        stack << [:leave, value.object_id, nil]
        stack << [:text, indent ? "\n#{indent * depth}}" : '}', nil]
        stack << [:object_items, [value, keys, 0], depth]
      end
      private_class_method :write_object

      def write_object_item(payload, depth, destination, stack, indent, ascii)
        value, keys, index = payload
        return if index >= keys.length

        destination << if index.zero?
                         indent ? indent * (depth + 1) : ''
                       else
                         indent ? ",\n#{indent * (depth + 1)}" : ','
                       end
        key = keys[index]
        destination << dump_string(key, ascii)
        destination << (indent ? ': ' : ':')
        stack << [:object_items, [value, keys, index + 1], depth]
        stack << [:value, value.fetch(key), depth + 1]
      end
      private_class_method :write_object_item

      def enter_container(value, active)
        raise TypeError, 'cannot dump a cyclic JSON value' if active[value.object_id]

        active[value.object_id] = true
      end
      private_class_method :enter_container

      def validate_object_keys!(value)
        invalid = value.keys.find { |key| !key.is_a?(String) }
        raise TypeError, "object key must be a string, got #{invalid.class}" if invalid
      end
      private_class_method :validate_object_keys!

      def dump_float(value)
        return 'null' if value.nan?
        return Float::MAX.to_s if value.infinite? == 1
        return "-#{Float::MAX}" if value.infinite? == -1
        return '-0' if value.zero? && (1.0 / value).infinite? == -1

        text = value.to_s.sub(/\.0(?=e)/, '')
        if value == value.to_i
          integer_text = value.to_i.to_s
          return integer_text if value.abs < 1e16 || integer_text.length <= text.length
        end
        text.include?('.') || text.match?(/[eE]/) ? text : "#{text}.0"
      end
      private_class_method :dump_float

      def dump_string(value, ascii)
        string = value.encode(Encoding::UTF_8)
        raise TypeError, 'invalid UTF-8 string' unless string.valid_encoding?

        escaped = string.each_codepoint.map { |codepoint| escape_codepoint(codepoint, ascii) }.join
        "\"#{escaped}\""
      rescue EncodingError
        raise TypeError, 'invalid UTF-8 string'
      end
      private_class_method :dump_string

      def escape_codepoint(codepoint, ascii)
        case codepoint
        when 0x22
          '\"'
        when 0x5C
          '\\\\'
        when 0x08
          '\\b'
        when 0x0C
          '\\f'
        when 0x0A
          '\\n'
        when 0x0D
          '\\r'
        when 0x09
          '\\t'
        when 0x00..0x1F
          '\\u%04x' % codepoint
        else
          ascii && codepoint > 0x7F ? unicode_escape(codepoint) : [codepoint].pack('U')
        end
      end
      private_class_method :escape_codepoint

      def unicode_escape(codepoint)
        return '\\u%04x' % codepoint if codepoint <= 0xFFFF

        n = codepoint - 0x10000
        high = 0xD800 + (n >> 10)
        low = 0xDC00 + (n & 0x3FF)
        format('\\u%04x\\u%04x', high, low)
      end
      private_class_method :unicode_escape
    end
  end
end
