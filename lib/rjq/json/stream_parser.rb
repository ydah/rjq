# frozen_string_literal: true

module Rjq
  module JSON
    class StreamParser
      Result = Struct.new(:events, :close_path, keyword_init: true)
      class StreamError < StandardError
        attr_reader :path

        def initialize(message:, path:)
          @path = path
          super(message)
        end
      end

      class << self
        def parse(io_or_string, seq: false, stream_errors: false)
          input = io_or_string.respond_to?(:read) ? io_or_string.read : io_or_string.to_s
          new(input, seq: seq, stream_errors: stream_errors).parse
        end
      end

      def initialize(input, seq: false, stream_errors: false)
        @input = input.to_s.encode(Encoding::UTF_8)
        raise JSONParseError, 'invalid UTF-8 input' unless @input.valid_encoding?

        @input = @input.delete_prefix("\uFEFF")
        @seq = seq
        @stream_errors = stream_errors
        @index = 0
        @events = []
      rescue EncodingError => e
        raise JSONParseError, e.message
      end

      def parse
        parse_values
      rescue StreamError => e
        raise JSONParseError, e.message unless @stream_errors

        @events + [[e.message, e.path]]
      end

      private

      def parse_values
        until eof?
          skip_separators
          break if eof?

          result = parse_value([])
          skip_whitespace
          commit(result)
          raise_error('expected record separator', []) if @seq && !eof? && current != "\x1e"
        end
        @events
      end

      def parse_value(path)
        skip_whitespace
        raise_error('Unfinished JSON term at EOF', path) if eof?

        case current
        when '{'
          parse_object(path)
        when '['
          parse_array(path)
        when '"'
          Result.new(events: [[path, parse_string]], close_path: path)
        when 't'
          consume_literal('true', path)
          Result.new(events: [[path, true]], close_path: path)
        when 'f'
          consume_literal('false', path)
          Result.new(events: [[path, false]], close_path: path)
        when 'n'
          consume_literal('null', path)
          Result.new(events: [[path, nil]], close_path: path)
        else
          Result.new(events: [[path, parse_number(path)]], close_path: path)
        end
      end

      def parse_object(path)
        advance
        skip_whitespace
        if consume?('}')
          @events << [path, {}]
          return Result.new(events: [], close_path: path)
        end

        last_path = path
        loop do
          skip_whitespace
          raise_error('Unfinished JSON term at EOF', path + [nil]) if eof?
          raise_error('Expected another key:value pair', path + [nil]) if current == '}'
          raise_error('Expected another key:value pair', path + [nil]) unless current == '"'

          key = parse_string
          skip_whitespace
          unless consume?(':')
            raise_error('Unfinished JSON term at EOF', path + [nil]) if eof?

            scan_unexpected_value
            raise_error('Expected separator between values', path + [nil])
          end
          skip_whitespace
          raise_error('Missing value in key:value pair', path + [key]) if ['}', ']'].include?(current)

          result = parse_value(path + [key])
          skip_whitespace

          if consume?(',')
            commit(result)
            last_path = result.close_path
            next
          end

          if consume?('}')
            commit(result)
            last_path = result.close_path
            @events << [last_path]
            return Result.new(events: [], close_path: path)
          end

          raise_error('Unfinished JSON term at EOF', result.close_path) if eof?

          scan_unexpected_value
          raise_error('Expected separator between values', result.close_path)
        end
      end

      def parse_array(path)
        advance
        skip_whitespace
        if consume?(']')
          @events << [path, []]
          return Result.new(events: [], close_path: path)
        end

        index = 0
        last_path = path
        loop do
          skip_whitespace
          raise_error('Expected another array element', path + [index]) if current == ']'

          result = parse_value(path + [index])
          skip_whitespace

          if consume?(',')
            commit(result)
            last_path = result.close_path
            index += 1
            next
          end

          if consume?(']')
            commit(result)
            last_path = result.close_path
            @events << [last_path]
            return Result.new(events: [], close_path: path)
          end

          raise_error('Unfinished JSON term at EOF', result.close_path) if eof?

          scan_unexpected_value
          raise_error('Expected separator between values', result.close_path)
        end
      end

      def commit(result)
        result.events.each { |event| @events << event }
      end

      def parse_string
        expect('"', [])
        out = +''
        until eof?
          char = advance
          return out.force_encoding(Encoding::UTF_8) if char == '"'

          if char == '\\'
            out << parse_escape
          else
            raise_error('unescaped control character in string', []) if char.ord < 0x20

            out << char
          end
        end
        raise_error('Unfinished JSON term at EOF', [])
      end

      def parse_escape
        raise_error('Unfinished JSON term at EOF', []) if eof?

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
          raise_error("invalid escape: \\#{char}", [])
        end
      end

      def parse_unicode_escape
        codepoint = read_hex4
        if high_surrogate?(codepoint)
          raise_error('missing low surrogate', []) unless @input[@index, 2] == '\\u'

          @index += 2
          low = read_hex4
          raise_error('invalid low surrogate', []) unless low_surrogate?(low)

          codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00)
        elsif low_surrogate?(codepoint)
          raise_error('unexpected low surrogate', [])
        end
        [codepoint].pack('U')
      end

      def parse_number(path)
        start = @index
        consume?('-')
        if consume?('0')
          invalid_numeric_literal(path) if digit?(current)
        else
          invalid_numeric_literal(path) unless digit_1_9?(current)
          advance while digit?(current)
        end

        float = false
        if consume?('.')
          float = true
          invalid_numeric_literal(path) unless digit?(current)
          advance while digit?(current)
        end

        if %w[e E].include?(current)
          float = true
          advance
          advance if ['+', '-'].include?(current)
          invalid_numeric_literal(path) unless digit?(current)
          advance while digit?(current)
        end

        literal = @input[start...@index]
        return Float(literal) if literal.start_with?('-') && Float(literal).zero?

        float ? Float(literal) : Integer(literal, 10)
      rescue ArgumentError
        invalid_numeric_literal(path)
      end

      def consume_literal(literal, path)
        unless @input[@index, literal.length] == literal
          scan_invalid_token
          raise_error(eof? ? 'Invalid literal at EOF' : 'Invalid literal', path)
        end

        @index += literal.length
        if atom_char?(current)
          scan_invalid_token
          raise_error(eof? ? 'Invalid literal at EOF' : 'Invalid literal', path)
        end
      end

      def atom_char?(char)
        char&.match?(/[0-9A-Za-z_]/)
      end

      def read_hex4
        chars = @input[@index, 4]
        raise_error('invalid unicode escape', []) unless chars&.match?(/\A[0-9a-fA-F]{4}\z/)

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

      def scan_unexpected_value
        skip_whitespace
        return if eof? || current == ',' || current == ']' || current == '}'

        if current == '"'
          begin
            parse_string
            @index -= 1 unless @index.zero?
          rescue StreamError
            nil
          end
        else
          scan_invalid_token
        end
        skip_whitespace
      end

      def scan_invalid_token
        advance while current && !current.match?(/[,\]\s}]/)
      end

      def invalid_numeric_literal(path)
        scan_invalid_token
        raise_error(eof? ? 'Invalid numeric literal at EOF' : 'Invalid numeric literal', path)
      end

      def expect(char, path)
        raise_error("expected #{char}", path) unless consume?(char)
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

      def raise_error(message, path)
        raise StreamError.new(message: "#{message} at line #{line_number}, column #{column_number}", path: path)
      end

      def line_number
        @input[0...@index].count("\n") + 1
      end

      def column_number
        line_start = @input.rindex("\n", @index - 1) || -1
        column = @index - line_start
        eof? ? [column - 1, 1].max : column
      end
    end
  end
end
