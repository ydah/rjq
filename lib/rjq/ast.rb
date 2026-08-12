# frozen_string_literal: true

module Rjq
  module AST
    SourceSpan = Struct.new(:filename, :line, :column, :start_offset, :end_offset, keyword_init: true)

    class Context
      attr_reader :variables, :functions, :options, :current_path, :binding_variable_paths

      def initialize(variables: {}, functions: {}, options: {}, current_path: [], binding_variable_paths: {})
        @variables = variables
        @functions = functions
        @options = options
        @current_path = current_path
        @binding_variable_paths = binding_variable_paths
      end

      def with_variable(name, value)
        copy(variables: variables.merge(name => value))
      end

      def with_function(name, arity, definition)
        copy(functions: functions.merge([name, arity] => definition))
      end

      def with_functions(new_functions)
        copy(functions: new_functions)
      end

      def with_path_state(current_path:, variables: binding_variable_paths)
        copy(current_path: current_path, binding_variable_paths: variables)
      end

      def with_options(new_options)
        copy(options: new_options)
      end

      private

      def copy(variables: @variables, functions: @functions, options: @options,
               current_path: @current_path, binding_variable_paths: @binding_variable_paths)
        self.class.new(variables: variables, functions: functions, options: options,
                       current_path: current_path, binding_variable_paths: binding_variable_paths)
      end
    end

    class Node
      attr_reader :source_span

      def with_source_span(span)
        @source_span = span
        self
      end

      def eval(_input, _context)
        raise NotImplementedError, "#{self.class}#eval"
      end

      def take(input, context, count)
        eval(input, context).first(count)
      end

      def paths(_input, _context)
        raise TypeError, "#{self.class} is not a path expression"
      end

      def invalid_path_message(result, _input, _context)
        "Invalid path expression with result #{JSON::Dumper.dump(result, indent: nil)}"
      end

      def assign_value(copy, input, context, value)
        paths(input, context).each { |path| copy = Path.set(copy, path, value) }
        copy
      end

      private

      def one(node, input, context)
        values = node.eval(input, context)
        values.first
      end

      def numeric(value)
        AST.numeric(value)
      end

      def range_for(length, start, finish)
        AST.range_for(length, start, finish)
      end
    end

    class Program < Node
      attr_reader :body, :definitions, :directives

      def initialize(body, definitions = [], directives = [])
        @body = body
        @definitions = definitions
        @directives = directives
      end

      def eval(input, context)
        body.eval(input, context_with_definitions(context))
      end

      def context_with_definitions(context)
        apply_definitions(context)
      end

      private

      def apply_definitions(context)
        definitions.reduce(context) do |ctx, definition|
          closed = definition.with_closure(ctx.functions)
          ctx_with_self = ctx.with_function(definition.name, definition.params.length, closed)
          ctx_with_self.with_function(
            definition.name,
            definition.params.length,
            definition.with_closure(ctx_with_self.functions)
          )
        end
      end
    end

    ModuleDirective = Struct.new(:type, :name, :metadata, :alias_name, keyword_init: true)

    class FunctionDefinition
      attr_reader :name, :params, :body, :closure

      def initialize(name, params, body, closure = nil)
        @name = name
        @params = params
        @body = body
        @closure = closure
      end

      def with_closure(functions)
        self.class.new(name, params, body, functions)
      end
    end

    class ScopedDefinition < Node
      attr_reader :definition, :body

      def initialize(definition, body)
        @definition = definition
        @body = body
      end

      def eval(input, context)
        @body.eval(input, apply_definition(context))
      end

      private

      def apply_definition(context)
        closed = @definition.with_closure(context.functions)
        context_with_self = context.with_function(@definition.name, @definition.params.length, closed)
        context_with_self.with_function(
          @definition.name,
          @definition.params.length,
          @definition.with_closure(context_with_self.functions)
        )
      end
    end

    class CapturedFilter < Node
      attr_reader :node, :captured_context

      def initialize(node, captured_context)
        @node = node
        @captured_context = captured_context
      end

      def eval(input, _context)
        node.eval(input, captured_context)
      end

      def take(input, _context, count)
        node.take(input, captured_context, count)
      end

      def paths(input, _context)
        node.paths(input, captured_context)
      end
    end

    class Identity < Node
      def eval(input, _context)
        [input]
      end

      def paths(_input, context)
        [context.current_path]
      end
    end

    class Literal < Node
      attr_reader :value

      def initialize(value)
        @value = value
      end

      def eval(_input, _context)
        [Value.deep_copy(value)]
      end
    end

    class StringLiteral < Node
      attr_reader :value

      def initialize(value)
        @value = value
      end

      def eval(input, context)
        return [@value] if @value.is_a?(String)

        @value.reduce(['']) do |prefixes, (kind, value)|
          suffixes = eval_segment(kind, value, input, context)
          prefixes.flat_map { |prefix| suffixes.map { |suffix| prefix + suffix } }
        end
      end

      private

      def eval_segment(kind, value, input, context)
        return [value] if kind == :text

        parser = Rjq::Parser.new(value)
        parser.parse.eval(input, context).map { |item| Builtins.to_string(item) }
      end
    end

    class Format < Node
      attr_reader :name, :expression

      def initialize(name, expression = nil)
        @name = name
        @expression = expression
      end

      def eval(input, context)
        return Builtins.call(@name, input, context, []) unless @expression

        if @expression.is_a?(StringLiteral) && @expression.value.is_a?(Array)
          return @expression.value.reduce(['']) do |prefixes, (kind, value)|
            suffixes = format_segment(kind, value, input, context)
            prefixes.flat_map { |prefix| suffixes.map { |suffix| prefix + suffix } }
          end
        end

        @expression.eval(input, context).flat_map { |value| Builtins.call(@name, value, context, []) }
      end

      private

      def format_segment(kind, value, input, context)
        return [value] if kind == :text

        Parser.new(value).parse.eval(input, context).map do |item|
          Builtins.to_string(Builtins.call(@name, item, context, []).first)
        end
      end
    end

    class Variable < Node
      attr_reader :name

      def initialize(name)
        @name = name
      end

      def eval(_input, context)
        return [ENV.to_h] if @name == 'ENV'

        if @name == 'ARGS'
          positional = context.variables.fetch('ARGS.positional', [])
          named = context.variables.fetch('ARGS.named', {})
          return [{ 'positional' => positional, 'named' => named }]
        end
        if @name == '__loc__'
          return [{ 'file' => source_span&.filename || context.options.fetch(:source_path, '<top-level>'),
                    'line' => source_span&.line || 1 }]
        end

        raise RuntimeError, "variable $#{@name} is not defined" unless context.variables.key?(@name)

        [context.variables[@name]]
      end

      def paths(input, context)
        return [context.binding_variable_paths.fetch(@name)] if context.binding_variable_paths.key?(@name)

        result = eval(input, context).first
        raise InvalidPathError.new(invalid_path_message(result, input, context), result)
      end
    end

    class Pipe < Node
      attr_reader :left, :right

      def initialize(left, right)
        @left = left
        @right = right
      end

      def eval(input, context)
        out = []
        @left.eval(input, context).each do |value|
          out.concat(@right.eval(value, context))
        rescue ErrorValue => e
          raise ErrorValue.new(e.value, outputs: out + (e.outputs || []))
        rescue BreakSignal => e
          raise BreakSignal.new(e.label, e.value, outputs: out + (e.outputs || []))
        end
        out
      end

      def paths(input, context)
        @left.paths(input, context).flat_map do |path|
          value = Path.get(input, path)
          @right.paths(value, context).map { |suffix| path + suffix }
        end
      rescue InvalidPathError => e
        raise InvalidPathError.new(@right.invalid_path_message(e.result, input, context), e.result)
      end
    end

    class Comma < Node
      attr_reader :left, :right

      def initialize(left, right)
        @left = left
        @right = right
      end

      def eval(input, context)
        left_values = @left.eval(input, context)
        left_values + @right.eval(input, context)
      rescue ErrorValue => e
        raise ErrorValue.new(e.value, outputs: Array(left_values) + (e.outputs || []))
      rescue BreakSignal => e
        raise BreakSignal.new(e.label, e.value, outputs: Array(left_values) + (e.outputs || []))
      end

      def take(input, context, count)
        left_values = @left.take(input, context, count)
        return left_values if left_values.length >= count

        left_values + @right.take(input, context, count - left_values.length)
      end

      def paths(input, context)
        @left.paths(input, context) + @right.paths(input, context)
      end
    end

    class Binding < Node
      attr_reader :source, :pattern, :body

      def initialize(source, pattern, body)
        @source = source
        @pattern = pattern
        @body = body
      end

      def eval(input, context)
        @source.eval(input, context).flat_map do |value|
          bound = AST.bind_pattern(context, @pattern, value)
          bound ? @body.eval(input, bound) : []
        end
      end

      def paths(input, context)
        values = @source.eval(input, context)
        values.flat_map do |value|
          bound, pattern_path, relative_variables = AST.bind_pattern_with_path(context, @pattern, value)
          base_path = context.current_path + pattern_path
          variable_paths = context.binding_variable_paths.to_h { |name, _path| [name, base_path] }
          variable_paths.merge!(relative_variables.transform_values { |path| context.current_path + path })
          AST.validate_pattern_path(input, base_path)
          scoped = bound.with_path_state(current_path: base_path, variables: variable_paths)
          AST.validate_binding_results(input, @body.eval(input, scoped), @body.paths(input, scoped),
                                       alternative_base: base_path,
                                       variable_paths: variable_paths.values,
                                       alternative_paths: AST.alternative_paths(@pattern))
        end
      end
    end

    class Field < Node
      attr_reader :base, :name

      def initialize(base, name, optional: false)
        @base = base
        @name = name
        @optional = optional
      end

      def eval(input, context)
        @base.eval(input, context).flat_map do |value|
          [read(value)]
        rescue Rjq::RuntimeError
          @optional ? [] : raise
        end
      end

      def paths(input, context)
        @base.paths(input, context).map { |path| path + [@name] }
      end

      def invalid_path_message(result, _input, _context)
        "Invalid path expression near attempt to access element #{@name.inspect} of #{JSON::Dumper.dump(result,
                                                                                                        indent: nil)}"
      end

      private

      def read(value)
        return nil if value.nil?
        return value[@name] if value.is_a?(Hash)

        raise TypeError, "Cannot index #{Value.type_of(value)} with string #{@name.inspect}"
      end
    end

    class Index < Node
      attr_reader :base, :index

      def initialize(base, index, optional: false)
        @base = base
        @index = index
        @optional = optional
      end

      def eval(input, context)
        @base.eval(input, context).flat_map do |value|
          @index.eval(input, context).map { |idx| read(value, idx) }
        rescue Rjq::RuntimeError
          @optional ? [] : raise
        end
      end

      def paths(input, context)
        indices = @index.eval(input, context)
        @base.paths(input, context).flat_map do |path|
          value = Path.get(input, path)
          indices.map { |index| path + [path_index(value, index)] }
        end
      end

      def invalid_path_message(result, input, context)
        index = @index.eval(input, context).first
        "Invalid path expression near attempt to access element #{JSON::Dumper.dump(index,
                                                                                    indent: nil)} of #{JSON::Dumper.dump(
                                                                                      result, indent: nil
                                                                                    )}"
      end

      private

      def read(value, index)
        Path.read_index(value, index)
      end

      def path_index(value, index)
        return index unless index.is_a?(Numeric)
        return index if index.respond_to?(:nan?) && index.nan?

        index = index.floor
        return index unless index.negative?

        length =
          case value
          when Array
            value.length
          when String
            value.each_char.count
          else
            0
          end
        normalized = length + index
        raise RuntimeError, 'Out of bounds negative array index' if normalized.negative?

        normalized
      end
    end

    class Slice < Node
      attr_reader :base, :start_node, :finish_node

      def initialize(base, start_node, finish_node, optional: false)
        @base = base
        @start_node = start_node
        @finish_node = finish_node
        @optional = optional
      end

      def eval(input, context)
        @base.eval(input, context).flat_map do |value|
          starts = @start_node ? @start_node.eval(input, context) : [nil]
          finishes = @finish_node ? @finish_node.eval(input, context) : [nil]
          starts.flat_map { |start| finishes.map { |finish| slice(value, start, finish) } }
        rescue Rjq::RuntimeError
          @optional ? [] : raise
        end
      end

      def paths(input, context)
        starts = @start_node ? @start_node.eval(input, context) : [nil]
        finishes = @finish_node ? @finish_node.eval(input, context) : [nil]
        @base.paths(input, context).flat_map do |path|
          starts.flat_map { |start| finishes.map { |finish| path + [{ 'start' => start, 'end' => finish }] } }
        end
      end

      def assign_value(copy, input, context, value)
        @base.paths(input, context).each do |path|
          starts = @start_node ? @start_node.eval(input, context) : [nil]
          finishes = @finish_node ? @finish_node.eval(input, context) : [nil]
          starts.each do |start|
            finishes.each do |finish|
              target = Path.get(copy, path)
              copy = Path.set(copy, path, replace_slice(target, start, finish, value))
            end
          end
        end
        copy
      end

      private

      def slice(value, start, finish)
        return nil if value.nil?

        case value
        when Array
          value[range_for(value.length, start, finish)] || []
        when String
          value.each_char.to_a[range_for(value.each_char.count, start, finish)].join
        else
          raise TypeError, "cannot slice #{Value.type_of(value)}"
        end
      end

      def replace_slice(target, start, finish, replacement)
        case target
        when Array
          raise TypeError, 'can only assign an array to an array slice' unless replacement.is_a?(Array)

          range = range_for(target.length, start, finish)
          target[0...range.begin] + Value.deep_copy(replacement) + target[range.end..].to_a
        when String
          raise TypeError, 'Cannot update string slices'
        else
          raise TypeError, "cannot slice #{Value.type_of(target)}"
        end
      end
    end

    class Iterate < Node
      attr_reader :base

      def initialize(base, optional: false)
        @base = base
        @optional = optional
      end

      def eval(input, context)
        @base.eval(input, context).flat_map do |value|
          iterate(value)
        rescue Rjq::RuntimeError
          @optional ? [] : raise
        end
      end

      def paths(input, context)
        @base.eval(input, context).flat_map do |value|
          keys =
            case value
            when Array
              (0...value.length).to_a
            when Hash
              value.keys
            else
              raise TypeError, "cannot iterate over #{Value.type_of(value)}"
            end
          @base.paths(input, context).flat_map { |path| keys.map { |key| path + [key] } }
        end
      rescue InvalidPathError => e
        raise InvalidPathError.new(invalid_path_message(e.result, input, context), e.result)
      end

      def invalid_path_message(result, _input, _context)
        "Invalid path expression near attempt to iterate through #{JSON::Dumper.dump(result, indent: nil)}"
      end

      private

      def iterate(value)
        case value
        when Array
          value
        when Hash
          value.values
        else
          raise TypeError, "Cannot iterate over #{Value.type_of(value)} (#{JSON::Dumper.dump(value, indent: nil)})"
        end
      end
    end

    class Optional < Node
      attr_reader :node

      def initialize(node)
        @node = node
      end

      def eval(input, context)
        @node.eval(input, context)
      rescue Rjq::RuntimeError
        []
      end
    end

    class ArrayLiteral < Node
      attr_reader :expression

      def initialize(expression)
        @expression = expression
      end

      def eval(input, context)
        [@expression ? @expression.eval(input, context) : []]
      end
    end

    class ObjectLiteral < Node
      Pair = Struct.new(:key, :value, keyword_init: true)
      attr_reader :pairs

      def initialize(pairs)
        @pairs = pairs
      end

      def eval(input, context)
        objects = [{}]
        @pairs.each do |pair|
          key_values = key_outputs(pair.key, input, context)
          value_values = pair.value.eval(input, context)
          objects = objects.flat_map do |object|
            key_values.flat_map do |key|
              value_values.map { |value| object.merge(key.to_s => value) }
            end
          end
        end
        objects
      end

      private

      def key_outputs(key, input, context)
        return StringLiteral.new(key).eval(input, context) if key.is_a?(Array)

        key.is_a?(Node) ? key.eval(input, context) : [key]
      end
    end

    class If < Node
      attr_reader :condition, :then_branch, :else_branch

      def initialize(condition, then_branch, else_branch)
        @condition = condition
        @then_branch = then_branch
        @else_branch = else_branch
      end

      def eval(input, context)
        @condition.eval(input, context).flat_map do |value|
          branch = Value.truthy?(value) ? @then_branch : @else_branch
          branch.eval(input, context)
        end
      end
    end

    class Try < Node
      attr_reader :body, :handler

      def initialize(body, handler = nil)
        @body = body
        @handler = handler
      end

      def eval(input, context)
        @body.eval(input, context)
      rescue Rjq::ErrorValue => e
        (e.outputs || []) + (@handler ? @handler.eval(e.value, context) : [])
      rescue Rjq::RuntimeError => e
        @handler ? @handler.eval(e.message, context) : []
      end
    end

    class Reduce < Node
      attr_reader :generator, :variable, :initial, :update

      def initialize(generator, variable, initial, update)
        @generator = generator
        @variable = variable
        @initial = initial
        @update = update
      end

      def eval(input, context)
        accumulators = @initial.eval(input, context)
        @generator.eval(input, context).each do |value|
          ctx = AST.bind_pattern(context, @variable, value)
          next unless ctx
          accumulators = accumulators.flat_map { |accumulator| @update.eval(accumulator, ctx) }
        end
        accumulators
      end
    end

    class Foreach < Node
      attr_reader :generator, :variable, :initial, :update, :extract

      def initialize(generator, variable, initial, update, extract)
        @generator = generator
        @variable = variable
        @initial = initial
        @update = update
        @extract = extract
      end

      def eval(input, context)
        out = []
        @initial.eval(input, context).each do |initial|
          accumulators = [initial]
          @generator.eval(input, context).each do |value|
            ctx = AST.bind_pattern(context, @variable, value)
            next unless ctx
            accumulators = accumulators.flat_map { |accumulator| @update.eval(accumulator, ctx) }
            accumulators.each { |accumulator| out.concat(@extract ? @extract.eval(accumulator, ctx) : [accumulator]) }
          rescue BreakSignal => e
            raise BreakSignal.new(e.label, e.value, outputs: out + (e.outputs || []))
          end
        end
        out
      end
    end

    class Label < Node
      attr_reader :label, :body

      def initialize(label, body)
        @label = label
        @body = body
      end

      def eval(input, context)
        @body.eval(input, context)
      rescue BreakSignal => e
        raise unless e.label == @label

        return e.outputs if e.outputs

        e.value.nil? ? [] : [e.value]
      end
    end

    class Break < Node
      attr_reader :label

      def initialize(label)
        @label = label
      end

      def eval(_input, _context)
        raise BreakSignal, @label
      end
    end

    class UnaryOp < Node
      attr_reader :op, :expression

      def initialize(op, expression)
        @op = op
        @expression = expression
      end

      def eval(input, context)
        @expression.eval(input, context).map do |value|
          case @op
          when '-'
            unless value.is_a?(Numeric)
              raise TypeError,
                    "#{Value.type_of(value)} (#{AST.short_dump(value)}) cannot be negated"
            end

            next -0.0 if value.zero?

            value * -1
          when 'not'
            !Value.truthy?(value)
          else
            raise "unknown unary operator #{@op}"
          end
        end
      end
    end

    class BinaryOp < Node
      attr_reader :left, :op, :right

      def initialize(left, op, right)
        @left = left
        @op = op
        @right = right
      end

      def eval(input, context)
        return eval_alternative(input, context) if @op == '//'
        return eval_boolean(input, context) if @op == 'and' || @op == 'or'

        left_values = @left.eval(input, context)
        right_values = @right.eval(input, context)
        left_values.flat_map do |left|
          right_values.map { |right| apply(left, right) }
        end
      end

      private

      def eval_alternative(input, context)
        left_values = @left.eval(input, context).select { |value| Value.truthy?(value) }
        return left_values unless left_values.empty?

        @right.eval(input, context)
      end

      def eval_boolean(input, context)
        @left.eval(input, context).flat_map do |left|
          if (@op == 'and' && !Value.truthy?(left)) || (@op == 'or' && Value.truthy?(left))
            [@op == 'or']
          else
            @right.eval(input, context).map { |right| Value.truthy?(right) }
          end
        end
      end

      def apply(left, right)
        case @op
        when '+'
          add(left, right)
        when '-'
          subtract(left, right)
        when '*'
          multiply(left, right)
        when '/'
          divide(left, right)
        when '%'
          modulo(left, right)
        when '=='
          Value.equal?(left, right)
        when '!='
          !Value.equal?(left, right)
        when '<'
          Value.compare(left, right).negative?
        when '<='
          Value.compare(left, right) <= 0
        when '>'
          Value.compare(left, right).positive?
        when '>='
          Value.compare(left, right) >= 0
        else
          raise "unknown operator #{@op}"
        end
      end

      def add(left, right)
        return right if left.nil?
        return left if right.nil?
        return numeric_pair(left, right).then { |a, b| a + b } if left.is_a?(Numeric) && right.is_a?(Numeric)
        return left + right if left.is_a?(String) && right.is_a?(String)
        return left + right if left.is_a?(Array) && right.is_a?(Array)
        return left.merge(right) if left.is_a?(Hash) && right.is_a?(Hash)

        raise TypeError, "#{Value.type_of(left)} and #{Value.type_of(right)} cannot be added"
      end

      def subtract(left, right)
        return numeric_pair(left, right).then { |a, b| a - b } if left.is_a?(Numeric) && right.is_a?(Numeric)
        if left.is_a?(Array) && right.is_a?(Array)
          return left.reject do |item|
            right.any? do |other|
              Value.equal?(item, other)
            end
          end
        end

        raise TypeError, "#{Value.type_of(left)} and #{Value.type_of(right)} cannot be subtracted"
      end

      def multiply(left, right)
        return numeric_pair(left, right).then { |a, b| a * b } if left.is_a?(Numeric) && right.is_a?(Numeric)
        return repeat_string(left, right) if left.is_a?(String) && right.is_a?(Numeric)
        return repeat_string(right, left) if right.is_a?(String) && left.is_a?(Numeric)
        return recursive_merge(left, right) if left.is_a?(Hash) && right.is_a?(Hash)

        raise TypeError, "#{Value.type_of(left)} and #{Value.type_of(right)} cannot be multiplied"
      end

      def divide(left, right)
        if left.is_a?(String) && right.is_a?(String)
          return left.each_char.to_a if right.empty?

          return left.split(right, -1)
        end

        left_number = numeric(left)
        right_number = numeric(right)
        raise TypeError, division_by_zero_message(left_number, right_number, 'divided') if right_number.zero?

        left_number.fdiv(right_number)
      end

      def modulo(left, right)
        left, right = numeric_pair(numeric(left), numeric(right))
        return Float::NAN if nan_number?(left) || nan_number?(right)

        left_integer = jq_integer(left)
        right_integer = jq_integer(right)
        raise TypeError, division_by_zero_message(left, right, 'divided (remainder)') if right_integer.zero?

        remainder = left_integer.remainder(right_integer)
        if remainder.zero? && left.is_a?(Float) && left.zero? && (1.0 / left).negative?
          return -0.0
        end
        return remainder.to_f.round(-3) if (nonfinite_number?(left) || nonfinite_number?(right)) &&
                                           unsafe_integer?(remainder)

        unsafe_integer?(remainder) ? remainder.to_f : remainder
      end

      def jq_integer(value)
        return (2**63) - 1 if value.respond_to?(:infinite?) && value.infinite? == 1
        return -(2**63) if value.respond_to?(:infinite?) && value.infinite? == -1

        [[value.to_i, -(2**63)].max, (2**63) - 1].min
      end

      def nonfinite_number?(value)
        value.respond_to?(:finite?) && !value.finite?
      end

      def numeric_pair(left, right)
        return [left.to_f, right.to_f] if unsafe_integer?(left) || unsafe_integer?(right)

        [left, right]
      end

      def unsafe_integer?(value)
        value.is_a?(Integer) && value.abs > (2**53)
      end

      def repeat_string(string, count)
        return nil if count.respond_to?(:nan?) && count.nan?

        count = count.floor
        return nil if count.negative?

        string * count
      end

      def recursive_merge(left, right)
        Value.merge_objects(left, right)
      end

      def division_by_zero_message(left, right, verb)
        "number (#{left}) and number (#{right}) cannot be #{verb} because the divisor is zero"
      end
    end

    class Assignment < Node
      DELETE = Object.new.freeze
      NO_OUTPUT = Object.new.freeze
      attr_reader :left, :op, :right

      def initialize(left, op, right)
        @left = left
        @op = op
        @right = right
      end

      def eval(input, context)
        @op == '=' ? assign(input, context) : update(input, context)
      end

      private

      def assign(input, context)
        values = @right.eval(input, context)
        return [] if values.empty?

        values.map do |value|
          copy = Value.deep_copy(input)
          @left.assign_value(copy, input, context, value)
        end
      end

      def update(input, context)
        operations = @left.paths(input, context).map do |path|
          current = Path.get(input, path)
          value = update_value(current, input, context)
          return [] if value.equal?(NO_OUTPUT)

          [path, value]
        end
        copy = Value.deep_copy(input)
        operations.reject { |_path, value| value.equal?(DELETE) }.each do |path, value|
          copy = Path.set(copy, path, value)
        end
        Builtins.ordered_delete_paths(operations.select do |_path, value|
          value.equal?(DELETE)
        end.map(&:first)).each do |path|
          Path.delete(copy, path)
        end
        [copy]
      end

      def update_value(current, input, context)
        if @op == '|='
          values = @right.eval(current, context)
          return DELETE if values.empty?

          values.first
        else
          values = @right.eval(input, context)
          return NO_OUTPUT if values.empty?

          rhs = values.first
          BinaryOp.new(Literal.new(current), @op.delete_suffix('='), Literal.new(rhs)).eval(current, context).first
        end
      end
    end

    class FunctionCall < Node
      attr_reader :name, :args

      def initialize(name, args = [])
        @name = name
        @args = args
      end

      def eval(input, context)
        if @args.empty? && context.variables[filter_variable_name(@name)].is_a?(Node)
          return context.variables[filter_variable_name(@name)].eval(input, context)
        end

        if context.functions.key?([@name, @args.length])
          return eval_user_function(input, context, context.functions.fetch([@name, @args.length]))
        end

        Builtins.call(@name, input, context, @args)
      end

      def paths(input, context)
        if @args.empty? && context.variables[filter_variable_name(@name)].is_a?(Node)
          return context.variables[filter_variable_name(@name)].paths(input, context)
        end

        return @args.first.eval(input, context).map { |path| Array(path) } if @name == 'getpath' && @args.length == 1

        if context.functions.key?([@name, @args.length])
          definition = context.functions.fetch([@name, @args.length])
          return call_contexts(input, context, definition).flat_map { |ctx| definition.body.paths(input, ctx) }
        end

        if @name == 'select' && @args.length == 1
          return @args.first.eval(input, context).any? { |value| Value.truthy?(value) } ? [[]] : []
        end
        return [] if @name == 'empty' && @args.empty?
        return [[0]] if @name == 'first' && @args.empty?
        return [[-1]] if @name == 'last' && @args.empty?

        result = eval(input, context)
        result = result.first if result.length == 1
        raise InvalidPathError.new(invalid_path_message(result, input, context), result)
      end

      private

      def eval_user_function(input, context, definition)
        call_contexts(input, context, definition).flat_map { |ctx| definition.body.eval(input, ctx) }
      end

      def call_contexts(input, context, definition)
        functions = (definition.closure || context.functions).merge([definition.name,
                                                                     definition.params.length] => definition)
        contexts = [context.with_functions(functions)]
        definition.params.zip(@args).each do |param, arg|
          if param.start_with?('$')
            values = arg.eval(input, context)
            contexts = contexts.flat_map do |ctx|
              values.map { |value| ctx.with_variable(param.delete_prefix('$'), value) }
            end
          else
            filter = resolve_filter_argument(arg, context)
            contexts = contexts.map { |ctx| ctx.with_variable(filter_variable_name(param), filter) }
          end
        end
        contexts
      end

      def resolve_filter_argument(arg, context)
        if arg.is_a?(FunctionCall) && arg.args.empty? && context.variables[filter_variable_name(arg.name)].is_a?(Node)
          return context.variables[filter_variable_name(arg.name)]
        end

        CapturedFilter.new(arg, context)
      end

      def filter_variable_name(name)
        "filter:#{name}"
      end
    end

    class Recurse < Node
      def eval(input, _context)
        values = []
        visit = lambda do |value|
          values << value
          case value
          when Array
            value.each { |item| visit.call(item) }
          when Hash
            value.each_value { |item| visit.call(item) }
          end
        end
        visit.call(input)
        values
      end

      def paths(input, _context)
        Path.paths(input, leaves_only: false)
      end
    end

    module_function

    def bind_pattern(context, pattern, value)
      case pattern[0]
      when :alternatives
        matched = pattern[1].lazy.map { |candidate| match_bind_pattern(context, candidate, value) }.find(&:itself)
        matched ||= bind_pattern(context, pattern[1].first, value)
        bind_missing_variables(matched, pattern_variable_names(pattern), nil)
      when :both
        bind_pattern(bind_pattern(context, pattern[1], value), pattern[2], value)
      when :var
        context.with_variable(pattern[1], value)
      when :object
        pattern[1].reduce(context) do |ctx, (key, child)|
          actual_key = key.is_a?(Node) ? key.eval(value, ctx).first : key
          unless value.nil? || value.is_a?(Hash)
            raise TypeError, "Cannot index #{Value.type_of(value)} with string #{actual_key.to_s.inspect}"
          end
          bind_pattern(ctx, child, value.is_a?(Hash) ? value[actual_key.to_s] : nil)
        end
      when :array
        unless value.nil? || value.is_a?(Array)
          raise TypeError, "Cannot index #{Value.type_of(value)} with number"
        end
        pattern[1].each_with_index.reduce(context) do |ctx, (child, index)|
          bind_pattern(ctx, child, value.is_a?(Array) ? value[index] : nil)
        end
      end
    end

    def match_bind_pattern(context, pattern, value)
      case pattern[0]
      when :var
        bind_pattern(context, pattern, value)
      when :object
        return nil unless value.nil? || value.is_a?(Hash)

        bind_pattern(context, pattern, value)
      when :array
        return nil unless value.nil? || value.is_a?(Array)

        bind_pattern(context, pattern, value)
      when :alternatives
        pattern[1].lazy.map { |candidate| match_bind_pattern(context, candidate, value) }.find(&:itself)
      when :both
        first = match_bind_pattern(context, pattern[1], value)
        first && match_bind_pattern(first, pattern[2], value)
      end
    end

    def pattern_variable_names(pattern)
      case pattern[0]
      when :var
        [pattern[1]]
      when :object
        pattern[1].flat_map { |_key, child| pattern_variable_names(child) }
      when :array
        pattern[1].flat_map { |child| pattern_variable_names(child) }
      when :both
        pattern_variable_names(pattern[1]) + pattern_variable_names(pattern[2])
      when :alternatives
        pattern[1].flat_map { |child| pattern_variable_names(child) }.uniq
      else
        []
      end
    end

    def bind_missing_variables(context, names, value)
      names.reduce(context) do |ctx, name|
        ctx.variables.key?(name) ? ctx : ctx.with_variable(name, value)
      end
    end

    def bind_pattern_with_path(context, pattern, value)
      candidates = pattern[0] == :alternatives ? pattern[1] : [pattern]
      errors = []
      candidates.each do |candidate|
        begin
          return bind_pattern_candidate_with_path(context, pattern, candidate, value)
        rescue Rjq::RuntimeError => e
          errors << e
        end
      end
      raise errors.last
    end

    def bind_pattern_candidate_with_path(context, pattern, candidate, value)
      bound, path, variables = bind_single_pattern_with_path(context, candidate, value)
      selected = value_at_path(value, path)
      pattern_variable_names(pattern).each do |name|
        next if variables.key?(name)

        variables[name] = selected.nil? ? path : (static_variable_path(pattern, name) || path)
      end
      [bind_missing_variables(bound, pattern_variable_names(pattern), nil), path, variables]
    end

    def validate_binding_results(input, results, paths, alternative_base: nil, variable_paths: [],
                                 alternative_paths: [])
      return [] if results.empty?

      validated = []
      switched_path = nil
      results.zip(paths).each do |result, path|
        if alternative_paths.include?([]) && path == alternative_base &&
           !binding_path_matches?(input, path, result)
          path = []
        end
        variable_path = variable_paths.include?(path)
        if switched_path && variable_path
          if binding_path_matches?(input, path, result)
            validated << switched_path
            next
          end
          raise InvalidPathError.new("Invalid path expression with result #{JSON::Dumper.dump(result, indent: nil)}",
                                     result, outputs: validated)
        end

        switching = !alternative_paths.empty? && variable_path && path != alternative_base
        if switching && validated.empty?
          validate_pattern_path(input, path) unless alternative_paths.include?([])
          validated << path
          switched_path = path unless binding_path_matches?(input, path, result)
          next
        end

        unless binding_path_matches?(input, path, result)
          raise InvalidPathError.new("Invalid path expression with result #{JSON::Dumper.dump(result, indent: nil)}",
                                     result, outputs: validated)
        end
        validated << path
        if switching && binding_path_matches?(input, path, result)
          switched_path = path
          validated << path
        end
      end
      validated
    end

    def binding_path_matches?(input, path, result)
      path && binding_path_components_valid?(input, path) && Value.equal?(value_at_path(input, path), result)
    end

    def binding_path_components_valid?(input, path)
      current = input
      path.each do |component|
        return true if current.nil?
        return false unless current.is_a?(Array) || current.is_a?(Hash)
        return false if current.is_a?(Array) && !component.is_a?(Numeric)
        return false if current.is_a?(Hash) && !component.is_a?(String)

        current = current.is_a?(Array) ? current[component.to_i] : current[component]
      end
      true
    end

    def alternative_paths(pattern)
      return [] unless pattern[0] == :alternatives

      pattern[1].map { |candidate| pattern_primary_path(candidate) }
    end

    def pattern_primary_path(pattern)
      case pattern[0]
      when :var then []
      when :object
        key, child = pattern[1].first
        [key.is_a?(Node) ? nil : key.to_s] + pattern_primary_path(child)
      when :array then [0] + pattern_primary_path(pattern[1].first || [:var, ''])
      when :both then pattern_primary_path(pattern[1]) + pattern_primary_path(pattern[2])
      else []
      end
    end

    def validate_pattern_path(input, path)
      return true if input.nil? || path.empty?

      current = input
      previous_container = input
      path.each do |component|
        unless current.is_a?(Array) || current.is_a?(Hash)
          raise InvalidPathError.new("Invalid path expression near attempt to access element #{component.inspect} of " \
                                     "#{JSON::Dumper.dump(previous_container, indent: nil)}", current)
        end
        if current.is_a?(Array) && !component.is_a?(Numeric)
          raise TypeError, "Cannot index array with string #{component.to_s.inspect}"
        end
        if current.is_a?(Hash) && !component.is_a?(String)
          raise TypeError, 'Cannot index object with number'
        end
        previous_container = current
        current = current.is_a?(Array) ? current[component.to_i] : current[component]
      end
      true
    end

    def bind_single_pattern_with_path(context, pattern, value)
      case pattern[0]
      when :var
        [context.with_variable(pattern[1], value), [], { pattern[1] => [] }]
      when :object
        unless value.nil? || value.is_a?(Hash)
          key = pattern[1].first&.first
          key = key.eval(value, context).first if key.is_a?(Node)
          raise TypeError, "Cannot index #{Value.type_of(value)} with string #{key.to_s.inspect}"
        end
        ctx = context
        combined = []
        variables = {}
        pattern[1].each do |key, child|
          actual_key = key.is_a?(Node) ? key.eval(value, ctx).first : key
          child_value = value.is_a?(Hash) ? value[actual_key.to_s] : nil
          ctx, child_path, child_variables = bind_single_pattern_with_path(ctx, child, child_value)
          full = [actual_key.to_s] + child_path
          combined.concat(full)
          variables.merge!(child_variables.transform_values { |path| [actual_key.to_s] + path })
        end
        variables.transform_values! { combined } if variables.length > 1
        [ctx, combined, variables]
      when :array
        unless value.nil? || value.is_a?(Array)
          raise TypeError, "Cannot index #{Value.type_of(value)} with number"
        end
        ctx = context
        entries = pattern[1].each_with_index.map do |child, index|
          child_value = value.is_a?(Array) ? value[index] : nil
          ctx, child_path, child_variables = bind_single_pattern_with_path(ctx, child, child_value)
          [[index] + child_path, child_variables.transform_values { |path| [index] + path }]
        end
        combined = entries.reverse.flat_map(&:first)
        variables = entries.each_with_object({}) { |(_path, vars), all| all.merge!(vars) }
        variables.transform_values! { combined } if variables.length > 1
        [ctx, combined, variables]
      when :both
        first_ctx, first_path, first_variables = bind_single_pattern_with_path(context, pattern[1], value)
        second_ctx, second_path, second_variables = bind_single_pattern_with_path(first_ctx, pattern[2], value)
        combined = first_path + second_path
        variables = first_variables.merge(second_variables)
        variables.transform_values! { combined } if variables.length > 1
        [second_ctx, combined, variables]
      else
        raise TypeError, 'invalid binding pattern'
      end
    end

    def static_variable_path(pattern, target, prefix = [])
      case pattern[0]
      when :var
        return prefix if pattern[1] == target
      when :object
        pattern[1].each do |key, child|
          next if key.is_a?(Node)

          found = static_variable_path(child, target, prefix + [key.to_s])
          return found if found
        end
      when :array
        pattern[1].each_with_index do |child, index|
          found = static_variable_path(child, target, prefix + [index])
          return found if found
        end
      when :both
        return static_variable_path(pattern[1], target, prefix) || static_variable_path(pattern[2], target, prefix)
      when :alternatives
        pattern[1].each do |candidate|
          found = static_variable_path(candidate, target, prefix)
          return found if found
        end
      end
      nil
    end

    def value_at_path(value, path)
      path.reduce(value) do |current, component|
        return nil unless current.is_a?(Array) || current.is_a?(Hash)
        return nil if current.is_a?(Array) && !component.is_a?(Numeric)
        return nil if current.is_a?(Hash) && !component.is_a?(String)

        current.is_a?(Array) ? current[component.to_i] : current[component]
      end
    end

    def valid_path_parent?(input, path)
      return true if input.nil? || path.empty?

      parent = path[0...-1].reduce(input) do |current, component|
        return false unless current.is_a?(Array) || current.is_a?(Hash)
        return false if current.is_a?(Array) && !component.is_a?(Numeric)
        return false if current.is_a?(Hash) && !component.is_a?(String)

        current.is_a?(Array) ? current[component.to_i] : current[component]
      end
      parent.is_a?(Array) || parent.is_a?(Hash)
    end

    def numeric(value)
      raise TypeError, "#{Value.type_of(value)} is not a number" unless value.is_a?(Numeric)

      value
    end

    def short_dump(value)
      dumped = JSON::Dumper.dump(value, indent: nil)
      dumped.length > 14 ? "#{dumped[0, 11]}..." : dumped
    end

    def range_for(length, start, finish)
      from = start.nil? || nan_number?(start) ? 0 : normalize_boundary(start, length, :floor)
      to = finish.nil? || nan_number?(finish) ? length : normalize_boundary(finish, length, :ceil)
      from...to
    end

    def normalize_boundary(index, length, rounding)
      raise TypeError, 'slice index must be a number' unless index.is_a?(Numeric)

      index = rounding == :ceil ? index.ceil : index.floor

      normalized = index.negative? ? length + index : index
      [[normalized, 0].max, length].min
    end

    def nan_number?(value)
      value.respond_to?(:nan?) && value.nan?
    end
  end
end
