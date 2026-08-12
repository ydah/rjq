# frozen_string_literal: true

module Rjq
  module JSON
    class StreamParser
      DEFAULT_MAX_DEPTH = 256
      Result = Struct.new(:events, :close_path, keyword_init: true)
      ParsedEvent = Struct.new(:value, :line, keyword_init: true)
      class StreamError < StandardError
        attr_reader :path

        def initialize(message:, path:)
          @path = path
          super(message)
        end
      end

      class << self
        def parse(io_or_string, seq: false, stream_errors: false, chunk_size: InputBuffer::DEFAULT_CHUNK_SIZE,
                  on_error: nil, max_depth: DEFAULT_MAX_DEPTH, max_number_digits: nil, max_string_bytes: nil,
                  locations: false)
          new(io_or_string, seq: seq, stream_errors: stream_errors, chunk_size: chunk_size,
                            on_error: on_error, max_depth: max_depth, max_number_digits: max_number_digits,
                            max_string_bytes: max_string_bytes, locations: locations).parse
        end
      end

      def initialize(input, seq: false, stream_errors: false, chunk_size: InputBuffer::DEFAULT_CHUNK_SIZE,
                     on_error: nil, max_depth: DEFAULT_MAX_DEPTH, max_number_digits: nil, max_string_bytes: nil,
                     locations: false)
        validate_options!(chunk_size, max_depth, max_number_digits, max_string_bytes)
        @input = InputBuffer.new(input, chunk_size: chunk_size)
        @seq = seq
        @stream_errors = stream_errors
        @on_error = on_error
        @max_depth = max_depth
        @max_number_digits = max_number_digits
        @max_string_bytes = max_string_bytes
        @locations = locations
        @depth = 0
        @index = 0
        @line = 1
        @column = 1
        advance if current == "\uFEFF"
      end

      def parse
        Enumerator.new do |yielder|
          @events = yielder
          parse_values
        end
      end

      private

      def parse_values
        until eof?
          skip_separators
          break if eof?

          begin
            value_line = @line
            value_column = @column
            result = parse_value([])
            skip_whitespace
            commit(result)
            @unmatched_error_location = [value_line, value_column] if @unmatched_error_location
            raise_error('expected record separator', []) if @seq && !eof? && current != "\x1e"
            @input.discard_before(@index)
          rescue StreamError => e
            if @stream_errors
              emit([e.message, e.path])
            elsif @seq && @on_error
              @on_error.call(e.message)
            else
              raise JSONParseError, e.message
            end
            @unmatched_error_location = [@last_error_line, @last_error_column + 1]
            if @seq
              resync_to_record_separator
            elsif @stream_errors
              resync_to_next_line
            else
              break
            end
          end
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
          Result.new(events: [pending_event(path, parse_string(path))], close_path: path)
        when 't'
          consume_literal('true', path)
          Result.new(events: [pending_event(path, true)], close_path: path)
        when 'f'
          consume_literal('false', path)
          Result.new(events: [pending_event(path, false)], close_path: path)
        when 'n'
          consume_literal('null', path)
          Result.new(events: [pending_event(path, nil)], close_path: path)
        when ']', '}'
          delimiter = current
          if @unmatched_error_location
            line, column = @unmatched_error_location
            @unmatched_error_location = nil
            raise_error_at("Unmatched '#{delimiter}' at the top-level", path, line, column)
          end
          raise_error("Unmatched '#{delimiter}' at the top-level", path)
        else
          Result.new(events: [pending_event(path, parse_number(path))], close_path: path)
        end
      end

      def parse_object(path)
        with_container_depth(path) { parse_object_body(path) }
      end

      def parse_object_body(path)
        advance
        skip_whitespace
        if consume?('}')
          emit([path, {}])
          return Result.new(events: [], close_path: path)
        end

        last_path = path
        loop do
          skip_whitespace
          raise_error('Unfinished JSON term at EOF', path + [nil]) if eof?
          raise_error('Expected another key:value pair', path + [nil]) if current == '}'
          unless current == '"'
            advance while current&.match?(/[0-9A-Za-z_+-]/)
            raise_error('Invalid numeric literal', path + [nil])
          end

          key = parse_string(path + [nil])
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
            emit([last_path])
            return Result.new(events: [], close_path: path)
          end

          raise_error('Unfinished JSON term at EOF', result.close_path) if eof?

          scan_unexpected_value
          raise_error('Expected separator between values', result.close_path)
        end
      end

      def parse_array(path)
        with_container_depth(path) { parse_array_body(path) }
      end

      def parse_array_body(path)
        advance
        skip_whitespace
        if consume?(']')
          emit([path, []])
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
            emit([last_path])
            return Result.new(events: [], close_path: path)
          end

          raise_error('Unfinished JSON term at EOF', result.close_path) if eof?

          scan_unexpected_value
          raise_error('Expected separator between values', result.close_path)
        end
      end

      def commit(result)
        result.events.each { |event| emit(event) }
      end

      def emit(event)
        parsed = event.is_a?(ParsedEvent) ? event : located_event(event)
        @events << (@locations ? parsed : parsed.value)
      end

      def located_event(value)
        ParsedEvent.new(value: value, line: @line)
      end

      def pending_event(path, value)
        event = [path, value]
        path.empty? ? located_event(event) : event
      end

      def parse_string(path = [])
        expect('"', [])
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
                    raise_error('unescaped control character in string', path) if char.ord < 0x20

                    char
                  end
          bytes += piece.bytesize
          if @max_string_bytes && bytes > @max_string_bytes
            raise_error_at("string exceeds #{@max_string_bytes} byte limit", path, line, column)
          end

          out << piece
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

          2.times { advance }
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
        digits = 0
        consume?('-')
        if current == '0'
          digits = consume_number_digit(digits, path)
          invalid_numeric_literal(path) if digit?(current)
        else
          invalid_numeric_literal(path) unless digit_1_9?(current)
          digits = consume_number_digit(digits, path) while digit?(current)
        end

        if consume?('.')
          invalid_numeric_literal(path) unless digit?(current)
          digits = consume_number_digit(digits, path) while digit?(current)
        end

        if %w[e E].include?(current)
          advance
          advance if ['+', '-'].include?(current)
          invalid_numeric_literal(path) unless digit?(current)
          digits = consume_number_digit(digits, path) while digit?(current)
        end

        literal = @input[start...@index]
        invalid_numeric_literal(path) unless number_delimiter?(current)

        Number.parse(literal)
      rescue ArgumentError
        invalid_numeric_literal(path)
      end

      def number_delimiter?(char)
        char.nil? || char.match?(/[\s,\]}\x1e]/)
      end

      def consume_literal(literal, path)
        unless @input[@index, literal.length] == literal
          scan_invalid_token
          raise_error(eof? ? 'Invalid literal at EOF' : 'Invalid literal', path)
        end

        literal.length.times { advance }
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

      def resync_to_next_line
        advance until eof? || current == "\n"
        advance if current == "\n"
        @input.discard_before(@index)
      end

      def with_container_depth(path)
        @depth += 1
        raise_error('Exceeds depth limit for parsing', path) if @depth > @max_depth

        yield
      ensure
        @depth -= 1
      end

      def consume_number_digit(count, path)
        count += 1
        if @max_number_digits && count > @max_number_digits
          raise_error("Number exceeds #{@max_number_digits} digit limit", path)
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

      def scan_unexpected_value
        skip_whitespace
        return if eof? || current == ',' || current == ']' || current == '}'

        if current == '"'
          begin
            parse_string
            rewind_one unless @index.zero?
          rescue StreamError
            nil
          end
        else
          scan_invalid_token
        end
        skip_whitespace
      end

      def scan_invalid_token
        advance while current && !current.match?(/[,\]\s}\x1e]/)
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

      def rewind_one
        @index -= 1
        @column -= 1
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

      def raise_error(message, path)
        @last_error_line = line_number
        @last_error_column = column_number
        raise StreamError.new(message: "#{message} at line #{line_number}, column #{column_number}", path: path)
      end

      def raise_error_at(message, path, line, column)
        @last_error_line = line
        @last_error_column = column
        raise StreamError.new(message: "#{message} at line #{line}, column #{column}", path: path)
      end

      def line_number
        @line
      end

      def column_number
        eof? ? [@column - 1, 1].max : @column
      end
    end
  end
end
