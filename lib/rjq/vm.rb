# frozen_string_literal: true

module Rjq
  class VM
    class InstructionBudget
      attr_reader :maximum

      def initialize(maximum)
        @maximum = maximum
        @count = 0
      end

      def charge!
        return unless @maximum

        @count += 1
        raise ResourceLimitError, "instruction limit exceeded (#{@maximum})" if @count > @maximum
      end
    end

    class RecordingInputQueue
      attr_reader :current_record

      def initialize(queue)
        @queue = queue
        @records = []
      end

      def empty?
        @queue.empty?
      end

      def shift_record
        @current_record = @queue.shift_record
        @records << @current_record if @current_record
        @current_record
      end

      def shift
        shift_record&.value
      end

      def each_remaining
        return enum_for(:each_remaining) unless block_given?

        yield shift until empty?
      end

      def playback
        Runtime::InputQueue.new(@records)
      end
    end

    def initialize(program, opts = {}, instruction_budget: nil)
      @program = program
      @opts = opts
      @instruction_budget = instruction_budget || InstructionBudget.new(opts[:max_instructions])
    end

    def run(input_value)
      Enumerator.new do |yielder|
        @call_depth = 0
        Value.validate!(input_value)
        @opts.fetch(:variables, {}).each_value { |value| Value.validate!(value) }
        context = context_with_definitions(base_context)
        output_count = 0
        begin
          each_block(@program.program.instructions, input_value, context).each do |value|
            output_count += 1
            max_outputs = @opts[:max_outputs]
            raise RuntimeError, "output limit exceeded (#{max_outputs})" if max_outputs && output_count > max_outputs

            yielder << value
          end
        rescue ErrorValue => e
          Array(e.outputs).each { |value| yielder << value }
          raise
        rescue SystemStackError
          raise ResourceLimitError, 'execution recursion exceeded the host stack limit'
        end
      end
    end

    def execute_block(instructions, input, context)
      output = []
      each_block(instructions, input, context) { |value| output << value }
      output
    rescue Rjq::RuntimeError => e
      raise e.prepend_outputs(output)
    rescue BreakSignal => e
      raise BreakSignal.new(e.label, e.value, outputs: output + Array(e.outputs))
    end

    def take_block(instructions, input, context, count)
      return [] if count <= 0

      each_block(instructions, input, context).take(count)
    end

    def paths_for_block(instructions, input, context)
      stack = []
      instructions.each_with_index do |instruction, index|
        execute_path_instruction(instruction, stack, input, context)
      rescue Rjq::RuntimeError => e
        remaining = instructions[(index + 1)..].to_a
        raise if remaining.empty?

        if e.is_a?(InvalidPathError)
          raise InvalidPathError.new(invalid_path_message(remaining, e.result, input, context), e.result,
                                     outputs: e.outputs)
        end
        raise
      end
      stack.pop || []
    end

    def source_any?(instructions, input, context, &)
      each_block(instructions, input, context).any?(&)
    end

    def source_all?(instructions, input, context, &)
      each_block(instructions, input, context).all?(&)
    end

    def replacement_filters(block, captured_context)
      if block.instructions.last&.op == :append
        left = BytecodeBlock.new(instructions: block.instructions[0...-1])
        right = block.instructions.last.arg1
        return replacement_filters(left, captured_context) + replacement_filters(right, captured_context)
      end

      [BytecodeFilter.new(self, block, captured_context: captured_context)]
    end

    def stream_block(block, input, context)
      each_block(block.instructions, input, context)
    end

    private

    def base_context
      AST::Context.new(
        variables: @program.program.module_variables.merge(@opts.fetch(:variables, {})),
        functions: {},
        options: @opts.merge(module_metadata: @program.program.module_metadata)
      )
    end

    def context_with_definitions(context, definitions = @program.program.definitions)
      definitions.reduce(context) { |ctx, definition| apply_definition(ctx, definition) }
    end

    def apply_definition(context, definition)
      closed = definition.with_closure(context.functions)
      context_with_self = context.with_function(definition.name, definition.params.length, closed)
      context_with_self.with_function(
        definition.name,
        definition.params.length,
        definition.with_closure(context_with_self.functions)
      )
    end

    def execute_filter(block, input, context)
      execute_block(block.instructions, input, context)
    end

    def each_block(instructions, input, context, &block)
      return enum_for(:each_block, instructions, input, context) unless block

      stack = []
      instructions.each { |instruction| execute_stream_instruction(instruction, stack, input, context) }
      (stack.pop || empty_stream).each(&block)
    end

    def execute_stream_instruction(instruction, stack, input, context)
      charge_instruction!
      case instruction.op
      when :load_input then stack << value_stream(input)
      when :load_const then stack << value_stream(Value.deep_copy(@program.program.constants.fetch(instruction.arg1)))
      when :string_interp then stack << values_stream(evaluate_string(instruction.arg1, input, context))
      when :format then stack << values_stream(evaluate_format(instruction.arg1, instruction.arg2, input, context))
      when :variable then stack << values_stream(evaluate_variable(instruction.arg1, context, instruction.loc))
      when :field then stack << map_stream(stack.pop) { |value| read_field(value, instruction.arg1) }
      when :index_const then stack << map_stream(stack.pop) { |value| read_index(value, instruction.arg1) }
      when :index_filter then stack << index_filter_stream(stack.pop, instruction.arg1, input, context)
      when :slice_const then stack << map_stream(stack.pop) do |value|
        read_slice(value, instruction.arg1, instruction.arg2)
      end
      when :slice_filter then stack << slice_filter_stream(stack.pop, instruction.arg1, input, context)
      when :each then stack << flat_map_stream(stack.pop) { |value| values_stream(each_value(value)) }
      when :path then stack << path_stream(instruction.arg1, input, context)
      when :optional then stack << optional_stream(instruction.arg1, input, context)
      when :pipe then stack << pipe_stream(stack.pop, instruction.arg1, context)
      when :append then stack << concat_stream(stack.pop, each_block(instruction.arg1.instructions, input, context))
      when :binding then stack << binding_stream(instruction.arg1, input, context)
      when :array then stack << array_stream(instruction.arg1, input, context)
      when :object then stack << object_stream(instruction.arg1, input, context)
      when :branch then stack << branch_stream(instruction, input, context)
      when :try then stack << try_stream(instruction.arg1, input, context)
      when :reduce then stack << reduce_stream(instruction.arg1, input, context)
      when :foreach then stack << foreach_stream(instruction.arg1, input, context)
      when :label then stack << label_stream(instruction.arg1, instruction.arg2, input, context)
      when :break then raise BreakSignal, instruction.arg1
      when :unary then stack << unary_stream(instruction.arg1, instruction.arg2, input, context)
      when :binary then stack << binary_stream(instruction.arg1, instruction.arg2, input, context)
      when :assign then stack << assignment_stream(instruction.arg1, input, context)
      when :call then stack << call_stream(instruction, input, context)
      when :tail_call then stack << call_stream(instruction, input, context, tail: true)
      when :recurse then stack << recurse_stream(input)
      when :scoped_def then stack << each_block(instruction.arg2.instructions, input,
                                                apply_definition(context, instruction.arg1))
      else raise "unknown opcode #{instruction.op}"
      end
    end

    def empty_stream
      values_stream([])
    end

    def value_stream(value)
      values_stream([value])
    end

    def values_stream(values)
      Enumerator.new { |yielder| values.each { |value| yielder << value } }
    end

    def deferred_values_stream
      Enumerator.new do |yielder|
        yield.each { |value| yielder << value }
      end
    end

    def map_stream(stream)
      Enumerator.new do |yielder|
        stream.each { |value| yielder << yield(value) }
      end
    end

    def flat_map_stream(stream)
      Enumerator.new do |yielder|
        stream.each do |value|
          yield(value).each { |item| yielder << item }
        end
      end
    end

    def concat_stream(left, right)
      Enumerator.new do |yielder|
        left.each { |value| yielder << value }
        right.each { |value| yielder << value }
      end
    end

    def index_filter_stream(values, block, input, context)
      indices = replayable_stream(each_block(block.instructions, input, context))
      flat_map_stream(values) { |value| map_stream(indices.call) { |index| read_index(value, index) } }
    end

    def slice_filter_stream(values, spec, input, context)
      Enumerator.new do |yielder|
        starts = spec[:start] ? each_block(spec.fetch(:start).instructions, input, context).to_a : [nil]
        finishes = spec[:finish] ? each_block(spec.fetch(:finish).instructions, input, context).to_a : [nil]
        values.each do |value|
          starts.each do |start_index|
            finishes.each { |finish_index| yielder << read_slice(value, start_index, finish_index) }
          end
        end
      end
    end

    def replayable_stream(stream)
      cache = []
      source = stream.to_enum
      exhausted = false
      failure = nil

      lambda do
        Enumerator.new do |yielder|
          index = 0
          loop do
            if index < cache.length
              yielder << cache.fetch(index)
              index += 1
              next
            end

            raise failure if failure
            break if exhausted

            begin
              value = source.next
              maximum = @opts[:max_replay_cache]
              if maximum && cache.length >= maximum
                raise ResourceLimitError, "replay cache limit exceeded (#{maximum})"
              end
              cache << value
              yielder << value
              index += 1
            rescue StopIteration
              exhausted = true
              break
            rescue StandardError => e
              failure = e
              raise
            end
          end
        end
      end
    end

    def optional_stream(block, input, context)
      Enumerator.new do |yielder|
        source = each_block(block.instructions, input, context).to_enum
        loop do
          value =
            begin
              source.next
            rescue StopIteration
              break
            rescue ResourceLimitError
              raise
            rescue Rjq::RuntimeError
              break
            end
          yielder << value
        end
      end
    end

    def path_stream(block, input, context)
      Enumerator.new do |yielder|
        paths_for_block(block.instructions, input, context).each { |path| yielder << path }
      rescue Rjq::RuntimeError => e
        Array(e.outputs).each { |path| yielder << path }
        raise
      end
    end

    def array_stream(block, input, context)
      Enumerator.new do |yielder|
        yielder << (block ? each_block(block.instructions, input, context).to_a : [])
      end
    end

    def pipe_stream(values, block, context)
      flat_map_stream(values) { |value| each_block(block.instructions, value, context) }
    end

    def binding_stream(spec, input, context)
      flat_map_stream(each_block(spec.fetch(:source).instructions, input, context)) do |value|
        bound = AST.bind_pattern(context, spec.fetch(:pattern), value)
        bound ? each_block(spec.fetch(:body).instructions, input, bound) : empty_stream
      end
    end

    def object_stream(pairs, input, context)
      Enumerator.new do |yielder|
        emit_object_pair(pairs, 0, {}, input, context, yielder)
      end
    end

    def emit_object_pair(pairs, index, object, input, context, yielder)
      if index >= pairs.length
        yielder << object
        return
      end

      pair = pairs.fetch(index)
      object_key_stream(pair.fetch(:key), input, context).each do |key|
        each_block(pair.fetch(:value).instructions, input, context) do |value|
          emit_object_pair(pairs, index + 1, object.merge(key.to_s => value), input, context, yielder)
        end
      end
    end

    def object_key_stream(key, input, context)
      return value_stream(key.fetch(:value)) if key.fetch(:type) == :literal

      map_stream(each_block(key.fetch(:block).instructions, input, context)) { |value| object_key(value) }
    end

    def branch_stream(instruction, input, context)
      then_block, else_block = instruction.arg2
      flat_map_stream(each_block(instruction.arg1.instructions, input, context)) do |value|
        each_block((Value.truthy?(value) ? then_block : else_block).instructions, input, context)
      end
    end

    def try_stream(spec, input, context)
      Enumerator.new do |yielder|
        source = each_block(spec.fetch(:body).instructions, input, context).to_enum
        loop do
          value =
            begin
              source.next
            rescue StopIteration
              break
            rescue Rjq::ErrorValue => e
              Array(e.outputs).each { |item| yielder << item }
              if spec[:handler]
                each_block(spec.fetch(:handler).instructions, e.value, context).each do |item|
                  yielder << item
                end
              end
              break
            rescue Rjq::ResourceLimitError
              raise
            rescue Rjq::RuntimeError => e
              if spec[:handler]
                each_block(spec.fetch(:handler).instructions, e.message, context).each do |item|
                  yielder << item
                end
              end
              break
            end
          yielder << value
        end
      end
    end

    def reduce_stream(spec, input, context)
      Enumerator.new do |yielder|
        each_block(spec.fetch(:initial).instructions, input, context).each do |initial|
          accumulator = initial
          each_block(spec.fetch(:generator).instructions, input, context).each do |value|
            ctx = AST.bind_pattern(context, spec.fetch(:pattern), value)
            next unless ctx
            did_update = false
            each_block(spec.fetch(:update).instructions, accumulator, ctx).each do |next_accumulator|
              did_update = true
              accumulator = next_accumulator
            end
            accumulator = nil unless did_update
          end
          yielder << accumulator
        end
      end
    end

    def foreach_stream(spec, input, context)
      Enumerator.new do |yielder|
        each_block(spec.fetch(:initial).instructions, input, context).each do |initial|
          accumulator = initial
          each_block(spec.fetch(:generator).instructions, input, context).each do |value|
            ctx = AST.bind_pattern(context, spec.fetch(:pattern), value)
            next unless ctx
            did_update = false
            each_block(spec.fetch(:update).instructions, accumulator, ctx).each do |next_accumulator|
              did_update = true
              accumulator = next_accumulator
              values = if spec[:extract]
                         each_block(spec.fetch(:extract).instructions, next_accumulator, ctx)
                       else
                         value_stream(next_accumulator)
                       end
              values.each { |item| yielder << item }
            end
            accumulator = nil unless did_update
          rescue BreakSignal => e
            raise BreakSignal.new(e.label, e.value, outputs: e.outputs)
          end
        end
      end
    end

    def label_stream(label, block, input, context)
      Enumerator.new do |yielder|
        source = each_block(block.instructions, input, context).to_enum
        loop do
          value =
            begin
              source.next
            rescue StopIteration
              break
            rescue BreakSignal => e
              raise unless e.label == label

              if e.outputs
                e.outputs.each { |item| yielder << item }
              elsif !e.value.nil?
                yielder << e.value
              end
              break
            end
          yielder << value
        end
      end
    end

    def unary_stream(op, block, input, context)
      map_stream(each_block(block.instructions, input, context)) { |value| apply_unary(op, value) }
    end

    def binary_stream(op, blocks, input, context)
      return alternative_stream(blocks, input, context) if op == '//'
      return boolean_stream(op, blocks, input, context) if %w[and or].include?(op)

      flat_map_stream(each_block(blocks[1].instructions, input, context)) do |right|
        map_stream(each_block(blocks[0].instructions, input, context)) { |left| apply_binary(op, left, right) }
      end
    end

    def alternative_stream(blocks, input, context)
      Enumerator.new do |yielder|
        found = false
        each_block(blocks[0].instructions, input, context).each do |value|
          next unless Value.truthy?(value)

          found = true
          yielder << value
        end
        each_block(blocks[1].instructions, input, context).each { |value| yielder << value } unless found
      end
    end

    def boolean_stream(op, blocks, input, context)
      flat_map_stream(each_block(blocks[0].instructions, input, context)) do |left|
        if (op == 'and' && !Value.truthy?(left)) || (op == 'or' && Value.truthy?(left))
          value_stream(op == 'or')
        else
          map_stream(each_block(blocks[1].instructions, input, context)) { |right| Value.truthy?(right) }
        end
      end
    end

    def assignment_stream(spec, input, context)
      return deferred_values_stream { execute_assignment(spec, input, context) } if spec.fetch(:op) == '|='

      assignment_rhs_stream(spec, input, context)
    end

    def assignment_rhs_stream(spec, input, context)
      flat_map_stream(each_block(spec.fetch(:right).instructions, input, context)) do |rhs|
        value_stream(execute_assignment_with_rhs(spec, input, context, rhs))
      end
    end

    def call_stream(instruction, input, context, tail: false)
      name = instruction.arg1
      arg_blocks = instruction.arg2

      if arg_blocks.empty? && context.variables[filter_variable_name(name)].is_a?(BytecodeFilter)
        return context.variables[filter_variable_name(name)].stream(input, context)
      end

      if context.functions.key?([name, arg_blocks.length])
        definition = context.functions.fetch([name, arg_blocks.length])
        return value_stream(TailCall.new(input: input, context: context, definition: definition,
                                         arg_blocks: arg_blocks)) if tail

        return user_function_stream(input, context, definition, arg_blocks)
      end

      builtin_args = arg_blocks.map { |block| BytecodeFilter.new(self, block) }
      deferred_values_stream { Builtins.call_stream(name, input, context, builtin_args) }
    end

    def user_function_stream(input, context, definition, arg_blocks)
      Enumerator.new do |yielder|
        with_call_frame do
          stack = []
          push_tail_contexts(stack, input, call_contexts(input, context, definition, arg_blocks), definition)
          until stack.empty?
            begin
              value = stack.last.next
              if value.is_a?(TailCall)
                contexts = call_contexts(value.input, value.context, value.definition, value.arg_blocks)
                push_tail_contexts(stack, value.input, contexts, value.definition)
              else
                yielder << value
              end
            rescue StopIteration
              stack.pop
            end
          end
        end
      end
    end

    def push_tail_contexts(stack, input, contexts, definition)
      contexts.reverse_each do |ctx|
        stack << each_block(definition.body.instructions, input, ctx).to_enum
      end
    end

    def with_call_frame
      @call_depth += 1
      max_depth = @opts.fetch(:max_call_depth, Runtime::DEFAULT_OPTIONS.fetch(:max_call_depth))
      raise ResourceLimitError, "call depth limit exceeded (#{max_depth})" if max_depth && @call_depth > max_depth

      yield
    ensure
      @call_depth -= 1
    end

    def charge_instruction!
      @instruction_budget.charge!
    end

    def recurse_stream(input)
      Enumerator.new do |yielder|
        stack = [input]
        until stack.empty?
          value = stack.pop
          yielder << value
          children = value.is_a?(Array) ? value : value.is_a?(Hash) ? value.values : []
          stack.concat(children.reverse)
        end
      end
    end

    def object_key(value)
      return value if value.is_a?(String)

      raise TypeError, "Cannot use #{Value.type_of(value)} (#{short_dump(value)}) as object key"
    end

    def execute_assignment(spec, input, context)
      spec.fetch(:op) == '=' ? assign(spec, input, context) : update(spec, input, context)
    end

    def execute_assignment_with_rhs(spec, input, context, rhs)
      return assign_value(spec.fetch(:left).instructions, Value.deep_copy(input), input, context, rhs) if spec.fetch(:op) == '='

      update_with_rhs(spec, input, context, rhs)
    end

    def update_with_rhs(spec, input, context, rhs)
      copy = Value.deep_copy(input)
      paths_for_block(spec.fetch(:left).instructions, input, context).each do |path|
        current = Path.get(copy, path)
        value = if spec.fetch(:op) == '//='
                  Value.truthy?(current) ? current : rhs
                else
                  apply_binary(spec.fetch(:op).delete_suffix('='), current, rhs)
                end
        copy = Path.set(copy, path, value)
      end
      copy
    end

    def assign(spec, input, context)
      values = execute_filter(spec.fetch(:right), input, context)
      return [] if values.empty?

      values.map do |value|
        copy = Value.deep_copy(input)
        assign_value(spec.fetch(:left).instructions, copy, input, context, value)
      end
    end

    def update(spec, input, context)
      copy = Value.deep_copy(input)
      deletions = []
      paths_for_block(spec.fetch(:left).instructions, input, context).each do |path|
        current = Path.get(copy, path)
        value = update_value(spec.fetch(:op), spec.fetch(:right), current, input, context)
        return [] if value.equal?(AssignmentSentinel.no_output)

        if value.equal?(AssignmentSentinel.delete)
          deletions << path
        else
          copy = Path.set(copy, path, value)
        end
      end
      Builtins.ordered_delete_paths(deletions.uniq).each do |path|
        Path.delete(copy, path)
      end
      [copy]
    end

    def update_value(op, right, current, input, context)
      if op == '|='
        values = take_block(right.instructions, current, context, 1)
        return AssignmentSentinel.delete if values.empty?

        return values.first
      end

      values = execute_filter(right, input, context)
      return AssignmentSentinel.no_output if values.empty?
      return Value.truthy?(current) ? current : values.first if op == '//='

      apply_binary(op.delete_suffix('='), current, values.first)
    end

    def assign_value(instructions, copy, input, context, value)
      return assign_slice(instructions, copy, input, context, value) if slice_assignment?(instructions)

      paths_for_block(instructions, input, context).each { |path| copy = Path.set(copy, path, value) }
      copy
    end

    def slice_assignment?(instructions)
      %i[slice_const slice_filter].include?(instructions.last&.op)
    end

    def assign_slice(instructions, copy, input, context, replacement)
      base = instructions[0...-1]
      slice = instructions.last
      paths_for_block(base, input, context).each do |path|
        slice_bounds(slice, input, context).each do |start_index, finish_index|
          target = Path.get(copy, path)
          copy = Path.set(copy, path, replace_slice(target, start_index, finish_index, replacement))
        end
      end
      copy
    end

    def slice_bounds(slice, input, context)
      return [[slice.arg1, slice.arg2]] if slice.op == :slice_const

      starts = slice.arg1[:start] ? execute_filter(slice.arg1.fetch(:start), input, context) : [nil]
      finishes = slice.arg1[:finish] ? execute_filter(slice.arg1.fetch(:finish), input, context) : [nil]
      starts.product(finishes)
    end

    def call_builtin_or_function(instruction, input, context)
      name = instruction.arg1
      arg_blocks = instruction.arg2

      if arg_blocks.empty? && context.variables[filter_variable_name(name)].is_a?(BytecodeFilter)
        return context.variables[filter_variable_name(name)].eval(input, context)
      end

      if context.functions.key?([name, arg_blocks.length])
        return execute_user_function(input, context, context.functions.fetch([name, arg_blocks.length]), arg_blocks)
      end

      Builtins.call(name, input, context, arg_blocks.map { |block| BytecodeFilter.new(self, block) })
    end

    def execute_user_function(input, context, definition, arg_blocks)
      call_contexts(input, context, definition, arg_blocks).flat_map do |ctx|
        execute_filter(definition.body, input, ctx)
      end
    end

    def call_contexts(input, context, definition, arg_blocks)
      functions = (definition.closure || context.functions).merge([definition.name,
                                                                   definition.params.length] => definition)
      contexts = [context.with_functions(functions)]
      definition.params.zip(arg_blocks).each do |param, block|
        if param.start_with?('$')
          values = execute_filter(block, input, context)
          contexts = contexts.flat_map do |ctx|
            values.map do |value|
              ctx.with_variable(param.delete_prefix('$'), value)
            end
          end
        else
          filter = forwarded_filter(block, context) || BytecodeFilter.new(self, block, captured_context: context)
          contexts = contexts.map { |ctx| ctx.with_variable(filter_variable_name(param), filter) }
        end
      end
      contexts
    end

    def forwarded_filter(block, context)
      return unless block.instructions.length == 1

      instruction = block.instructions.first
      return unless %i[call tail_call].include?(instruction.op) && instruction.arg2.empty?

      context.variables[filter_variable_name(instruction.arg1)].then do |filter|
        filter if filter.is_a?(BytecodeFilter)
      end
    end

    def evaluate_variable(name, context, loc = nil)
      return [ENV.to_h] if name == 'ENV'

      if name == 'ARGS'
        positional = context.variables.fetch('ARGS.positional', [])
        named = context.variables.fetch('ARGS.named', {})
        return [{ 'positional' => positional, 'named' => named }]
      end
      if name == '__loc__'
        return [{ 'file' => loc&.filename || context.options.fetch(:source_path, '<top-level>'),
                  'line' => loc&.line || 1 }]
      end

      raise RuntimeError, "variable $#{name} is not defined" unless context.variables.key?(name)

      [context.variables[name]]
    end

    def evaluate_string(segments, input, context)
      segments.reduce(['']) do |prefixes, segment|
        suffixes =
          if segment.fetch(:kind) == :text
            [segment.fetch(:value)]
          else
            ctx = context_with_definitions(context, segment.fetch(:definitions))
            execute_filter(segment.fetch(:block), input, ctx).map { |item| Builtins.to_string(item) }
          end
        prefixes.flat_map { |prefix| suffixes.map { |suffix| prefix + suffix } }
      end
    end

    def evaluate_format(name, spec, input, context)
      return Builtins.call(name, input, context, []) unless spec

      if spec[:segments]
        return spec.fetch(:segments).reduce(['']) do |prefixes, segment|
          suffixes = format_segment(name, segment, input, context)
          prefixes.flat_map { |prefix| suffixes.map { |suffix| prefix + suffix } }
        end
      end

      execute_filter(spec.fetch(:block), input, context).flat_map { |value| Builtins.call(name, value, context, []) }
    end

    def format_segment(name, segment, input, context)
      return [segment.fetch(:value)] if segment.fetch(:kind) == :text

      ctx = context_with_definitions(context, segment.fetch(:definitions))
      execute_filter(segment.fetch(:block), input, ctx).map do |item|
        Builtins.to_string(Builtins.call(name, item, context, []).first)
      end
    end

    def execute_path_instruction(instruction, stack, input, context)
      charge_instruction!
      case instruction.op
      when :load_input then stack << [context.current_path]
      when :variable
        if context.binding_variable_paths.key?(instruction.arg1)
          stack << [context.binding_variable_paths.fetch(instruction.arg1)]
        else
          result = execute_block([instruction], input, context).first
          raise InvalidPathError.new(invalid_path_message([instruction], result, input, context), result)
        end
      when :field then stack << stack.pop.map { |path| path + [instruction.arg1] }
      when :index_const then stack << stack.pop.map do |path|
        path + [path_index(Path.get(input, path), instruction.arg1)]
      end
      when :index_filter then stack << index_filter_paths(stack.pop, instruction.arg1, input, context)
      when :slice_const then stack << slice_paths(stack.pop, input, instruction.arg1, instruction.arg2)
      when :slice_filter then stack << slice_filter_paths(stack.pop, instruction.arg1, input, context)
      when :each then stack << each_paths(stack.pop, input)
      when :pipe then stack << pipe_paths(stack.pop, instruction.arg1, input, context)
      when :append
        left = stack.pop
        begin
          stack << (left + paths_for_block(instruction.arg1.instructions, input, context))
        rescue Rjq::RuntimeError => e
          raise e.prepend_outputs(left)
        end
      when :binding then stack << binding_paths(instruction.arg1, input, context)
      when :branch then stack << branch_paths(instruction, input, context)
      when :optional then stack << optional_paths(instruction.arg1, input, context)
      when :call, :tail_call then stack << call_paths(instruction, input, context)
      when :recurse then stack << Path.paths(input, leaves_only: false)
      when :scoped_def then stack << paths_for_block(instruction.arg2.instructions, input,
                                                     apply_definition(context, instruction.arg1))
      else
        result = execute_block([instruction], input, context)
        result = result.first if result.length == 1
        raise InvalidPathError.new(invalid_path_message([instruction], result, input, context), result)
      end
    end

    def index_filter_paths(paths, block, input, context)
      indices = execute_filter(block, input, context)
      paths.flat_map { |path| indices.map { |index| path + [path_index(Path.get(input, path), index)] } }
    end

    def slice_paths(paths, input, start_index, finish_index)
      paths.map { |path| path + [{ 'start' => start_index, 'end' => finish_index }] }
    end

    def slice_filter_paths(paths, spec, input, context)
      starts = spec[:start] ? execute_filter(spec.fetch(:start), input, context) : [nil]
      finishes = spec[:finish] ? execute_filter(spec.fetch(:finish), input, context) : [nil]
      starts.product(finishes).flat_map do |start_index, finish_index|
        slice_paths(paths, input, start_index, finish_index)
      end
    end

    def each_paths(paths, input)
      paths.flat_map do |path|
        value = Path.get(input, path)
        keys =
          case value
          when Array then (0...value.length).to_a
          when Hash then value.keys
          else raise TypeError, "cannot iterate over #{Value.type_of(value)}"
          end
        keys.map { |key| path + [key] }
      end
    rescue InvalidPathError => e
      raise InvalidPathError.new(invalid_path_message([Instruction.new(op: :each)], e.result, input, nil), e.result)
    end

    def pipe_paths(paths, block, input, context)
      paths.flat_map do |path|
        value = Path.get(input, path)
        nested = context.with_path_state(current_path: [])
        paths_for_block(block.instructions, value, nested).map { |suffix| path + suffix }
      end
    rescue InvalidPathError => e
      raise InvalidPathError.new(invalid_path_message(block.instructions, e.result, input, context), e.result)
    end

    def binding_paths(spec, input, context)
      execute_filter(spec.fetch(:source), input, context).flat_map do |value|
        pattern = spec.fetch(:pattern)
        candidates = pattern[0] == :alternatives ? pattern[1] : [pattern]
        candidate_index = 0
        validated = []
        loop do
          candidate = candidates.fetch(candidate_index)
          begin
            bound, pattern_path, relative_variables =
              AST.bind_pattern_candidate_with_path(context, pattern, candidate, value)
          rescue Rjq::RuntimeError => e
            candidate_index += 1
            next if candidate_index < candidates.length

            raise e.prepend_outputs(validated)
          end

          base_path = context.current_path + pattern_path
          variable_paths = context.binding_variable_paths.to_h { |name, _path| [name, base_path] }
          variable_paths.merge!(relative_variables.transform_values { |path| context.current_path + path })
          AST.validate_pattern_path(input, base_path)
          scoped = bound.with_path_state(current_path: base_path, variables: variable_paths)
          results, paths, error = execute_with_replayed_paths(spec.fetch(:body), input, scoped)

          if candidates[(candidate_index + 1)..].to_a.any? { |item| item[0] == :var }
            paths = paths.each_with_index.map do |path, index|
              path == base_path && !AST.binding_path_matches?(input, path, results[index]) ? context.current_path : path
            end
          end

          missing_names = AST.pattern_variable_names(pattern) - AST.pattern_variable_names(candidate)
          missing_paths = missing_names.filter_map { |name| variable_paths[name] }
          switch_at = paths.index { |path| path != base_path && missing_paths.include?(path) } unless value.nil?
          if switch_at && candidate_index + 1 < candidates.length
            begin
              validated.concat(AST.validate_binding_results(input, results.first(switch_at), paths.first(switch_at)))
            rescue Rjq::RuntimeError => e
              raise e.prepend_outputs(validated)
            end
            candidate_index += 1
            next
          end

          begin
            validated.concat(AST.validate_binding_results(input, results, paths))
          rescue Rjq::RuntimeError => e
            raise e.prepend_outputs(validated)
          end
          raise error.prepend_outputs(validated) if error

          break validated
        end
      end
    end

    def execute_with_replayed_paths(block, input, context)
      queue = context.options[:input_queue]
      recording = queue && RecordingInputQueue.new(queue)
      first_context = recording ? context.with_options(context.options.merge(input_queue: recording,
                                                                              remaining_inputs: recording)) : context
      values = []
      error = nil
      begin
        values = execute_filter(block, input, first_context)
      rescue Rjq::RuntimeError => e
        values = e.take_outputs
        error = e
      end

      playback = recording&.playback
      second_context = playback ? context.with_options(context.options.merge(input_queue: playback,
                                                                              remaining_inputs: playback)) : context
      paths = []
      begin
        paths = paths_for_block(block.instructions, input, second_context)
      rescue Rjq::RuntimeError => e
        paths = e.take_outputs
        error ||= e
      end
      [values, paths, error]
    end

    def branch_paths(instruction, input, context)
      then_block, else_block = instruction.arg2
      execute_filter(instruction.arg1, input, context).flat_map do |value|
        paths_for_block((Value.truthy?(value) ? then_block : else_block).instructions, input, context)
      end
    end

    def optional_paths(block, input, context)
      paths_for_block(block.instructions, input, context)
    rescue Rjq::ResourceLimitError
      raise
    rescue Rjq::RuntimeError
      []
    end

    def call_paths(instruction, input, context)
      name = instruction.arg1
      arg_blocks = instruction.arg2
      return [context.current_path] if %w[debug stderr].include?(name)
      if name == 'select' && arg_blocks.length == 1
        return execute_filter(arg_blocks.first, input, context).filter_map { |value| [] if Value.truthy?(value) }
      end
      return [] if (name == 'select' && arg_blocks.length == 1) || (name == 'empty' && arg_blocks.empty?)
      return [[0]] if name == 'first' && arg_blocks.empty?
      return [[-1]] if name == 'last' && arg_blocks.empty?
      if name == 'getpath' && arg_blocks.length == 1
        return arg_blocks.first.then do |block|
          execute_filter(block, input, context).map do |path|
            Array(path)
          end
        end
      end

      if arg_blocks.empty? && context.variables[filter_variable_name(name)].is_a?(BytecodeFilter)
        return context.variables[filter_variable_name(name)].paths(input, context)
      end

      if context.functions.key?([name, arg_blocks.length])
        definition = context.functions.fetch([name, arg_blocks.length])
        return with_call_frame do
          call_contexts(input, context, definition, arg_blocks).flat_map do |ctx|
            paths_for_block(definition.body.instructions, input, ctx)
          end
        end
      end

      result = call_builtin_or_function(instruction, input, context)
      return [] if result.empty?

      result = result.first if result.length == 1
      raise InvalidPathError.new(invalid_path_message([instruction], result, input, context), result)
    end

    def invalid_path_message(instructions, result, input, context)
      instruction = instructions.find { |item| item.op != :load_input }
      return "Invalid path expression with result #{JSON::Dumper.dump(result, indent: nil)}" unless instruction

      case instruction.op
      when :field
        "Invalid path expression near attempt to access element #{instruction.arg1.inspect} of #{JSON::Dumper.dump(
          result, indent: nil
        )}"
      when :index_const
        "Invalid path expression near attempt to access element #{JSON::Dumper.dump(instruction.arg1,
                                                                                    indent: nil)} of #{JSON::Dumper.dump(
                                                                                      result, indent: nil
                                                                                    )}"
      when :index_filter
        index = execute_filter(instruction.arg1, input, context).first
        "Invalid path expression near attempt to access element #{JSON::Dumper.dump(index,
                                                                                    indent: nil)} of #{JSON::Dumper.dump(
                                                                                      result, indent: nil
                                                                                    )}"
      when :each
        "Invalid path expression near attempt to iterate through #{JSON::Dumper.dump(result, indent: nil)}"
      when :pipe
        invalid_path_message(instruction.arg1.instructions, result, input, context)
      else
        "Invalid path expression with result #{JSON::Dumper.dump(result, indent: nil)}"
      end
    end

    def apply_unary(op, value)
      case op
      when '-'
        raise TypeError, "#{Value.type_of(value)} (#{short_dump(value)}) cannot be negated" unless value.is_a?(Numeric)

        return -0.0 if value.zero?

        value * -1
      when 'not'
        !Value.truthy?(value)
      else
        raise "unknown unary operator #{op}"
      end
    end

    def apply_binary(op, left, right)
      case op
      when '+' then add_values(left, right)
      when '-' then subtract_values(left, right)
      when '*' then multiply_values(left, right)
      when '/' then divide_values(left, right)
      when '%' then modulo_values(left, right)
      when '==' then Value.equal?(left, right)
      when '!=' then !Value.equal?(left, right)
      when '<' then Value.compare(left, right).negative?
      when '<=' then Value.compare(left, right) <= 0
      when '>' then Value.compare(left, right).positive?
      when '>=' then Value.compare(left, right) >= 0
      else raise "unknown operator #{op}"
      end
    end

    def add_values(left, right)
      return right if left.nil?
      return left if right.nil?
      return numeric_pair(left, right).then { |a, b| a + b } if left.is_a?(Numeric) && right.is_a?(Numeric)
      return left + right if left.is_a?(String) && right.is_a?(String)
      return left + right if left.is_a?(Array) && right.is_a?(Array)
      return left.merge(right) if left.is_a?(Hash) && right.is_a?(Hash)

      raise TypeError, "#{Value.type_of(left)} and #{Value.type_of(right)} cannot be added"
    end

    def subtract_values(left, right)
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

    def multiply_values(left, right)
      return numeric_pair(left, right).then { |a, b| a * b } if left.is_a?(Numeric) && right.is_a?(Numeric)
      return repeat_string(left, right) if left.is_a?(String) && right.is_a?(Numeric)
      return repeat_string(right, left) if right.is_a?(String) && left.is_a?(Numeric)
      return recursive_merge(left, right) if left.is_a?(Hash) && right.is_a?(Hash)

      raise TypeError, "#{Value.type_of(left)} and #{Value.type_of(right)} cannot be multiplied"
    end

    def divide_values(left, right)
      if left.is_a?(String) && right.is_a?(String)
        return left.each_char.to_a if right.empty?

        return left.split(right, -1)
      end

      left_number, right_number = numeric_pair(numeric(left), numeric(right))
      raise TypeError, division_by_zero_message(left_number, right_number, 'divided') if right_number.zero?

      left_number.fdiv(right_number)
    end

    def modulo_values(left, right)
      left_number, right_number = numeric_pair(numeric(left), numeric(right))
      return Float::NAN if nan_number?(left_number) || nan_number?(right_number)

      left_integer = jq_integer(left_number)
      right_integer = jq_integer(right_number)
      raise TypeError, division_by_zero_message(left_number, right_number, 'divided (remainder)') if right_integer.zero?

      remainder = left_integer.remainder(right_integer)
      if remainder.zero? && left_number.is_a?(Float) && left_number.zero? && (1.0 / left_number).negative?
        return -0.0
      end
      return remainder.to_f.round(-3) if (nonfinite_number?(left_number) || nonfinite_number?(right_number)) &&
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

    def replace_slice(target, start_index, finish_index, replacement)
      case target
      when Array
        raise TypeError, 'can only assign an array to an array slice' unless replacement.is_a?(Array)

        range = range_for(target.length, start_index, finish_index)
        target[0...range.begin] + Value.deep_copy(replacement) + target[range.end..].to_a
      when String
        raise TypeError, 'Cannot update string slices'
      else
        raise TypeError, "cannot slice #{Value.type_of(target)}"
      end
    end

    def read_field(value, name)
      return nil if value.nil?
      return value[name] if value.is_a?(Hash)

      raise TypeError, "Cannot index #{Value.type_of(value)} with string #{name.inspect}"
    end

    def read_index(value, index)
      Path.read_index(value, index)
    end

    def read_slice(value, start_index, finish_index)
      return nil if value.nil?

      case value
      when Array
        value[range_for(value.length, start_index, finish_index)] || []
      when String
        value.each_char.to_a[range_for(value.each_char.count, start_index, finish_index)].join
      else
        raise TypeError, "cannot slice #{Value.type_of(value)}"
      end
    end

    def each_value(value)
      case value
      when Array then value
      when Hash then value.values
      else raise TypeError, "Cannot iterate over #{Value.type_of(value)} (#{JSON::Dumper.dump(value, indent: nil)})"
      end
    end

    def path_index(value, index)
      unless index.is_a?(String) || index.is_a?(Numeric)
        raise TypeError, "Cannot index #{Value.type_of(value)} with #{Value.type_of(index)}"
      end
      return index unless index.is_a?(Numeric)
      return index if index.respond_to?(:nan?) && index.nan?
      if index.respond_to?(:infinite?) && index.infinite?
        raise RuntimeError, 'Out of bounds negative array index' if index.negative? && !value.is_a?(Hash)
        raise TypeError, "Cannot index #{Value.type_of(value)} with number"
      end

      index = index.floor
      return index unless index.negative?

      length =
        case value
        when Array then value.length
        when String then value.each_char.count
        else 0
        end
      normalized = length + index
      raise RuntimeError, 'Out of bounds negative array index' if normalized.negative?

      normalized
    end

    def range_for(length, start_index, finish_index)
      from = start_index.nil? || nan_number?(start_index) ? 0 : normalize_boundary(start_index, length, :floor)
      to = finish_index.nil? || nan_number?(finish_index) ? length : normalize_boundary(finish_index, length, :ceil)
      from...to
    end

    def normalize_boundary(index, length, rounding)
      raise TypeError, 'slice index must be a number' unless index.is_a?(Numeric)

      rounded = rounding == :ceil ? index.ceil : index.floor
      normalized = rounded.negative? ? length + rounded : rounded
      [[normalized, 0].max, length].min
    end

    def numeric(value)
      raise TypeError, "#{Value.type_of(value)} is not a number" unless value.is_a?(Numeric)

      value
    end

    def nan_number?(value)
      value.respond_to?(:nan?) && value.nan?
    end

    def short_dump(value)
      dumped = JSON::Dumper.dump(value, indent: nil)
      dumped.length > 14 ? "#{dumped[0, 11]}..." : dumped
    end

    def division_by_zero_message(left, right, verb)
      "number (#{left}) and number (#{right}) cannot be #{verb} because the divisor is zero"
    end

    def filter_variable_name(name)
      "filter:#{name}"
    end
  end

  module AssignmentSentinel
    module_function

    def delete
      @delete ||= Object.new.freeze
    end

    def no_output
      @no_output ||= Object.new.freeze
    end
  end

  class BytecodeFilter < AST::Node
    def initialize(vm, block, captured_context: nil)
      @vm = vm
      @block = block
      @captured_context = captured_context
    end

    def eval(input, context)
      @vm.execute_block(@block.instructions, input, @captured_context || context)
    end

    def stream(input, context)
      @vm.stream_block(@block, input, @captured_context || context)
    end

    def take(input, context, count)
      @vm.take_block(@block.instructions, input, @captured_context || context, count)
    end

    def paths(input, context)
      @vm.paths_for_block(@block.instructions, input, @captured_context || context)
    end

    def source_any?(input, context, &)
      @vm.source_any?(@block.instructions, input, @captured_context || context, &)
    end

    def source_all?(input, context, &)
      @vm.source_all?(@block.instructions, input, @captured_context || context, &)
    end

    def replacement_filters
      @vm.replacement_filters(@block, @captured_context)
    end
  end
end
