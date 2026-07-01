# frozen_string_literal: true

module Rjq
  class Runtime
    DEFAULT_OPTIONS = {
      compact: false,
      raw_output: false,
      raw_output0: false,
      join_output: false,
      null_input: false,
      raw_input: false,
      slurp: false,
      ascii: false,
      sort_keys: false,
      tab: false,
      indent: 2,
      seq: false,
      stream: false,
      stream_errors: false,
      unbuffered: false,
      variables: {}
    }.freeze

    def initialize(filter_string, opts = {})
      @filter_string = filter_string || '.'
      @opts = DEFAULT_OPTIONS.merge(opts)
      @program = Rjq.compile(@filter_string, @opts)
    end

    def run_values(values, input_queue: nil)
      Enumerator.new do |yielder|
        queue = values.to_a
        builtin_queue = input_queue || queue
        until queue.empty?
          value = queue.shift
          run_opts = @opts.merge(
            variables: @opts.fetch(:variables, {}),
            remaining_inputs: builtin_queue,
            input_queue: builtin_queue
          )
          @program.run(value, run_opts).each { |result| yielder << result }
        end
      end
    end

    def run_stream(io, &block)
      input_values = inputs_from_io(io)
      input_queue = @opts[:null_input] ? lazy_inputs_from_io(io) : nil
      enum = run_values(input_values, input_queue: input_queue)
      return enum unless block

      enum.each(&block)
    end

    def inputs_from_io(io)
      if @opts[:null_input]
        [nil]
      elsif @opts[:raw_input]
        raw_inputs(io)
      else
        json_inputs(io)
      end
    end

    def format_output(value)
      return value if @opts[:raw_output] && value.is_a?(String)

      indent = @opts[:compact] ? nil : @opts[:indent]
      dumped = JSON::Dumper.dump(value, indent: indent, sort_keys: @opts[:sort_keys], ascii: @opts[:ascii],
                                        tab: @opts[:tab])
      @opts[:color] ? Color.colorize(dumped) : dumped
    end

    private

    class LazyInputQueue
      def initialize(&loader)
        @loader = loader
        @loaded = false
        @values = []
      end

      def empty?
        values.empty?
      end

      def shift
        values.shift
      end

      def dup
        values.dup
      end

      def clear
        values.clear
      end

      private

      def values
        unless @loaded
          @values = @loader.call
          @loaded = true
        end
        @values
      end
    end

    def lazy_inputs_from_io(io)
      LazyInputQueue.new { @opts[:raw_input] ? raw_inputs(io) : json_inputs(io) }
    end

    def raw_inputs(io)
      if @opts[:slurp]
        [io.read]
      else
        io.each_line.map { |line| line.delete_suffix("\n").delete_suffix("\r") }
      end
    end

    def json_inputs(io)
      return JSON::StreamParser.parse(io.read, seq: @opts[:seq], stream_errors: @opts[:stream_errors]) if @opts[:stream]

      values = JSON::Parser.parse(io.read, seq: @opts[:seq]).to_a
      values = [values] if @opts[:slurp]
      values
    end
  end
end
