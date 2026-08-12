# frozen_string_literal: true

module Rjq
  class SemanticAnalyzer
    def initialize(program)
      @program = program
    end

    def validate!
      global_functions = @program.definitions.map { |definition| signature(definition) }.to_h { |item| [item, true] }
      @program.definitions.each { |definition| validate_definition(definition, global_functions) }
      validate_instructions(@program.instructions, global_functions, {})
      @program
    end

    private

    def validate_definition(definition, functions)
      local_functions = functions.merge(signature(definition) => true)
      filter_parameters = definition.params.reject { |param| param.start_with?('$') }.to_h { |name| [name, true] }
      validate_instructions(definition.body.instructions, local_functions, filter_parameters)
    end

    def validate_instructions(instructions, functions, filter_parameters)
      instructions.each do |instruction|
        if instruction.op == :call
          validate_call(instruction, functions, filter_parameters)
        elsif instruction.op == :scoped_def
          validate_scoped_definition(instruction, functions, filter_parameters)
          next
        end
        validate_nested(instruction.arg1, functions, filter_parameters)
        validate_nested(instruction.arg2, functions, filter_parameters)
      end
    end

    def validate_call(instruction, functions, filter_parameters)
      name = instruction.arg1
      arity = instruction.arg2.length
      return if arity.zero? && filter_parameters[name]
      return if functions[[name, arity]]
      return if Builtins.valid_arity?(name, arity)

      raise CompileError, "#{name}/#{arity} is not defined"
    end

    def validate_scoped_definition(instruction, functions, filter_parameters)
      definition = instruction.arg1
      local_functions = functions.merge(signature(definition) => true)
      validate_definition(definition, local_functions)
      validate_nested(instruction.arg2, local_functions, filter_parameters)
    end

    def validate_nested(value, functions, filter_parameters)
      case value
      when BytecodeBlock
        validate_instructions(value.instructions, functions, filter_parameters)
      when BytecodeFunctionDefinition
        validate_definition(value, functions)
      when Array
        value.each { |item| validate_nested(item, functions, filter_parameters) }
      when Hash
        value.each_value { |item| validate_nested(item, functions, filter_parameters) }
      end
    end

    def signature(definition)
      [definition.name, definition.params.length]
    end
  end
end
