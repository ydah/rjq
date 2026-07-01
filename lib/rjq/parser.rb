# frozen_string_literal: true

module Rjq
  class Parser
    ASSIGNMENT_OPERATORS = ['=', '|=', '+=', '-=', '*=', '/=', '%=', '//='].freeze
    COMPARISON_OPERATORS = %w[== != < <= > >=].freeze
    ADDITIVE_OPERATORS = %w[+ -].freeze
    MULTIPLICATIVE_OPERATORS = %w[* / %].freeze
    PRECEDENCE = {
      '|' => 1,
      'as' => 2,
      ',' => 3,
      '=' => 4,
      '|=' => 4,
      '+=' => 4,
      '-=' => 4,
      '*=' => 4,
      '/=' => 4,
      '%=' => 4,
      '//=' => 4,
      'or' => 5,
      'and' => 6,
      '//' => 7,
      '==' => 8,
      '!=' => 8,
      '<' => 8,
      '<=' => 8,
      '>' => 8,
      '>=' => 8,
      '+' => 9,
      '-' => 9,
      '*' => 10,
      '/' => 10,
      '%' => 10
    }.freeze

    def initialize(source, allow_comments: false)
      @tokens = source.is_a?(Array) ? source : Lexer.new(source, allow_comments: allow_comments).tokenize
      @index = 0
      @definitions = []
    end

    def parse
      parse_directives
      parse_definitions
      body = eof? ? AST::Identity.new : parse_expression
      expect(:eof)
      AST::Program.new(body, @definitions)
    end

    private

    def parse_directives
      consume_until_semicolon while keyword?('include') || keyword?('import') || keyword?('module')
    end

    def parse_definitions
      while keyword?('def')
        name, params, body = parse_function_definition
        expect(:semicolon)
        @definitions << AST::FunctionDefinition.new(name, params, body)
      end
    end

    def parse_function_definition
      expect_keyword('def')
      name = parse_name
      params = []
      if consume?(:lparen)
        until current.type == :rparen
          params << parse_param
          break unless %i[semicolon comma].include?(current.type)

          consume
        end
        expect(:rparen)
      end
      expect(:colon)
      [name, params, parse_expression]
    end

    def parse_param
      if current.type == :variable
        "$#{consume.value}"
      else
        expect(:identifier).value
      end
    end

    def parse_binding_pattern
      case current.type
      when :variable
        [:var, consume.value]
      when :lbrace
        parse_object_binding_pattern
      when :lbracket
        parse_array_binding_pattern
      else
        raise error('expected binding pattern')
      end
    end

    def parse_object_binding_pattern
      expect(:lbrace)
      pairs = []
      raise error('expected binding object key') if current.type == :rbrace

      until consume?(:rbrace)
        key =
          case current.type
          when :identifier, :string, :keyword
            consume.value
          when :variable
            variable = consume.value
            pairs << if consume?(:colon)
                       [variable, [:both, [:var, variable], parse_binding_pattern]]
                     else
                       [variable, [:var, variable]]
                     end
            next if consume?(:comma)

            expect(:rbrace)
            break
          when :lparen
            consume
            expression = parse_expression
            expect(:rparen)
            expression
          else
            raise error('expected binding object key')
          end
        pairs << [key, consume?(:colon) ? parse_binding_pattern : [:var, key]]
        next if consume?(:comma)

        expect(:rbrace)
        break
      end
      [:object, pairs]
    end

    def parse_array_binding_pattern
      expect(:lbracket)
      patterns = []
      raise error('expected binding pattern') if current.type == :rbracket

      until consume?(:rbracket)
        patterns << parse_binding_pattern
        next if consume?(:comma)

        expect(:rbracket)
        break
      end
      [:array, patterns]
    end

    def parse_expression(min_precedence = 0)
      left = parse_prefix
      loop do
        op = current_operator
        break unless op

        precedence = PRECEDENCE[op]
        break unless precedence && precedence >= min_precedence

        consume
        left = parse_infix(left, op, precedence)
      end
      left
    end

    def parse_infix(left, op, precedence)
      if op == 'as'
        pattern = parse_binding_pattern
        alternatives = [pattern]
        while current.type == :question && @tokens[@index + 1]&.type == :operator && @tokens[@index + 1]&.value == '//'
          consume
          consume
          alternatives << parse_binding_pattern
        end
        pattern = [:alternatives, alternatives] if alternatives.length > 1
        expect(:pipe)
        return AST::Binding.new(left, pattern, parse_expression)
      end

      right = parse_expression(ASSIGNMENT_OPERATORS.include?(op) ? precedence : precedence + 1)
      case op
      when '|'
        AST::Pipe.new(left, right)
      when ','
        AST::Comma.new(left, right)
      when *ASSIGNMENT_OPERATORS
        AST::Assignment.new(left, op, right)
      else
        AST::BinaryOp.new(left, op, right)
      end
    end

    def parse_prefix
      node =
        case current.type
        when :dot
          consume
          parse_dot_suffix(AST::Identity.new)
        when :operator
          parse_operator_prefix
        when :number
          AST::Literal.new(consume.value)
        when :string
          AST::StringLiteral.new(consume.value)
        when :variable
          AST::Variable.new(consume.value)
        when :identifier
          parse_identifier
        when :format
          parse_format
        when :keyword
          parse_keyword
        when :lparen
          consume
          expression = parse_expression_allowing_comma
          expect(:rparen)
          expression
        when :lbracket
          parse_array_literal
        when :lbrace
          parse_object_literal
        else
          raise error("unexpected token #{current.type}")
        end
      parse_postfix(node)
    end

    def parse_operator_prefix
      if current.value == '-'
        consume
        AST::UnaryOp.new('-', parse_expression(11))
      elsif current.value == '..'
        consume
        AST::Recurse.new
      else
        raise error("unexpected operator #{current.value}")
      end
    end

    def parse_identifier
      name = parse_name
      return AST::FunctionCall.new(name, parse_arguments) if consume?(:lparen)

      AST::FunctionCall.new(name, [])
    end

    def parse_name
      name = expect(:identifier).value
      if current.type == :colon && @tokens[@index + 1]&.type == :colon
        consume
        consume
        name = "#{name}::#{expect(:identifier).value}"
      end
      name
    end

    def parse_format
      name = "@#{consume.value}"
      return AST::Format.new(name, parse_prefix) if current.type == :string

      AST::Format.new(name)
    end

    def parse_keyword
      case current.value
      when 'null'
        consume
        AST::Literal.new(nil)
      when 'true'
        consume
        AST::Literal.new(true)
      when 'false'
        consume
        AST::Literal.new(false)
      when 'if'
        parse_if
      when 'def'
        parse_scoped_definition
      when 'try'
        parse_try
      when 'reduce'
        parse_reduce
      when 'foreach'
        parse_foreach
      when 'label'
        parse_label
      when 'break'
        parse_break
      when 'include', 'import', 'module'
        consume_until_semicolon
        AST::Identity.new
      when 'not'
        consume
        AST::FunctionCall.new('not', [])
      else
        raise error("unexpected keyword #{current.value}")
      end
    end

    def parse_if
      expect_keyword('if')
      condition = parse_expression_allowing_pipe
      expect_keyword('then')
      then_branch = parse_expression_allowing_pipe
      else_branch =
        if keyword?('elif')
          AST::If.new(parse_elif_condition, parse_elif_then, parse_elif_else)
        elsif keyword?('end')
          AST::Identity.new
        else
          expect_keyword('else')
          parse_expression_allowing_pipe
        end
      expect_keyword('end')
      AST::If.new(condition, then_branch, else_branch)
    end

    def parse_elif_condition
      expect_keyword('elif')
      parse_expression_allowing_pipe
    end

    def parse_elif_then
      expect_keyword('then')
      parse_expression_allowing_pipe
    end

    def parse_elif_else
      if keyword?('elif')
        AST::If.new(parse_elif_condition, parse_elif_then, parse_elif_else)
      elsif keyword?('end')
        AST::Identity.new
      else
        expect_keyword('else')
        parse_expression_allowing_pipe
      end
    end

    def parse_try
      expect_keyword('try')
      body = parse_expression
      handler = nil
      handler = parse_expression_stopping_at_comma_or_pipe if consume_keyword?('catch')
      AST::Try.new(body, handler)
    end

    def parse_scoped_definition
      name, params, body = parse_function_definition
      expect(:semicolon)
      AST::ScopedDefinition.new(AST::FunctionDefinition.new(name, params, body), parse_expression)
    end

    def parse_reduce
      expect_keyword('reduce')
      generator = parse_expression_until_keywords('as')
      expect_keyword('as')
      pattern = parse_binding_pattern
      expect(:lparen)
      initial = parse_expression
      expect(:semicolon)
      update = parse_expression
      expect(:rparen)
      AST::Reduce.new(generator, pattern, initial, update)
    end

    def parse_foreach
      expect_keyword('foreach')
      generator = parse_expression_until_keywords('as')
      expect_keyword('as')
      pattern = parse_binding_pattern
      expect(:lparen)
      initial = parse_expression
      expect(:semicolon)
      update = parse_expression
      extract = consume?(:semicolon) ? parse_expression : nil
      expect(:rparen)
      AST::Foreach.new(generator, pattern, initial, update, extract)
    end

    def parse_label
      expect_keyword('label')
      label = expect(:variable).value
      expect(:pipe)
      AST::Label.new(label, parse_expression)
    end

    def parse_break
      expect_keyword('break')
      AST::Break.new(expect(:variable).value)
    end

    def parse_arguments
      args = []
      until consume?(:rparen)
        args << parse_expression
        next if consume?(:semicolon)

        expect(:rparen)
        break
      end
      args
    end

    def parse_array_literal
      expect(:lbracket)
      return AST::ArrayLiteral.new(nil) if consume?(:rbracket)

      expression = parse_expression_allowing_comma
      expect(:rbracket)
      AST::ArrayLiteral.new(expression)
    end

    def parse_object_literal
      expect(:lbrace)
      pairs = []
      until consume?(:rbrace)
        pairs << parse_object_pair
        next if consume?(:comma)

        expect(:rbrace)
        break
      end
      AST::ObjectLiteral.new(pairs)
    end

    def parse_object_pair
      case current.type
      when :identifier, :keyword
        key = consume.value
        value = consume?(:colon) ? parse_expression_stopping_at_comma : AST::Field.new(AST::Identity.new, key)
      when :string
        key = consume.value
        value =
          if consume?(:colon)
            parse_expression_stopping_at_comma
          elsif key.is_a?(Array)
            AST::Index.new(AST::Identity.new, AST::StringLiteral.new(key))
          else
            AST::Field.new(AST::Identity.new, key)
          end
      when :variable
        variable = consume.value
        if consume?(:colon)
          key = AST::Variable.new(variable)
          value = parse_expression_stopping_at_comma
        else
          key = variable
          value = AST::Variable.new(variable)
        end
      when :lparen
        consume
        key = parse_expression
        expect(:rparen)
        expect(:colon)
        value = parse_expression_stopping_at_comma
      else
        raise error('expected object key')
      end
      AST::ObjectLiteral::Pair.new(key: key, value: value)
    end

    def parse_postfix(node)
      loop do
        node =
          case current.type
          when :dot
            consume
            parse_dot_suffix(node)
          when :lbracket
            parse_bracket_access(node)
          when :question
            consume
            AST::Optional.new(node)
          else
            return node
          end
      end
    end

    def parse_dot_suffix(base)
      case current.type
      when :identifier
        AST::Field.new(base, consume.value)
      when :string
        AST::Field.new(base, consume.value)
      when :lbracket
        parse_bracket_access(base)
      else
        base
      end
    end

    def parse_bracket_access(base)
      expect(:lbracket)
      return AST::Iterate.new(base) if consume?(:rbracket)

      if consume?(:colon)
        if consume?(:rbracket)
          finish_node = nil
        else
          finish_node = parse_expression(PRECEDENCE.fetch(',') + 1)
          expect(:rbracket)
        end
        return AST::Slice.new(base, nil, finish_node)
      end

      start_node = parse_expression_allowing_comma
      if consume?(:colon)
        if consume?(:rbracket)
          finish_node = nil
        else
          finish_node = parse_expression(PRECEDENCE.fetch(',') + 1)
          expect(:rbracket)
        end
        AST::Slice.new(base, start_node, finish_node)
      else
        expect(:rbracket)
        AST::Index.new(base, start_node)
      end
    end

    def current_operator
      return nil if stopped_keyword?

      return '|' if current.type == :pipe && !stop_at_pipe?
      return ',' if current.type == :comma && !stop_at_comma?
      return current.value if current.type == :operator
      return current.value if current.type == :keyword && %w[as and or].include?(current.value)

      nil
    end

    def parse_expression_stopping_at_comma
      @stop_at_comma = @stop_at_comma.to_i + 1
      parse_expression
    ensure
      @stop_at_comma -= 1
    end

    def parse_expression_stopping_at_comma_or_pipe
      @stop_at_comma = @stop_at_comma.to_i + 1
      @stop_at_pipe = @stop_at_pipe.to_i + 1
      parse_expression
    ensure
      @stop_at_comma -= 1
      @stop_at_pipe -= 1
    end

    def parse_expression_allowing_comma
      previous = @stop_at_comma
      @stop_at_comma = 0
      parse_expression
    ensure
      @stop_at_comma = previous
    end

    def parse_expression_allowing_pipe
      previous = @stop_at_pipe
      @stop_at_pipe = 0
      parse_expression
    ensure
      @stop_at_pipe = previous
    end

    def parse_expression_until_keywords(*keywords)
      @stop_keywords ||= []
      @stop_keywords.push(keywords.flatten)
      parse_expression
    ensure
      @stop_keywords.pop
    end

    def stop_at_comma?
      @stop_at_comma.to_i.positive?
    end

    def stop_at_pipe?
      @stop_at_pipe.to_i.positive?
    end

    def stopped_keyword?
      current.type == :keyword && @stop_keywords&.any? { |keywords| keywords.include?(current.value) }
    end

    def expect(type)
      raise error("expected #{type}, got #{current.type}") unless current.type == type

      consume
    end

    def expect_keyword(value)
      raise error("expected #{value}") unless keyword?(value)

      consume
    end

    def consume?(type)
      return false unless current.type == type

      consume
      true
    end

    def consume_keyword?(value)
      return false unless keyword?(value)

      consume
      true
    end

    def consume_until_semicolon
      consume until %i[semicolon eof].include?(current.type)
      consume?(:semicolon)
    end

    def keyword?(value)
      current.type == :keyword && current.value == value
    end

    def consume
      token = current
      @index += 1
      token
    end

    def previous
      @tokens[@index - 1]
    end

    def current
      @tokens[@index]
    end

    def eof?
      current.type == :eof
    end

    def error(message)
      ParseError.new("#{message} at line #{current.line}, column #{current.column}")
    end
  end
end
