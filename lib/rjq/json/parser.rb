# frozen_string_literal: true

module Rjq
  module JSON
    class Parser
      ParsedValue = Struct.new(:value, :line, keyword_init: true)
      DEFAULT_MAX_DEPTH = 256

      class << self
        def parse(io_or_string, seq: false, chunk_size: InputBuffer::DEFAULT_CHUNK_SIZE, on_error: nil,
                  max_depth: DEFAULT_MAX_DEPTH, max_number_digits: nil, max_string_bytes: nil)
          new(io_or_string, seq: seq, chunk_size: chunk_size, on_error: on_error,
                            max_depth: max_depth, max_number_digits: max_number_digits,
                            max_string_bytes: max_string_bytes).parse_stream
        end

        def parse_one(io_or_string, seq: false, chunk_size: InputBuffer::DEFAULT_CHUNK_SIZE,
                      max_depth: DEFAULT_MAX_DEPTH, max_number_digits: nil, max_string_bytes: nil)
          values = parse(io_or_string, seq: seq, chunk_size: chunk_size, max_depth: max_depth,
                                       max_number_digits: max_number_digits, max_string_bytes: max_string_bytes).take(2)
          raise JSONParseError, "expected one JSON value, got #{values.length}" unless values.length == 1

          values.first
        end

        def parse_records(io_or_string, seq: false, chunk_size: InputBuffer::DEFAULT_CHUNK_SIZE, on_error: nil,
                          max_depth: DEFAULT_MAX_DEPTH, max_number_digits: nil, max_string_bytes: nil)
          new(io_or_string, seq: seq, chunk_size: chunk_size, on_error: on_error,
                            max_depth: max_depth, max_number_digits: max_number_digits,
                            max_string_bytes: max_string_bytes).parse_stream(locations: true)
        end
      end

      def initialize(input, seq: false, chunk_size: InputBuffer::DEFAULT_CHUNK_SIZE, on_error: nil,
                     max_depth: DEFAULT_MAX_DEPTH, max_number_digits: nil, max_string_bytes: nil)
        validate_options!(chunk_size, max_depth, max_number_digits, max_string_bytes)
        @input = InputBuffer.new(input, chunk_size: chunk_size)
        @seq = seq
        @on_error = on_error
        @max_depth = max_depth
        @max_number_digits = max_number_digits
        @max_string_bytes = max_string_bytes
        @depth = 0
        @index = 0
        @line = 1
        @column = 1
        advance if current == "\uFEFF"
      end

      def parse_stream(locations: false)
        Enumerator.new do |yielder|
          loop do
            skip_separators
            break if eof?

            begin
              line = @line
              value = parse_value
              yielder << (locations ? ParsedValue.new(value: value, line: line) : value)
              @input.discard_before(@index)
              skip_whitespace
              raise_error('expected record separator') if @seq && !(eof? || current == "\x1e")
            rescue JSONParseError => e
              raise unless @seq && @on_error

              @on_error.call(e.message)
              resync_to_record_separator
            end
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
        with_container_depth { parse_object_body }
      end

      def parse_object_body
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
        with_container_depth { parse_array_body }
      end

      def parse_array_body
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
        bytes = 0
        until eof?
          line = @line
          column = @column
          char = advance
          return out.force_encoding(Encoding::UTF_8) if char == '"'

          piece = if char == '\\'
                    parse_escape
                  else
            raise_error('unescaped control character in string') if char.ord < 0x20

                    char
                  end
          bytes += piece.bytesize
          raise_error_at("string exceeds #{@max_string_bytes} byte limit", line, column) if @max_string_bytes &&
            bytes > @max_string_bytes

          out << piece
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

          2.times { advance }
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
        digits = 0
        consume?('-')
        if current == '0'
          digits = consume_number_digit(digits)
          raise_error('leading zero in number') if digit?(current)
        else
          raise_error('expected number') unless digit_1_9?(current)
          digits = consume_number_digit(digits) while digit?(current)
        end

        if consume?('.')
          raise_error('expected digit after decimal point') unless digit?(current)
          digits = consume_number_digit(digits) while digit?(current)
        end

        if %w[e E].include?(current)
          advance
          advance if ['+', '-'].include?(current)
          raise_error('expected digit in exponent') unless digit?(current)
          digits = consume_number_digit(digits) while digit?(current)
        end

        literal = @input[start...@index]
        raise_error('invalid number') unless number_delimiter?(current)

        Number.parse(literal)
      rescue ArgumentError
        raise_error('invalid number')
      end

      def number_delimiter?(char)
        char.nil? || char.match?(/[\s,\]}\x1e]/)
      end

      def parse_special_number(positive:)
        if @input[@index, 8] == 'Infinity'
          8.times { advance }
          raise_error('invalid number') if atom_char?(current)

          return positive ? Float::INFINITY : -Float::INFINITY
        end

        raise_error('expected number') unless @input[@index, 3].to_s.casecmp('nan').zero?

        3.times { advance }
        digits = 0
        digits = consume_number_digit(digits) while digit?(current)
        raise_error('invalid number') if atom_char?(current)

        Float::NAN
      end

      def consume_literal(literal, value)
        raise_error("expected #{literal}") unless @input[@index, literal.length] == literal

        literal.length.times { advance }
        raise_error("invalid literal #{literal}") if atom_char?(current)

        value
      end

      def atom_char?(char)
        char&.match?(/[0-9A-Za-z_]/)
      end

      def read_hex4
        chars = @input[@index, 4]
        raise_error('invalid unicode escape') unless chars&.match?(/\A[0-9a-fA-F]{4}\z/)

        4.times { advance }
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

      def resync_to_record_separator
        advance until eof? || current == "\x1e"
        @input.discard_before(@index)
      end

      def with_container_depth
        @depth += 1
        raise_error('exceeds depth limit for parsing') if @depth > @max_depth

        yield
      ensure
        @depth -= 1
      end

      def consume_number_digit(count)
        count += 1
        if @max_number_digits && count > @max_number_digits
          raise_error("number exceeds #{@max_number_digits} digit limit")
        end

        advance
        count
      end

      def validate_options!(chunk_size, max_depth, max_number_digits, max_string_bytes)
        validate_nonnegative_integer!(:max_depth, max_depth)
        validate_nonnegative_integer!(:max_number_digits, max_number_digits, optional: true)
        validate_nonnegative_integer!(:max_string_bytes, max_string_bytes, optional: true)
        return if chunk_size.is_a?(Integer) && chunk_size.positive?

        raise ArgumentError, 'chunk_size must be a positive Integer'
      end

      def validate_nonnegative_integer!(name, value, optional: false)
        return if optional && value.nil?
        return if value.is_a?(Integer) && value >= 0

        raise ArgumentError, "#{name} must be a non-negative Integer#{' or nil' if optional}"
      end

      def skip_whitespace
        advance while current&.match?(/[ \t\r\n]/)
      end

      def expect(char)
        raise_error("expected #{char}") unless consume?(char)
      end

      def consume?(char)
        return false unless current == char

        advance
        true
      end

      def advance
        char = current
        @index += char.length
        if char == "\n"
          @line += 1
          @column = 1
        else
          @column += 1
        end
        char
      end

      def current
        @input[@index]
      end

      def eof?
        current.nil?
      end

      def digit?(char)
        !char.nil? && char >= '0' && char <= '9'
      end

      def digit_1_9?(char)
        !char.nil? && char >= '1' && char <= '9'
      end

      def raise_error(message)
        raise JSONParseError, "#{message} at line #{@line}, column #{@column}"
      end

      def raise_error_at(message, line, column)
        raise JSONParseError, "#{message} at line #{line}, column #{column}"
      end
    end
  end
end
