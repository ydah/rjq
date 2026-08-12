# frozen_string_literal: true

module Rjq
  Token = Struct.new(:type, :value, :line, :column, :start_offset, :end_offset, :filename, keyword_init: true)

  class Lexer
    KEYWORDS = %w[
      if then elif else end as def reduce foreach try catch label import include module
      null true false and or not break
    ].freeze

    TWO_CHAR_OPERATORS = ['//', '==', '!=', '<=', '>=', '|=', '+=', '-=', '*=', '/=', '%=', '..'].freeze
    THREE_CHAR_OPERATORS = ['//='].freeze
    SINGLE_CHAR_TOKENS = {
      '.' => :dot,
      '|' => :pipe,
      ',' => :comma,
      '(' => :lparen,
      ')' => :rparen,
      '[' => :lbracket,
      ']' => :rbracket,
      '{' => :lbrace,
      '}' => :rbrace,
      ':' => :colon,
      ';' => :semicolon,
      '?' => :question,
      '+' => :operator,
      '-' => :operator,
      '*' => :operator,
      '/' => :operator,
      '%' => :operator,
      '=' => :operator,
      '<' => :operator,
      '>' => :operator
    }.freeze

    attr_reader :tokens

    def initialize(source, allow_comments: true, source_name: '<top-level>')
      @source = source.to_s
      @allow_comments = allow_comments
      @source_name = source_name
      @index = 0
      @line = 1
      @column = 1
      @tokens = []
    end

    def tokenize
      until eof?
        skip_space
        break if eof?

        start_line = @line
        start_column = @column
        start_offset = @index
        char = current
        token =
          if char == '#'
            unless @allow_comments
              raise ParseError,
                    "comments are disabled at line #{start_line}, column #{start_column}"
            end

            skip_comment
            next
          elsif char == '"'
            Token.new(type: :string, value: read_string, line: start_line, column: start_column)
          elsif char == '$'
            advance
            Token.new(type: :variable, value: read_identifier, line: start_line, column: start_column)
          elsif char == '@'
            advance
            Token.new(type: :format, value: read_identifier, line: start_line, column: start_column)
          elsif number_start?(char)
            Token.new(type: :number, value: read_number, line: start_line, column: start_column)
          elsif identifier_start?(char)
            identifier = read_identifier
            type = KEYWORDS.include?(identifier) ? :keyword : :identifier
            Token.new(type: type, value: identifier, line: start_line, column: start_column)
          else
            read_operator_or_punctuation(start_line, start_column)
          end
        if token
          token.start_offset = start_offset
          token.end_offset = @index
          token.filename = @source_name
          @tokens << token
        end
      end
      @tokens << Token.new(type: :eof, value: nil, line: @line, column: @column, start_offset: @index,
                           end_offset: @index, filename: @source_name)
      @tokens
    end

    private

    def read_operator_or_punctuation(line, column)
      three = @source[@index, 3]
      if THREE_CHAR_OPERATORS.include?(three)
        3.times { advance }
        return Token.new(type: :operator, value: three, line: line, column: column)
      end

      two = @source[@index, 2]
      if TWO_CHAR_OPERATORS.include?(two)
        2.times { advance }
        return Token.new(type: :operator, value: two, line: line, column: column)
      end

      type = SINGLE_CHAR_TOKENS[current]
      raise ParseError, "unexpected character #{current.inspect} at line #{line}, column #{column}" unless type

      value = current
      advance
      Token.new(type: type, value: value, line: line, column: column)
    end

    def read_string
      expect('"')
      segments = []
      buffer = +''
      until eof?
        char = advance
        if char == '"'
          return segments.empty? ? buffer : segments_with_buffer(segments, buffer)
        end

        if char == '\\'
          if current == '('
            advance
            segments << [:text, buffer] unless buffer.empty?
            buffer = +''
            segments << [:expr, read_interpolation]
          else
            buffer << read_escape
          end
        else
          raise parse_error('unescaped control character in string') if char.ord < 0x20

          buffer << char
        end
      end
      raise parse_error('unterminated string')
    end

    def segments_with_buffer(segments, buffer)
      segments << [:text, buffer] unless buffer.empty?
      segments
    end

    def read_interpolation
      depth = 1
      quote = nil
      escape = false
      start = @index

      until eof?
        char = advance
        if quote
          if escape
            escape = false
          elsif char == '\\'
            escape = true
          elsif char == quote
            quote = nil
          end
          next
        end

        case char
        when '"', "'"
          quote = char
        when '('
          depth += 1
        when ')'
          depth -= 1
          return @source[start...(@index - 1)] if depth.zero?
        end
      end

      raise parse_error('unterminated interpolation')
    end

    def read_escape
      raise parse_error('unterminated escape') if eof?

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
        read_unicode_escape
      else
        raise parse_error("invalid escape \\#{char}")
      end
    end

    def read_unicode_escape
      codepoint = read_hex4
      if codepoint.between?(0xD800, 0xDBFF)
        raise parse_error('missing low surrogate') unless @source[@index, 2] == '\\u'

        2.times { advance }
        low = read_hex4
        raise parse_error('invalid low surrogate') unless low.between?(0xDC00, 0xDFFF)

        codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00)
      elsif codepoint.between?(0xDC00, 0xDFFF)
        raise parse_error('unexpected low surrogate')
      end
      [codepoint].pack('U')
    end

    def read_hex4
      text = @source[@index, 4]
      raise parse_error('invalid unicode escape') unless text&.match?(/\A[0-9a-fA-F]{4}\z/)

      4.times { advance }
      text.to_i(16)
    end

    def read_number
      start = @index
      advance while digit?(current)
      if current == '.'
        advance
        advance while digit?(current)
      end
      if %w[e E].include?(current)
        advance
        advance if ['+', '-'].include?(current)
        advance while digit?(current)
      end
      text = @source[start...@index]
      Number.parse(text)
    rescue ArgumentError
      raise parse_error('invalid number')
    end

    def read_identifier
      start = @index
      raise parse_error('expected identifier') unless identifier_start?(current)

      advance while identifier_part?(current)
      @source[start...@index]
    end

    def skip_space
      loop do
        advance while current&.match?(/[ \t\r\n]/)
        break unless @allow_comments && current == '#'

        skip_comment
      end
    end

    def skip_comment
      advance until eof? || current == "\n"
    end

    def number_start?(char)
      digit?(char)
    end

    def identifier_start?(char)
      !char.nil? && char.match?(/[A-Za-z_]/)
    end

    def identifier_part?(char)
      !char.nil? && char.match?(/[A-Za-z0-9_]/)
    end

    def digit?(char)
      !char.nil? && char >= '0' && char <= '9'
    end

    def expect(char)
      raise parse_error("expected #{char}") unless current == char

      advance
    end

    def current
      @source[@index]
    end

    def eof?
      @index >= @source.length
    end

    def advance
      char = @source[@index]
      @index += char.length
      if char == "\n"
        @line += 1
        @column = 1
      else
        @column += 1
      end
      char
    end

    def parse_error(message)
      ParseError.new("#{message} at #{@source_name}, line #{@line}, column #{@column}")
    end
  end
end
