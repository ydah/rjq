# frozen_string_literal: true

module Rjq
  module Opcodes
    ALL = %i[
      load_input load_const string_interp format variable field index_const index_filter slice_const slice_filter
      each path optional pipe append binding array object branch try reduce foreach label break unary binary assign
      call recurse scoped_def
    ].freeze

    MNEMONICS = ALL.to_h { |opcode| [opcode, opcode.to_s] }.freeze
  end

  Instruction = Struct.new(:op, :arg1, :arg2, :loc, keyword_init: true) do
    def to_s
      [Opcodes::MNEMONICS.fetch(op), format_arg(arg1), format_arg(arg2)].compact.join(' ')
    end

    private

    def format_arg(value)
      return nil if value.nil?

      case value
      when BytecodeBlock
        "<block:#{value.instructions.length}>"
      when BytecodeFunctionDefinition
        "<def:#{value.name}/#{value.params.length}>"
      when Array
        "[#{value.map { |item| format_arg(item) }.join(',')}]"
      when Hash
        "{#{value.map { |key, item| "#{key}:#{format_arg(item)}" }.join(',')}}"
      else
        value.inspect
      end
    end
  end

  BytecodeBlock = Struct.new(:instructions, keyword_init: true)

  BytecodeFunctionDefinition = Struct.new(:name, :params, :body, :closure, keyword_init: true) do
    def with_closure(functions)
      self.class.new(name: name, params: params, body: body, closure: functions)
    end
  end

  class Program
    attr_reader :instructions, :constants, :subroutines, :definitions, :module_metadata, :module_variables

    def initialize(instructions:, constants: [], subroutines: {}, definitions: [], module_metadata: {},
                   module_variables: {})
      @instructions = instructions
      @constants = constants
      @subroutines = subroutines
      @definitions = definitions
      @module_metadata = module_metadata
      @module_variables = module_variables
    end

    def disasm
      lines = []
      append_disasm(lines, instructions, 'main', 0)
      lines.join("\n")
    end

    def finalize!
      freeze_value(instructions)
      freeze_value(constants)
      freeze_value(subroutines)
      freeze_value(definitions)
      freeze_value(module_metadata)
      freeze_value(module_variables)
      freeze
    end

    private

    def append_disasm(lines, block, name, indent)
      pad = ' ' * indent
      lines << "#{pad}== #{name} =="
      block.each_with_index do |instruction, index|
        lines << format("#{pad}%04d %s", index, instruction)
        append_nested(lines, instruction, indent + 2)
      end
    end

    def append_nested(lines, instruction, indent)
      append_nested_value(lines, instruction.arg1, indent, 'arg1')
      append_nested_value(lines, instruction.arg2, indent, 'arg2')
    end

    def append_nested_value(lines, value, indent, name)
      case value
      when BytecodeBlock
        append_disasm(lines, value.instructions, name, indent)
      when BytecodeFunctionDefinition
        append_disasm(lines, value.body.instructions, "#{name}:#{value.name}/#{value.params.length}", indent)
      when Array
        value.each_with_index { |item, index| append_nested_value(lines, item, indent, "#{name}[#{index}]") }
      when Hash
        value.each { |key, item| append_nested_value(lines, item, indent, "#{name}.#{key}") }
      end
    end

    def freeze_value(root)
      stack = [root]
      seen = {}
      until stack.empty?
        value = stack.pop
        next if value.nil? || seen[value.object_id]

        seen[value.object_id] = true
        case value
        when Array
          stack.concat(value)
        when Hash
          stack.concat(value.keys)
          stack.concat(value.values)
        when Struct
          stack.concat(value.to_a)
        end
        value.freeze
      end
    end
  end
end
