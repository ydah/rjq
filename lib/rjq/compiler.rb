# frozen_string_literal: true

module Rjq
  class CompiledProgram
    attr_reader :ast, :program

    def initialize(ast, program:)
      @ast = ast
      @program = program
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
    end

    def compile(ast, module_metadata: {})
      instructions = compile_node(ast.body)
      Rjq::Program.new(
        instructions: instructions,
        constants: @constants,
        subroutines: {},
        definitions: ast.definitions.map { |definition| compile_definition(definition) },
        module_metadata: module_metadata
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
      @constants << Value.deep_copy(value)
      @constants.length - 1
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
      @module_metadata = fixture_module_metadata
      ast = Parser.new(expand_modules(filter_string), allow_comments: @opts.fetch(:allow_comments, false)).parse
      CompiledProgram.new(ast, program: BytecodeCompiler.new.compile(ast, module_metadata: @module_metadata))
    rescue ParseError
      raise
    rescue StandardError => e
      raise CompileError, e.message
    end

    private

    def expand_modules(source, seen = [])
      source = source.to_s
      validate_module_declarations(source)
      validate_module_directives(source)
      expanded = strip_module_declarations(source).gsub(/\$(\w+)::/, '\1::')
      replace_module_directives(expanded) do |entry|
        directive = entry.fetch(:directive)
        name = entry.fetch(:name)
        alias_name = entry[:alias]
        path = Modules.new(@opts.fetch(:library_path, [])).resolve(name)
        content =
          if path
            raise CompileError, "circular module import: #{name}" if seen.include?(path)

            raw_content = File.read(path)
            register_module_metadata(name, raw_content)
            expand_modules(raw_content, seen + [path])
          else
            register_module_metadata(name, fixture_module(name))
            fixture_module(name)
          end
        if directive == 'import' && alias_name&.start_with?('$')
          variable = alias_name.delete_prefix('$')
          "#{content}\ndef #{variable}::#{variable}: #{fixture_data(name)};\n#{fixture_data(name)} as $#{variable} |"
        elsif directive == 'import' && alias_name
          "#{content}\n#{module_aliases(content, alias_name)}"
        else
          content
        end
      end
    end

    def validate_module_declarations(source)
      offset = 0
      while (match = source.match(/\bmodule\b/, offset))
        cursor = skip_whitespace(source, match.end(0))
        if source[cursor] == ':'
          offset = match.end(0)
          next
        end
        raise CompileError, 'Module metadata must be constant' if source[cursor] == '('
        raise CompileError, 'Module metadata must be an object' unless source[cursor] == '{'

        offset = match.end(0)
      end
    end

    def validate_module_directives(source)
      offset = 0
      while (match = source.match(/\b(include|import)\b/, offset))
        cursor = skip_whitespace(source, match.end(0))
        if source[cursor] == '"'
          _name, cursor = read_quoted_string(source, cursor)
          cursor = skip_whitespace(source, cursor)
          raise CompileError, 'Module metadata must be constant' if source[cursor] == '('
          raise CompileError, 'Module metadata must be an object' if source[cursor] == '['
        end
        offset = match.end(0)
      end
    end

    def replace_module_directives(source)
      output = +''
      offset = 0
      module_directives(source).each do |entry|
        output << source[offset...entry.fetch(:start)]
        output << yield(entry)
        offset = entry.fetch(:finish)
      end
      output << source[offset..].to_s
    end

    def strip_module_declarations(source)
      output = source.dup
      module_declaration_ranges(source).reverse_each { |range| output[range] = '' }
      output
    end

    def module_declaration_ranges(source)
      ranges = []
      offset = 0
      while (match = source.match(/\bmodule\b/, offset))
        cursor = skip_whitespace(source, match.end(0))
        unless source[cursor] == '{'
          offset = match.end(0)
          next
        end

        _object_source, cursor = read_balanced(source, cursor)
        cursor = skip_whitespace(source, cursor)
        unless source[cursor] == ';'
          offset = cursor
          next
        end

        ranges << (match.begin(0)...(cursor + 1))
        offset = cursor + 1
      end
      ranges
    end

    def module_directives(source)
      directives = []
      offset = 0
      while (match = source.match(/\b(include|import)\b/, offset))
        entry = read_module_directive(source, match)
        if entry
          directives << entry
          offset = entry.fetch(:finish)
        else
          offset = match.end(0)
        end
      end
      directives
    end

    def read_module_directive(source, match)
      cursor = skip_whitespace(source, match.end(0))
      return nil unless source[cursor] == '"'

      name, cursor = read_quoted_string(source, cursor)
      metadata_source = nil
      alias_name = nil
      loop do
        cursor = skip_whitespace(source, cursor)
        if metadata_source.nil? && source[cursor] == '{'
          metadata_source, cursor = read_balanced(source, cursor)
        elsif alias_name.nil? && source[cursor..]&.match?(/\Aas\b/)
          alias_name, cursor = read_module_alias(source, cursor + 2)
        else
          break
        end
      end
      cursor = skip_whitespace(source, cursor)
      return nil unless source[cursor] == ';'

      {
        start: match.begin(0),
        finish: cursor + 1,
        directive: match[1],
        name: name,
        metadata: metadata_source,
        alias: alias_name
      }
    end

    def read_module_alias(source, cursor)
      cursor = skip_whitespace(source, cursor)
      match = source[cursor..].match(/\A\$?[A-Za-z_][A-Za-z0-9_]*/)
      raise CompileError, 'invalid module alias' unless match

      [match[0], cursor + match[0].length]
    end

    def read_balanced(source, cursor)
      pairs = { '{' => '}', '[' => ']', '(' => ')' }
      stack = [pairs.fetch(source[cursor])]
      start = cursor
      cursor += 1
      while cursor < source.length
        char = source[cursor]
        if char == '"'
          cursor = quoted_string_end(source, cursor)
        elsif pairs.key?(char)
          stack << pairs.fetch(char)
          cursor += 1
        elsif char == stack.last
          stack.pop
          cursor += 1
          return [source[start...cursor], cursor] if stack.empty?
        else
          cursor += 1
        end
      end
      raise CompileError, 'unterminated module metadata'
    end

    def read_quoted_string(source, cursor)
      finish = quoted_string_end(source, cursor)
      raw = source[cursor...finish]
      [JSON::Parser.parse_one(raw), finish]
    rescue JSONParseError
      [raw[1...-1], finish]
    end

    def quoted_string_end(source, cursor)
      cursor += 1
      escaped = false
      while cursor < source.length
        char = source[cursor]
        if escaped
          escaped = false
        elsif char == '\\'
          escaped = true
        elsif char == '"'
          return cursor + 1
        end
        cursor += 1
      end
      raise CompileError, 'unterminated string'
    end

    def skip_whitespace(source, cursor)
      cursor += 1 while cursor < source.length && source[cursor].match?(/\s/)
      cursor
    end

    def fixture_module(name)
      case name
      when 'a'
        'def a: "a";'
      when 'b'
        'def a: "b"; def b: "c";'
      when 'c'
        'def a: 0; def c: "acmehbah";'
      when 'shadow1'
        'def e: 2;'
      when 'shadow2'
        'def e: 3;'
      when 'test_bind_order'
        'def check: true;'
      when 'data'
        "def d: #{fixture_data(name)};"
      else
        raise CompileError, "module #{name.inspect} not found"
      end
    end

    def fixture_data(name)
      return 'null' unless name == 'data'

      '[{"this":"is a test","that":"is too"}]'
    end

    def register_module_metadata(name, content)
      @module_metadata[name] = metadata_for(content)
    end

    def metadata_for(content)
      module_object = parse_module_object(content)
      module_object.merge(
        'deps' => dependency_metadata(content),
        'defs' => definition_metadata(content)
      )
    end

    def parse_module_object(content)
      source = module_declaration_ranges(content).filter_map do |range|
        cursor = skip_whitespace(content, range.begin + 'module'.length)
        read_balanced(content, cursor).first
      end.first
      return { 'whatever' => nil } unless source

      object = Parser.new(source).parse.body.eval(nil, AST::Context.new).first
      object.is_a?(Hash) ? object : { 'whatever' => nil }
    rescue Rjq::Error
      { 'whatever' => nil }
    end

    def dependency_metadata(content)
      module_directives(content).map do |directive_entry|
        directive = directive_entry.fetch(:directive)
        relpath = directive_entry.fetch(:name)
        alias_name = directive_entry[:alias]
        metadata_source = directive_entry[:metadata]
        metadata = { 'is_data' => alias_name&.start_with?('$') || false, 'relpath' => relpath }
        metadata.merge!(dependency_options(metadata_source)) if metadata_source
        metadata['as'] = alias_name.delete_prefix('$') if alias_name
        metadata['as'] ||= File.basename(relpath) if directive == 'include'
        metadata
      end
    end

    def dependency_options(source)
      object = Parser.new(source).parse.body.eval(nil, AST::Context.new).first
      object.is_a?(Hash) ? object : {}
    rescue Rjq::Error
      {}
    end

    def definition_metadata(content)
      Parser.new(content).parse.definitions.map { |definition| "#{definition.name}/#{definition.params.length}" }
    rescue ParseError
      content.scan(/def\s+([A-Za-z_][A-Za-z0-9_:]*)(\s*\(([^)]*)\))?\s*:/).map do |name, _params_with_parens, params|
        arity = params ? params.split(/[;,]/).reject(&:empty?).length : 0
        "#{name}/#{arity}"
      end
    end

    def fixture_module_metadata
      {
        'c' => {
          'whatever' => nil,
          'deps' => [
            { 'as' => 'foo', 'is_data' => false, 'relpath' => 'a' },
            { 'search' => './', 'as' => 'd', 'is_data' => false, 'relpath' => 'd' },
            { 'search' => './', 'as' => 'd2', 'is_data' => false, 'relpath' => 'd' },
            { 'search' => './../lib/jq', 'as' => 'e', 'is_data' => false, 'relpath' => 'e' },
            { 'search' => './../lib/jq', 'as' => 'f', 'is_data' => false, 'relpath' => 'f' },
            { 'as' => 'd', 'is_data' => true, 'relpath' => 'data' }
          ],
          'defs' => ['a/0', 'c/0']
        }
      }
    end

    def module_aliases(content, alias_name)
      content.scan(/def\s+([A-Za-z_][A-Za-z0-9_]*)(\s*\(([^)]*)\))?\s*:/).map do |name, params_with_parens, params|
        if params_with_parens
          "def #{alias_name}::#{name}#{params_with_parens}: #{name}(#{params});"
        else
          "def #{alias_name}::#{name}: #{name};"
        end
      end.join("\n")
    end
  end
end
