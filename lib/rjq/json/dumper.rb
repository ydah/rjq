# frozen_string_literal: true

module Rjq
  module JSON
    module Dumper
      module_function

      def dump(value, indent: 2, sort_keys: false, ascii: false, tab: false)
        step = tab ? "\t" : (' ' * Integer(indent || 0))
        write(value, indent.nil? ? nil : step, 0, sort_keys, ascii)
      end

      def write(value, indent, depth, sort_keys, ascii)
        case value
        when NilClass
          'null'
        when TrueClass
          'true'
        when FalseClass
          'false'
        when Integer
          value.to_s
        when Float
          dump_float(value)
        when String
          dump_string(value, ascii)
        when Array
          dump_array(value, indent, depth, sort_keys, ascii)
        when Hash
          dump_object(value, indent, depth, sort_keys, ascii)
        else
          raise TypeError, "unsupported value type: #{value.class}"
        end
      end
      private_class_method :write

      def dump_float(value)
        return 'null' if value.nan?
        return Float::MAX.to_s if value.infinite? == 1
        return "-#{Float::MAX}" if value.infinite? == -1
        return '-0' if value.zero? && (1.0 / value).infinite? == -1
        return value.to_i.to_s if value == value.to_i

        text = value.to_s
        text.include?('.') || text.match?(/[eE]/) ? text : "#{text}.0"
      end
      private_class_method :dump_float

      def dump_string(value, ascii)
        escaped = value.each_codepoint.map { |codepoint| escape_codepoint(codepoint, ascii) }.join
        "\"#{escaped}\""
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
          if ascii && codepoint > 0x7F
            unicode_escape(codepoint)
          else
            [codepoint].pack('U')
          end
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

      def dump_array(value, indent, depth, sort_keys, ascii)
        return '[]' if value.empty?

        parts = value.map { |item| write(item, indent, depth + 1, sort_keys, ascii) }
        return "[#{parts.join(',')}]" if indent.nil?

        child_pad = indent * (depth + 1)
        pad = indent * depth
        "[\n#{child_pad}#{parts.join(",\n#{child_pad}")}\n#{pad}]"
      end
      private_class_method :dump_array

      def dump_object(value, indent, depth, sort_keys, ascii)
        return '{}' if value.empty?

        keys = sort_keys ? value.keys.sort : value.keys
        parts = keys.map do |key|
          dumped_key = dump_string(key.to_s, ascii)
          dumped_value = write(value[key], indent, depth + 1, sort_keys, ascii)
          indent.nil? ? "#{dumped_key}:#{dumped_value}" : "#{dumped_key}: #{dumped_value}"
        end
        return "{#{parts.join(',')}}" if indent.nil?

        child_pad = indent * (depth + 1)
        pad = indent * depth
        "{\n#{child_pad}#{parts.join(",\n#{child_pad}")}\n#{pad}}"
      end
      private_class_method :dump_object
    end
  end
end
