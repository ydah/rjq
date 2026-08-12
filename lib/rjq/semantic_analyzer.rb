# frozen_string_literal: true

module Rjq
  class SemanticAnalyzer
    PUSH_OPS = %i[
      load_input load_const string_interp format variable path optional binding array object branch try reduce foreach
      label unary binary assign call tail_call recurse scoped_def
    ].freeze
    TRANSFORM_OPS = %i[
      field index_const index_filter slice_const slice_filter each pipe append
    ].freeze

    def initialize(program)
      @program = program
    end

    def validate!
      global_functions = @program.definitions.map { |definition| signature(definition) }.to_h { |item| [item, true] }
      @program.definitions.each { |definition| validate_definition(definition, global_functions, {}) }
      validate_instructions(@program.instructions, global_functions, {}, {})
      @program
    end

    private

    def validate_definition(definition, functions, labels)
      local_functions = functions.merge(signature(definition) => true)
      filter_parameters = definition.params.reject { |param| param.start_with?('$') }.to_h { |name| [name, true] }
      validate_instructions(definition.body.instructions, local_functions, filter_parameters, labels)
    end

    def validate_instructions(instructions, functions, filter_parameters, labels)
      validate_stack(instructions)
      instructions.each do |instruction|
        validate_constant_object_keys(instruction) if instruction.op == :object
        if %i[call tail_call].include?(instruction.op)
          validate_call(instruction, functions, filter_parameters)
        elsif instruction.op == :scoped_def
          validate_scoped_definition(instruction, functions, filter_parameters, labels)
          next
        elsif instruction.op == :label
          validate_nested(instruction.arg2, functions, filter_parameters, labels.merge(instruction.arg1 => true))
          next
        elsif instruction.op == :break
          raise CompileError, "label $#{instruction.arg1} is not defined" unless labels[instruction.arg1]

          next
        end
        validate_nested(instruction.arg1, functions, filter_parameters, labels)
        validate_nested(instruction.arg2, functions, filter_parameters, labels)
      end
    end

    def validate_stack(instructions)
      depth = 0
      terminated = false
      instructions.each do |instruction|
        raise CompileError, "unknown opcode #{instruction.op}" unless Opcodes::ALL.include?(instruction.op)
        raise CompileError, 'unreachable bytecode after break' if terminated

        if PUSH_OPS.include?(instruction.op)
          depth += 1
        elsif TRANSFORM_OPS.include?(instruction.op)
          raise CompileError, "bytecode stack underflow at #{instruction.op}" if depth.zero?
        elsif instruction.op == :break
          terminated = true
        end
      end
      return if terminated
      raise CompileError, "bytecode stack has #{depth} values, expected 1" unless depth == 1
    end

    def validate_call(instruction, functions, filter_parameters)
      name = instruction.arg1
      arity = instruction.arg2.length
      return if arity.zero? && filter_parameters[name]
      return if functions[[name, arity]]
      return if Builtins.valid_arity?(name, arity)

      raise CompileError, "#{name}/#{arity} is not defined"
    end

    def validate_scoped_definition(instruction, functions, filter_parameters, labels)
      definition = instruction.arg1
      local_functions = functions.merge(signature(definition) => true)
      validate_definition(definition, local_functions, labels)
      validate_nested(instruction.arg2, local_functions, filter_parameters, labels)
    end

    def validate_nested(value, functions, filter_parameters, labels)
      case value
      when BytecodeBlock
        validate_instructions(value.instructions, functions, filter_parameters, labels)
      when BytecodeFunctionDefinition
        validate_definition(value, functions, labels)
      when Array
        value.each { |item| validate_nested(item, functions, filter_parameters, labels) }
      when Hash
        value.each_value { |item| validate_nested(item, functions, filter_parameters, labels) }
      end
    end

    def signature(definition)
      [definition.name, definition.params.length]
    end

    def validate_constant_object_keys(instruction)
      instruction.arg1.each do |pair|
        key = pair.fetch(:key)
        next unless key.fetch(:type) == :filter

        known, value = constant_filter_value(key.fetch(:block))
        next unless known
        next if value.is_a?(String)

        dumped = JSON::Dumper.dump(value, indent: nil)
        raise CompileError, "Cannot use #{Value.type_of(value)} (#{dumped}) as object key"
      end
    end

    def constant_filter_value(block)
      instructions = block.instructions
      if instructions.length > 1 && instructions.last.op == :pipe
        left = BytecodeBlock.new(instructions: instructions[0...-1])
        right = instructions.last.arg1
        left_known, left_value = constant_filter_value(left)
        return [false, nil] unless left_known
        return [true, left_value] if right.instructions.length == 1 && right.instructions.first.op == :load_input

        return constant_filter_value(right)
      end
      return [false, nil] unless instructions.length == 1

      instruction = instructions.first
      case instruction.op
      when :load_const
        [true, @program.constants.fetch(instruction.arg1)]
      when :array
        return [true, []] unless instruction.arg1

        constant_generator_block?(instruction.arg1) ? [true, []] : [false, nil]
      when :object
        constant_object_value(instruction.arg1)
      when :binary
        constant_binary_value(instruction)
      else
        [false, nil]
      end
    end

    def constant_generator_block?(block)
      instructions = block.instructions
      return constant_filter_value(block).first if instructions.length == 1
      return false unless instructions.last&.op == :append

      left = BytecodeBlock.new(instructions: instructions[0...-1])
      constant_generator_block?(left) && constant_generator_block?(instructions.last.arg1)
    end

    def constant_object_value(pairs)
      object = {}
      pairs.each do |pair|
        key = pair.fetch(:key)
        return [false, nil] unless key.fetch(:type) == :literal

        known, value = constant_filter_value(pair.fetch(:value))
        return [false, nil] unless known

        object[key.fetch(:value)] = value
      end
      [true, object]
    end

    def constant_binary_value(instruction)
      left_known, left = constant_filter_value(instruction.arg2[0])
      right_known, right = constant_filter_value(instruction.arg2[1])
      return [false, nil] unless left_known && right_known

      case instruction.arg1
      when '+'
        return [true, right] if left.nil?
        return [true, left] if right.nil?
        return [true, ''] if left.is_a?(String) && right.is_a?(String)
        return [true, []] if left.is_a?(Array) && right.is_a?(Array)
        return [true, {}] if left.is_a?(Hash) && right.is_a?(Hash)
        return [true, 0] if left.is_a?(Numeric) && right.is_a?(Numeric)
      when '-'
        return [true, []] if left.is_a?(Array) && right.is_a?(Array)
        return [true, 0] if left.is_a?(Numeric) && right.is_a?(Numeric)
      when '*'
        return [true, ''] if (left.is_a?(String) && right.is_a?(Numeric)) ||
                             (left.is_a?(Numeric) && right.is_a?(String))
        return [true, {}] if left.is_a?(Hash) && right.is_a?(Hash)
        return [true, 0] if left.is_a?(Numeric) && right.is_a?(Numeric)
      when '/'
        return [true, []] if left.is_a?(String) && right.is_a?(String)
        return [false, nil] if right.is_a?(Numeric) && right.zero?
        return [true, 0] if left.is_a?(Numeric) && right.is_a?(Numeric)
      when '%'
        return [false, nil] if right.is_a?(Numeric) && right.zero?
        return [true, 0] if left.is_a?(Numeric) && right.is_a?(Numeric)
      when '==', '!=', '<', '<=', '>', '>='
        return [true, true]
      end

      [false, nil]
    end
  end
end
