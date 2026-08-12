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
    def initialize(allow_comments: true)
      @constants = []
      @constant_indices = {}
      @current_nodes = []
      @allow_comments = allow_comments
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
      @current_nodes << node
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
        [instruction(:variable, node.name, nil, loc: node.source_span)]
      when AST::Field
        compile_node(node.base) + [instruction(:field, node.name)]
      when AST::Index
        compile_index(node)
      when AST::Slice
        compile_slice(node)
      when AST::Iterate
        compile_node(node.base) + [instruction(:each)]
      when AST::Optional
        [instruction(:optional, block_for(node.node))]
      when AST::Pipe
        compile_node(node.left) + [instruction(:pipe, block_for(node.right))]
      when AST::Comma
        compile_node(node.left) + [instruction(:append, block_for(node.right))]
      when AST::Binding
        [instruction(:binding, {
                       source: block_for(node.source),
                       pattern: node.pattern,
                       body: block_for(node.body)
                     })]
      when AST::ArrayLiteral
        expression = node.expression
        [instruction(:array, expression ? block_for(expression) : nil)]
      when AST::ObjectLiteral
        [instruction(:object, compile_object_pairs(node.pairs))]
      when AST::FunctionCall
        compile_call(node)
      when AST::BinaryOp
        compile_binary(node)
      when AST::UnaryOp
        [instruction(:unary, node.op, block_for(node.expression))]
      when AST::If
        compile_if(node)
      when AST::Try
        [instruction(:try, { body: block_for(node.body), handler: optional_block(node.handler) })]
      when AST::Reduce
        [instruction(:reduce, {
                       generator: block_for(node.generator),
                       pattern: node.variable,
                       initial: block_for(node.initial),
                       update: block_for(node.update)
                     })]
      when AST::Foreach
        [instruction(:foreach, {
                       generator: block_for(node.generator),
                       pattern: node.variable,
                       initial: block_for(node.initial),
                       update: block_for(node.update),
                       extract: optional_block(node.extract)
                     })]
      when AST::Label
        [instruction(:label, node.label, block_for(node.body))]
      when AST::Break
        [instruction(:break, node.label)]
      when AST::Assignment
        [instruction(:assign,
                     { left: block_for(node.left), op: node.op, right: block_for(node.right) })]
      when AST::ScopedDefinition
        [instruction(:scoped_def, compile_definition(node.definition), block_for(node.body))]
      when AST::Recurse
        [instruction(:recurse)]
      else
        raise CompileError, "unsupported AST node #{node.class}"
      end
    ensure
      @current_nodes.pop
    end

    def compile_string(node)
      value = node.value
      return [instruction(:load_const, const(value))] if value.is_a?(String)

      [instruction(:string_interp, value.map { |kind, segment| compile_string_segment(kind, segment) })]
    end

    def compile_string_segment(kind, value)
      return { kind: :text, value: value } if kind == :text

      fragment = value.is_a?(SourceFragment) ? value : SourceFragment.new(
        source: value, filename: '<top-level>', line: 1, column: 1, start_offset: 0
      )
      parsed = Parser.new(fragment.source, allow_comments: @allow_comments, source_name: fragment.filename,
                                          initial_line: fragment.line, initial_column: fragment.column,
                                          start_offset: fragment.start_offset).parse
      { kind: :expr, block: block_for(parsed.body), definitions: parsed.definitions.map do |definition|
        compile_definition(definition)
      end }
    end

    def compile_format(node)
      expression = node.expression
      return [instruction(:format, node.name, nil)] unless expression

      if expression.is_a?(AST::StringLiteral) && expression.value.is_a?(Array)
        return [instruction(:format, node.name, { segments: expression.value.map do |kind, value|
          compile_string_segment(kind, value)
        end })]
      end

      [instruction(:format, node.name, { block: block_for(expression) })]
    end

    def compile_index(node)
      base = compile_node(node.base)
      index = node.index
      return base + [instruction(:index_const, index.value)] if index.is_a?(AST::Literal)

      base + [instruction(:index_filter, block_for(index))]
    end

    def compile_slice(node)
      start_node = node.start_node
      finish_node = node.finish_node
      base = compile_node(node.base)
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
      [instruction(:binary, node.op, [block_for(node.left), block_for(node.right)])]
    end

    def compile_if(node)
      [instruction(
        :branch,
        block_for(node.condition),
        [block_for(node.then_branch), block_for(node.else_branch)]
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

    def instruction(op, arg1 = nil, arg2 = nil, loc: nil)
      inherited_location = @current_nodes.reverse_each.lazy.filter_map(&:source_span).first
      location = loc || inherited_location || AST::SourceSpan.new(
        filename: '<top-level>', line: 1, column: 1, start_offset: 0, end_offset: 0
      )
      Instruction.new(op: op, arg1: arg1, arg2: arg2, loc: location)
    end
  end

  class Compiler
    OPTION_KEYS = %i[allow_comments library_path module_resolver source_path].freeze

    class << self
      def options_from(opts)
        opts.slice(*OPTION_KEYS)
      end

      def validate_options!(opts)
        raise ArgumentError, 'options must be a Hash' unless opts.is_a?(Hash)

        unknown = opts.keys - OPTION_KEYS
        raise ArgumentError, "unknown compiler option: #{unknown.first.inspect}" unless unknown.empty?

        validate_boolean!(opts, :allow_comments)
        validate_optional_string!(opts, :source_path)
        validate_library_path!(opts[:library_path]) if opts.key?(:library_path)
        validate_module_resolver!(opts[:module_resolver]) if opts.key?(:module_resolver)
        opts
      end

      private

      def validate_boolean!(opts, key)
        return unless opts.key?(key)
        return if opts[key] == true || opts[key] == false

        raise ArgumentError, "#{key} must be true or false"
      end

      def validate_optional_string!(opts, key)
        return unless opts.key?(key)
        return if opts[key].nil? || opts[key].is_a?(String)

        raise ArgumentError, "#{key} must be a String or nil"
      end

      def validate_library_path!(paths)
        return if paths.is_a?(Array) && paths.all? { |path| path.is_a?(String) }

        raise ArgumentError, 'library_path must be an Array of Strings'
      end

      def validate_module_resolver!(resolver)
        return if resolver.respond_to?(:resolve) && resolver.respond_to?(:initial_metadata)

        raise ArgumentError, 'module_resolver must respond to resolve and initial_metadata'
      end
    end

    def initialize(opts = {})
      @opts = self.class.validate_options!(opts).dup.freeze
    end

    def compile(filter_string)
      source_path = @opts[:source_path] || '<top-level>'
      parsed = Parser.new(filter_string, allow_comments: @opts.fetch(:allow_comments, true),
                                         source_name: source_path).parse
      resolver = @opts[:module_resolver] || default_module_resolver
      allow_comments = @opts.fetch(:allow_comments, true)
      loaded = ModuleLoader.new(resolver, allow_comments: allow_comments).load(parsed, source_path: @opts[:source_path])
      ast = loaded.program
      program = BytecodeCompiler.new(allow_comments: allow_comments).compile(
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
