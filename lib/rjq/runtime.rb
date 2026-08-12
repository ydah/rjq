# frozen_string_literal: true

module Rjq
  class Runtime
    DEFAULT_OPTIONS = {
      compact: false, raw_output: false, raw_output0: false, join_output: false,
      null_input: false, raw_input: false, slurp: false, ascii: false,
      sort_keys: false, tab: false, indent: 2, seq: false, stream: false,
      stream_errors: false, unbuffered: false, variables: {}
    }.freeze

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
      @opts = DEFAULT_OPTIONS.merge(opts)
      @program = Rjq.compile(@filter_string, @opts)
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

    private

    def run_queue(queue, builtin_queue = queue, on_close: nil)
      ResultStream.new(on_close: on_close) do |emit|
        until queue.empty?
          record = queue.shift_record
          run_opts = @opts.merge(
            variables: @opts.fetch(:variables, {}), input_queue: builtin_queue,
            remaining_inputs: builtin_queue, current_filename: display_filename(record.filename),
            current_line: record.line
          )
          @program.run(record.value, run_opts).each { |result| emit.call(result) }
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
                                     on_error: method(:warn_ignored_parse_error)).lazy.map do |parsed|
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
                                   on_error: method(:warn_ignored_parse_error)).lazy.map do |event|
        InputRecord.new(value: event, filename: filename, line: 1)
      end
    end

    def input_chunk_size
      @opts.fetch(:input_chunk_size, JSON::InputBuffer::DEFAULT_CHUNK_SIZE)
    end

    def display_filename(filename)
      filename || '<stdin>'
    end

    def warn_ignored_parse_error(message)
      (@opts[:stderr] || $stderr).puts("rjq: ignoring parse error: #{message}")
    end
  end
end
