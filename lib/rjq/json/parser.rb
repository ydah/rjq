# frozen_string_literal: true

module Rjq
  module JSON
    class Parser
      class << self
        def parse(io_or_string, seq: false)
          input = io_or_string.respond_to?(:read) ? io_or_string.read : io_or_string.to_s
          new(input, seq: seq).parse_stream
        end

        def parse_one(io_or_string, seq: false)
          values = parse(io_or_string, seq: seq).to_a
          raise JSONParseError, "expected one JSON value, got #{values.length}" unless values.length == 1

          values.first
        end
      end

      def initialize(input, seq: false)
        @input = input.to_s.encode(Encoding::UTF_8)
        raise JSONParseError, 'invalid UTF-8 input' unless @input.valid_encoding?

        @input = @input.delete_prefix("\uFEFF")
        @seq = seq
        @index = 0
      rescue EncodingError => e
        raise JSONParseError, e.message
      end

      def parse_stream
        Enumerator.new do |yielder|
          loop do
            skip_separators
            break if eof?

            yielder << parse_value
            skip_whitespace
            raise_error('expected record separator') if @seq && !(eof? || current == "\x1e")
          end
        end
      end

      private

      def parse_value
        skip_whitespace
        raise_error('unexpected end of input') if eof?

        case current
        when '{'
          parse_object
        when '['
          parse_array
        when '"'
          parse_string
        when 't'
          consume_literal('true', true)
        when 'f'
          consume_literal('false', false)
        when 'n'
          if @input[@index,
                    3].to_s.casecmp('nan').zero?
            parse_special_number(positive: true)
          else
            consume_literal('null', nil)
          end
        when 'I', 'N'
          parse_special_number(positive: true)
        when '-'
          if %w[I N].include?(@input[@index + 1, 1])
            advance
            parse_special_number(positive: false)
          else
            parse_number
          end
        else
          parse_number
        end
      end

      def parse_object
        advance
        object = {}
        skip_whitespace
        return object if consume?('}')

        loop do
          skip_whitespace
          raise_error('expected object key string') unless current == '"'

          key = parse_string
          skip_whitespace
          expect(':')
          object[key] = parse_value
          skip_whitespace
          return object if consume?('}')

          expect(',')
        end
      end

      def parse_array
        advance
        array = []
        skip_whitespace
        return array if consume?(']')

        loop do
          array << parse_value
          skip_whitespace
          return array if consume?(']')

          expect(',')
        end
      end

      def parse_string
        expect('"')
        out = +''
        until eof?
          char = advance
          return out.force_encoding(Encoding::UTF_8) if char == '"'

          if char == '\\'
            out << parse_escape
          else
            raise_error('unescaped control character in string') if char.ord < 0x20

            out << char
          end
        end
        raise_error('unterminated string')
      end

      def parse_escape
        raise_error('unterminated escape') if eof?

        char = advance
        case char
        when '"', '\\', '/'
          char
        when 'b'
          "\b"
        when 'f'
          "\f"
        when 'n'
          "\n"
        when 'r'
          "\r"
        when 't'
          "\t"
        when 'u'
          parse_unicode_escape
        else
          raise_error("invalid escape: \\#{char}")
        end
      end

      def parse_unicode_escape
        codepoint = read_hex4
        if high_surrogate?(codepoint)
          raise_error('missing low surrogate') unless @input[@index, 2] == '\\u'

          @index += 2
          low = read_hex4
          raise_error('invalid low surrogate') unless low_surrogate?(low)

          codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00)
        elsif low_surrogate?(codepoint)
          raise_error('unexpected low surrogate')
        end
        [codepoint].pack('U')
      end

      def parse_number
        start = @index
        consume?('-')
        if consume?('0')
          raise_error('leading zero in number') if digit?(current)
        else
          raise_error('expected number') unless digit_1_9?(current)
          advance while digit?(current)
        end

        float = false
        if consume?('.')
          float = true
          raise_error('expected digit after decimal point') unless digit?(current)
          advance while digit?(current)
        end

        if %w[e E].include?(current)
          float = true
          advance
          advance if ['+', '-'].include?(current)
          raise_error('expected digit in exponent') unless digit?(current)
          advance while digit?(current)
        end

        literal = @input[start...@index]
        return Float(literal) if literal.start_with?('-') && Float(literal).zero?

        float ? Float(literal) : Integer(literal, 10)
      rescue ArgumentError
        raise_error('invalid number')
      end

      def parse_special_number(positive:)
        if @input[@index, 8] == 'Infinity'
          @index += 8
          raise_error('invalid number') if atom_char?(current)

          return positive ? Float::INFINITY : -Float::INFINITY
        end

        raise_error('expected number') unless @input[@index, 3].to_s.casecmp('nan').zero?

        @index += 3
        advance while digit?(current)
        raise_error('invalid number') if atom_char?(current)

        Float::NAN
      end

      def consume_literal(literal, value)
        raise_error("expected #{literal}") unless @input[@index, literal.length] == literal

        @index += literal.length
        raise_error("invalid literal #{literal}") if atom_char?(current)

        value
      end

      def atom_char?(char)
        char&.match?(/[0-9A-Za-z_]/)
      end

      def read_hex4
        chars = @input[@index, 4]
        raise_error('invalid unicode escape') unless chars&.match?(/\A[0-9a-fA-F]{4}\z/)

        @index += 4
        chars.to_i(16)
      end

      def high_surrogate?(codepoint)
        codepoint.between?(0xD800, 0xDBFF)
      end

      def low_surrogate?(codepoint)
        codepoint.between?(0xDC00, 0xDFFF)
      end

      def skip_separators
        loop do
          skip_whitespace
          break unless @seq && current == "\x1e"

          advance
        end
      end

      def skip_whitespace
        advance while current&.match?(/[ \t\r\n]/)
      end

      def expect(char)
        raise_error("expected #{char}") unless consume?(char)
      end

      def consume?(char)
        return false unless current == char

        @index += char.length
        true
      end

      def advance
        char = current
        @index += char.length
        char
      end

      def current
        @input[@index]
      end

      def eof?
        @index >= @input.length
      end

      def digit?(char)
        !char.nil? && char >= '0' && char <= '9'
      end

      def digit_1_9?(char)
        !char.nil? && char >= '1' && char <= '9'
      end

      def raise_error(message)
        line = @input[0...@index].count("\n") + 1
        line_start = @input.rindex("\n", @index - 1) || -1
        column = @index - line_start
        raise JSONParseError, "#{message} at line #{line}, column #{column}"
      end
    end
  end
end
