# frozen_string_literal: true

module Rjq
  class ModuleLoader
    Result = Struct.new(:program, :metadata, :variables, keyword_init: true)
    MAX_DEPTH = 64

    def initialize(resolver)
      @resolver = resolver
      @cache = {}
    end

    def load(program, source_path: nil, stack: [])
      raise CompileError, "module import depth exceeds #{MAX_DEPTH}" if stack.length >= MAX_DEPTH
      program.directives.select { |directive| directive.type == :module }.each do |directive|
        ConstantEvaluator.evaluate_object(directive.metadata)
      end

      definitions = []
      variables = {}
      metadata = @resolver.initial_metadata.dup
      program.directives.each do |directive|
        next if directive.type == :module

        options = directive.metadata ? ConstantEvaluator.evaluate_object(directive.metadata) : {}
        data = directive.alias_name&.start_with?('$') || false
        source = @resolver.resolve(directive.name, from: source_path, metadata: options, data: data)
        raise CompileError, "circular module import: #{directive.name}" if stack.include?(source.path)

        if data
          value = JSON::Parser.parse_one(source.content)
          name = directive.alias_name.delete_prefix('$')
          variables[name] = value
          definitions << AST::FunctionDefinition.new("#{name}::#{name}", [], AST::Literal.new(value))
          metadata[directive.name] ||= data_metadata
          next
        end

        loaded, parsed = @cache[source.path]
        unless loaded
          parsed = Parser.new(source.content, source_name: source.path).parse
          loaded = load(parsed, source_path: source.path, stack: stack + [source.path])
          @cache[source.path] = [loaded, parsed]
        end
        metadata.merge!(loaded.metadata)
        metadata[directive.name] = metadata_for(parsed)
        variables.merge!(loaded.variables)
        imported = loaded.program.definitions
        imported = namespace_definitions(imported, directive.alias_name) if directive.type == :import
        definitions.concat(imported)
      end
      definitions.concat(program.definitions)
      Result.new(
        program: AST::Program.new(program.body, definitions, []),
        metadata: metadata,
        variables: variables
      )
    end

    private

    def metadata_for(program)
      declaration = program.directives.find { |directive| directive.type == :module }
      object = declaration ? ConstantEvaluator.evaluate_object(declaration.metadata) : { 'whatever' => nil }
      object.merge(
        'deps' => program.directives.filter_map { |directive| dependency_metadata(directive) },
        'defs' => program.definitions.map { |definition| "#{definition.name}/#{definition.params.length}" }
      )
    end

    def dependency_metadata(directive)
      return if directive.type == :module

      data = directive.alias_name&.start_with?('$') || false
      metadata = { 'is_data' => data, 'relpath' => directive.name }
      metadata.merge!(ConstantEvaluator.evaluate_object(directive.metadata)) if directive.metadata
      metadata['as'] = directive.alias_name.delete_prefix('$') if directive.alias_name
      metadata['as'] ||= File.basename(directive.name) if directive.type == :include
      metadata
    end

    def data_metadata
      { 'whatever' => nil, 'deps' => [], 'defs' => [] }
    end

    def namespace_definitions(definitions, namespace)
      cloned = Marshal.load(Marshal.dump(definitions))
      signatures = cloned.to_h { |definition| [[definition.name, definition.params.length], true] }
      cloned.each do |definition|
        namespace_calls(definition.body, namespace, signatures)
        definition.instance_variable_set(:@name, "#{namespace}::#{definition.name}")
      end
      cloned
    end

    def namespace_calls(value, namespace, signatures)
      if value.is_a?(AST::FunctionCall)
        name = value.name
        value.instance_variable_set(:@name, "#{namespace}::#{name}") if signatures[[name, value.args.length]]
      end
      nested_values(value).each { |child| namespace_calls(child, namespace, signatures) }
    end

    def nested_values(value)
      case value
      when AST::Node
        value.instance_variables.map { |name| value.instance_variable_get(name) }
      when Array
        value
      when Hash
        value.values
      when Struct
        value.to_a
      else
        []
      end
    end
  end

  class ConstantEvaluator
    class << self
      def evaluate_object(node)
        value = evaluate(node)
        raise CompileError, 'Module metadata must be an object' unless value.is_a?(Hash)

        value
      end

      def evaluate(node)
        case node
        when AST::Literal
          Value.deep_copy(node.value)
        when AST::StringLiteral
          raise CompileError, 'Module metadata must be constant' unless node.value.is_a?(String)

          node.value
        when AST::ArrayLiteral
          expression = node.instance_variable_get(:@expression)
          expression ? evaluate_sequence(expression) : []
        when AST::ObjectLiteral
          evaluate_object_literal(node)
        when AST::UnaryOp
          evaluate_unary(node)
        else
          raise CompileError, 'Module metadata must be constant'
        end
      end

      private

      def evaluate_sequence(node)
        return evaluate_sequence(node.left) + evaluate_sequence(node.right) if node.is_a?(AST::Comma)

        [evaluate(node)]
      end

      def evaluate_object_literal(node)
        node.instance_variable_get(:@pairs).to_h do |pair|
          key = pair.key
          raise CompileError, 'Module metadata must be constant' unless key.is_a?(String)

          [key, evaluate(pair.value)]
        end
      end

      def evaluate_unary(node)
        op = node.instance_variable_get(:@op)
        value = evaluate(node.instance_variable_get(:@expression))
        raise CompileError, 'Module metadata must be constant' unless op == '-' && value.is_a?(Numeric)

        -value
      end
    end
  end
end
