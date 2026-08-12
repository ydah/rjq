# frozen_string_literal: true

module Rjq
  class CompiledProgram
    attr_reader :ast, :program

    def initialize(ast, program:)
      @ast = ast
      @program = program
      freeze
    end

    def instructions
      program.instructions
    end

    def run(input_value, opts = {})
      VM.new(self, opts).run(input_value)
    end

    def disasm
      program.disasm
    end
  end

  class BytecodeCompiler
    def initialize
      @constants = []
      @constant_indices = {}
    end

    def compile(ast, module_metadata: {}, module_variables: {})
      instructions = compile_node(ast.body)
      Rjq::Program.new(
        instructions: instructions,
        constants: @constants,
        subroutines: {},
        definitions: ast.definitions.map { |definition| compile_definition(definition) },
        module_metadata: module_metadata,
        module_variables: module_variables
      )
    end

    private

    def compile_node(node)
      case node
      when AST::Identity
        [instruction(:load_input)]
      when AST::Literal
        [instruction(:load_const, const(node.value))]
      when AST::StringLiteral
        compile_string(node)
      when AST::Format
        compile_format(node)
      when AST::Variable
        [instruction(:variable, ivar(node, :name))]
      when AST::Field
        compile_node(ivar(node, :base)) + [instruction(:field, ivar(node, :name))]
      when AST::Index
        compile_index(node)
      when AST::Slice
        compile_slice(node)
      when AST::Iterate
        compile_node(ivar(node, :base)) + [instruction(:each)]
      when AST::Optional
        [instruction(:optional, block_for(ivar(node, :node)))]
      when AST::Pipe
        compile_node(ivar(node, :left)) + [instruction(:pipe, block_for(ivar(node, :right)))]
      when AST::Comma
        compile_node(node.left) + [instruction(:append, block_for(node.right))]
      when AST::Binding
        [instruction(:binding, {
                       source: block_for(ivar(node, :source)),
                       pattern: ivar(node, :pattern),
                       body: block_for(ivar(node, :body))
                     })]
      when AST::ArrayLiteral
        expression = ivar(node, :expression)
        [instruction(:array, expression ? block_for(expression) : nil)]
      when AST::ObjectLiteral
        [instruction(:object, compile_object_pairs(ivar(node, :pairs)))]
      when AST::FunctionCall
        compile_call(node)
      when AST::BinaryOp
        compile_binary(node)
      when AST::UnaryOp
        [instruction(:unary, ivar(node, :op), block_for(ivar(node, :expression)))]
      when AST::If
        compile_if(node)
      when AST::Try
        [instruction(:try, { body: block_for(ivar(node, :body)), handler: optional_block(ivar(node, :handler)) })]
      when AST::Reduce
        [instruction(:reduce, {
                       generator: block_for(ivar(node, :generator)),
                       pattern: ivar(node, :variable),
                       initial: block_for(ivar(node, :initial)),
                       update: block_for(ivar(node, :update))
                     })]
      when AST::Foreach
        [instruction(:foreach, {
                       generator: block_for(ivar(node, :generator)),
                       pattern: ivar(node, :variable),
                       initial: block_for(ivar(node, :initial)),
                       update: block_for(ivar(node, :update)),
                       extract: optional_block(ivar(node, :extract))
                     })]
      when AST::Label
        [instruction(:label, ivar(node, :label), block_for(ivar(node, :body)))]
      when AST::Break
        [instruction(:break, ivar(node, :label))]
      when AST::Assignment
        [instruction(:assign,
                     { left: block_for(ivar(node, :left)), op: ivar(node, :op), right: block_for(ivar(node, :right)) })]
      when AST::ScopedDefinition
        [instruction(:scoped_def, compile_definition(ivar(node, :definition)), block_for(ivar(node, :body)))]
      when AST::Recurse
        [instruction(:recurse)]
      else
        raise CompileError, "unsupported AST node #{node.class}"
      end
    end

    def compile_string(node)
      value = node.value
      return [instruction(:load_const, const(value))] if value.is_a?(String)

      [instruction(:string_interp, value.map { |kind, segment| compile_string_segment(kind, segment) })]
    end

    def compile_string_segment(kind, value)
      return { kind: :text, value: value } if kind == :text

      parsed = Parser.new(value).parse
      { kind: :expr, block: block_for(parsed.body), definitions: parsed.definitions.map do |definition|
        compile_definition(definition)
      end }
    end

    def compile_format(node)
      expression = ivar(node, :expression)
      return [instruction(:format, ivar(node, :name), nil)] unless expression

      if expression.is_a?(AST::StringLiteral) && expression.value.is_a?(Array)
        return [instruction(:format, ivar(node, :name), { segments: expression.value.map do |kind, value|
          compile_string_segment(kind, value)
        end })]
      end

      [instruction(:format, ivar(node, :name), { block: block_for(expression) })]
    end

    def compile_index(node)
      base = compile_node(ivar(node, :base))
      index = ivar(node, :index)
      return base + [instruction(:index_const, index.value)] if index.is_a?(AST::Literal)

      base + [instruction(:index_filter, block_for(index))]
    end

    def compile_slice(node)
      start_node = ivar(node, :start_node)
      finish_node = ivar(node, :finish_node)
      base = compile_node(ivar(node, :base))
      if literal_or_nil?(start_node) && literal_or_nil?(finish_node)
        return base + [instruction(:slice_const, literal_value(start_node), literal_value(finish_node))]
      end

      base + [instruction(:slice_filter, { start: optional_block(start_node), finish: optional_block(finish_node) })]
    end

    def compile_call(node)
      arg_blocks = node.args.map { |arg| block_for(arg) }
      return [instruction(:path, arg_blocks.first)] if node.name == 'path' && arg_blocks.length == 1

      [instruction(:call, node.name, arg_blocks)]
    end

    def compile_binary(node)
      op = ivar(node, :op)
      [instruction(:binary, op, [block_for(ivar(node, :left)), block_for(ivar(node, :right))])]
    end

    def compile_if(node)
      [instruction(
        :branch,
        block_for(ivar(node, :condition)),
        [block_for(ivar(node, :then_branch)), block_for(ivar(node, :else_branch))]
      )]
    end

    def block_for(node)
      BytecodeBlock.new(instructions: compile_node(node))
    end

    def optional_block(node)
      node ? block_for(node) : nil
    end

    def compile_definition(definition)
      BytecodeFunctionDefinition.new(
        name: definition.name,
        params: definition.params,
        body: block_for(definition.body)
      )
    end

    def compile_object_pairs(pairs)
      pairs.map do |pair|
        {
          key: compile_object_key(pair.key),
          value: block_for(pair.value)
        }
      end
    end

    def compile_object_key(key)
      return { type: :filter, block: block_for(key) } if key.is_a?(AST::Node)
      return { type: :filter, block: block_for(AST::StringLiteral.new(key)) } if key.is_a?(Array)

      { type: :literal, value: key }
    end

    def literal_or_nil?(node)
      node.nil? || node.is_a?(AST::Literal)
    end

    def literal_value(node)
      node&.value
    end

    def const(value)
      copy = Value.deep_copy(value)
      key = JSON::Dumper.dump(copy, indent: nil, sort_keys: true)
      return @constant_indices.fetch(key) if @constant_indices.key?(key)

      @constants << copy
      @constant_indices[key] = @constants.length - 1
    end

    def instruction(op, arg1 = nil, arg2 = nil)
      Instruction.new(op: op, arg1: arg1, arg2: arg2, loc: nil)
    end

    def ivar(object, name)
      object.instance_variable_get(:"@#{name}")
    end
  end

  class Compiler
    def initialize(opts = {})
      @opts = opts
    end

    def compile(filter_string)
      source_path = @opts[:source_path] || '<top-level>'
      parsed = Parser.new(filter_string, allow_comments: @opts.fetch(:allow_comments, true),
                                         source_name: source_path).parse
      resolver = @opts[:module_resolver] || default_module_resolver
      loaded = ModuleLoader.new(resolver).load(parsed, source_path: @opts[:source_path])
      ast = loaded.program
      program = BytecodeCompiler.new.compile(
        ast,
        module_metadata: loaded.metadata,
        module_variables: loaded.variables
      )
      SemanticAnalyzer.new(program).validate!
      program.finalize!
      CompiledProgram.new(ast, program: program)
    end

    private

    def default_module_resolver
      paths = @opts.fetch(:library_path, [])
      ModuleResolver.new(paths: paths, use_default_paths: paths.empty?)
    end

  end
end
