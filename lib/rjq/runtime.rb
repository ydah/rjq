# frozen_string_literal: true

module Rjq
  class Runtime
    DEFAULT_OPTIONS = {
      compact: false, raw_output: false, raw_output0: false, join_output: false,
      null_input: false, raw_input: false, slurp: false, ascii: false,
      sort_keys: false, tab: false, indent: 2, seq: false, stream: false,
      stream_errors: false, unbuffered: false, max_outputs: nil, variables: {}
    }.freeze
    OPTION_KEYS = (DEFAULT_OPTIONS.keys + %i[
      allow_comments color current_filename current_line exit_status input_chunk_size input_max_depth input_queue
      jq_origin library_path max_number_digits max_string_bytes module_resolver regexp_timeout remaining_inputs
      source_path stderr
    ]).freeze
    BOOLEAN_OPTIONS = %i[
      allow_comments ascii compact exit_status join_output null_input raw_input raw_output raw_output0 seq slurp
      sort_keys stream stream_errors tab unbuffered
    ].freeze

    class << self
      def validate_options!(opts)
        raise ArgumentError, 'options must be a Hash' unless opts.is_a?(Hash)

        unknown = opts.keys - OPTION_KEYS
        raise ArgumentError, "unknown runtime option: #{unknown.first.inspect}" unless unknown.empty?

        BOOLEAN_OPTIONS.each { |key| validate_boolean!(opts, key) }
        validate_color!(opts)
        validate_integer!(opts, :indent, minimum: 0, maximum: 7)
        validate_integer!(opts, :input_chunk_size, minimum: 1)
        validate_integer!(opts, :input_max_depth, minimum: 0)
        validate_integer!(opts, :current_line, minimum: 1, optional: true)
        validate_integer!(opts, :max_number_digits, minimum: 0, optional: true)
        validate_integer!(opts, :max_outputs, minimum: 0, optional: true)
        validate_integer!(opts, :max_string_bytes, minimum: 0, optional: true)
        validate_regexp_timeout!(opts)
        validate_stderr!(opts)
        validate_variables!(opts)
        Compiler.validate_options!(Compiler.options_from(opts))
        opts
      end

      def normalize_options(opts)
        validate_options!(opts)
        normalized = opts.dup
        normalized[:variables] = normalized[:variables].dup.freeze if normalized[:variables]
        normalized[:library_path] = normalized[:library_path].dup.freeze if normalized[:library_path]
        normalized.freeze
      end

      private

      def validate_boolean!(opts, key)
        return unless opts.key?(key)
        return if opts[key] == true || opts[key] == false

        raise ArgumentError, "#{key} must be true or false"
      end

      def validate_color!(opts)
        return unless opts.key?(:color)
        return if opts[:color].nil? || opts[:color] == true || opts[:color] == false

        raise ArgumentError, 'color must be true, false, or nil'
      end

      def validate_integer!(opts, key, minimum:, maximum: nil, optional: false)
        return unless opts.key?(key)
        return if optional && opts[key].nil?

        value = opts[key]
        valid = value.is_a?(Integer) && value >= minimum && (!maximum || value <= maximum)
        return if valid

        range = maximum ? "between #{minimum} and #{maximum}" : "at least #{minimum}"
        raise ArgumentError, "#{key} must be an Integer #{range}"
      end

      def validate_regexp_timeout!(opts)
        return unless opts.key?(:regexp_timeout)

        timeout = opts[:regexp_timeout]
        return if timeout.nil? || (timeout.is_a?(Numeric) && timeout.respond_to?(:finite?) && timeout.finite? &&
          timeout.respond_to?(:positive?) && timeout.positive?)

        raise ArgumentError, 'regexp_timeout must be a finite positive number or nil'
      end

      def validate_stderr!(opts)
        return unless opts.key?(:stderr)
        return if opts[:stderr].nil? || opts[:stderr].respond_to?(:puts)

        raise ArgumentError, 'stderr must be nil or respond to puts'
      end

      def validate_variables!(opts)
        return unless opts.key?(:variables)
        return if opts[:variables].is_a?(Hash)

        raise ArgumentError, 'variables must be a Hash'
      end
    end

    InputRecord = Struct.new(:value, :filename, :line, keyword_init: true)

    class ResultStream
      include Enumerable

      def initialize(on_close: nil, &producer)
        @producer = producer
        @on_close = on_close
        @closed = false
      end

      def each
        return enum_for(:each) unless block_given?

        begin
          @producer.call(->(value) { yield value })
        ensure
          close
        end
      end

      def close
        return if @closed

        @closed = true
        @on_close&.call
      end
    end

    class InputQueue
      END_OF_INPUT = Object.new.freeze

      attr_reader :current_record

      def initialize(records)
        @records = records.to_enum
        @next_record = nil
        @current_record = nil
      end

      def empty?
        peek.equal?(END_OF_INPUT)
      end

      def shift_record
        record = peek
        return if record.equal?(END_OF_INPUT)

        @next_record = nil
        @current_record = record
      end

      def shift
        shift_record&.value
      end

      def each_remaining
        return enum_for(:each_remaining) unless block_given?

        yield shift until empty?
      end

      def remaining_values
        each_remaining.to_a
      end

      private

      def peek
        return @next_record if @next_record

        @next_record = @records.next
      rescue StopIteration
        @next_record = END_OF_INPUT
      end
    end

    def initialize(filter_string, opts = {})
      @filter_string = filter_string || '.'
      @opts = self.class.normalize_options(DEFAULT_OPTIONS.merge(opts))
      @program = Rjq.compile(@filter_string, Compiler.options_from(@opts))
    end

    def run_values(values, input_queue: nil)
      records = values.lazy.map { |value| InputRecord.new(value: value, filename: nil, line: 1) }
      queue = InputQueue.new(records)
      builtin_queue = input_queue.is_a?(InputQueue) ? input_queue : queue
      run_queue(queue, builtin_queue)
    end

    def run_stream(io, &block)
      enum = run_io_streams([[io, nil, false]])
      return enum unless block

      enum.each(&block)
    end

    def run_io_streams(streams)
      owned_streams = []
      records = records_from_streams(streams, owned_streams)
      close_streams = lambda do
        owned_streams.each { |io| io.close unless io.closed? }
      end
      if @opts[:null_input]
        main = InputQueue.new([InputRecord.new(value: nil, filename: nil, line: 1)])
        return run_queue(main, InputQueue.new(records), on_close: close_streams)
      end

      run_queue(InputQueue.new(records), on_close: close_streams)
    end

    def format_output(value)
      return value if @opts[:raw_output] && value.is_a?(String)

      indent = @opts[:compact] ? nil : @opts[:indent]
      dumped = JSON::Dumper.dump(value, indent: indent, sort_keys: @opts[:sort_keys], ascii: @opts[:ascii],
                                        tab: @opts[:tab])
      @opts[:color] ? Color.colorize(dumped) : dumped
    end

    def write_output(value, io)
      if @opts[:raw_output] && value.is_a?(String)
        io << value
      elsif @opts[:color]
        io << format_output(value)
      else
        indent = @opts[:compact] ? nil : @opts[:indent]
        JSON::Dumper.dump(value, indent: indent, sort_keys: @opts[:sort_keys], ascii: @opts[:ascii],
                                tab: @opts[:tab], io: io)
      end
    end

    private

    def run_queue(queue, builtin_queue = queue, on_close: nil)
      ResultStream.new(on_close: on_close) do |emit|
        output_count = 0
        until queue.empty?
          record = queue.shift_record
          run_opts = @opts.merge(
            variables: @opts.fetch(:variables, {}), input_queue: builtin_queue,
            remaining_inputs: builtin_queue, current_filename: display_filename(record.filename),
            current_line: record.line
          )
          @program.run(record.value, run_opts).each do |result|
            output_count += 1
            max_outputs = @opts[:max_outputs]
            raise RuntimeError, "output limit exceeded (#{max_outputs})" if max_outputs && output_count > max_outputs

            emit.call(result)
          end
        end
      end
    end

    def records_from_streams(streams, owned_streams)
      return raw_slurp_record(streams, owned_streams) if @opts[:slurp] && @opts[:raw_input]

      records = uncollected_records(streams, owned_streams)
      return records unless @opts[:slurp]

      Enumerator.new do |yielder|
        collected = records.to_a
        yielder << InputRecord.new(value: collected.map(&:value), filename: collected.last&.filename, line: 1)
      end
    end

    def raw_slurp_record(streams, owned_streams)
      Enumerator.new do |yielder|
        content = +''.b
        last_filename = nil
        streams.each do |io, filename, close_after|
          owned_streams << io if close_after && !owned_streams.include?(io)
          begin
            while (chunk = io.read(input_chunk_size))
              break if chunk.empty?

              content << chunk.b
            end
            last_filename = filename
          ensure
            io.close if close_after && !io.closed?
          end
        end
        content.force_encoding(Encoding::UTF_8)
        yielder << InputRecord.new(value: content, filename: last_filename, line: 1)
      end
    end

    def uncollected_records(streams, owned_streams)
      Enumerator.new do |yielder|
        streams.each do |io, filename, close_after|
          owned_streams << io if close_after && !owned_streams.include?(io)
          begin
            records_for_io(io, filename).each { |record| yielder << record }
          ensure
            io.close if close_after && !io.closed?
          end
        end
      end
    end

    def records_for_io(io, filename)
      return raw_records(io, filename) if @opts[:raw_input]
      return stream_records(io, filename) if @opts[:stream]

      JSON::Parser.parse_records(io, seq: @opts[:seq], chunk_size: input_chunk_size,
                                     on_error: method(:warn_ignored_parse_error),
                                     max_depth: input_max_depth, max_number_digits: @opts[:max_number_digits],
                                     max_string_bytes: @opts[:max_string_bytes]).lazy.map do |parsed|
        InputRecord.new(value: parsed.value, filename: filename, line: parsed.line)
      end
    end

    def raw_records(io, filename)
      Enumerator.new do |yielder|
        io.each_line.with_index(1) do |line, line_number|
          value = line.delete_suffix("\n").delete_suffix("\r")
          yielder << InputRecord.new(value: value, filename: filename, line: line_number)
        end
      end
    end

    def stream_records(io, filename)
      JSON::StreamParser.parse(io, seq: @opts[:seq], stream_errors: @opts[:stream_errors],
                                   chunk_size: input_chunk_size,
                                   on_error: method(:warn_ignored_parse_error),
                                   max_depth: input_max_depth, max_number_digits: @opts[:max_number_digits],
                                   max_string_bytes: @opts[:max_string_bytes]).lazy.map do |event|
        InputRecord.new(value: event, filename: filename, line: 1)
      end
    end

    def input_chunk_size
      @opts.fetch(:input_chunk_size, JSON::InputBuffer::DEFAULT_CHUNK_SIZE)
    end

    def input_max_depth
      @opts.fetch(:input_max_depth, JSON::Parser::DEFAULT_MAX_DEPTH)
    end

    def display_filename(filename)
      filename || '<stdin>'
    end

    def warn_ignored_parse_error(message)
      (@opts[:stderr] || $stderr).puts("rjq: ignoring parse error: #{message}")
    end
  end
end
