# frozen_string_literal: true

require_relative '../rjq'

module Rjq
  class CLI
    HELP = <<~HELP.freeze
      rjq - commandline JSON processor [version #{VERSION}]

      Usage:	rjq [options] <jq filter> [file...]
      	rjq [options] --args <jq filter> [strings...]
      	rjq [options] --jsonargs <jq filter> [JSON_TEXTS...]

      rjq is a tool for processing JSON inputs, applying the given filter to
      its JSON text inputs and producing the filter's results as JSON on
      standard output.

      Command options:
        -n, --null-input          use `null` as the single input value;
        -R, --raw-input           read each line as string instead of JSON;
        -s, --slurp               read all inputs into an array and use it as
                                  the single input value;
        -c, --compact-output      compact instead of pretty-printed output;
        -r, --raw-output          output strings without escapes and quotes;
            --raw-output0         implies -r and output NUL after each output;
        -j, --join-output         implies -r and output without newline after
                                  each output;
        -a, --ascii-output        output strings by only ASCII characters
                                  using escape sequences;
        -S, --sort-keys           sort keys of each object on output;
        -C, --color-output        colorize JSON output;
        -M, --monochrome-output   disable colored output;
            --tab                 use tabs for indentation;
            --indent n            use n spaces for indentation (max 7 spaces);
            --unbuffered          flush output stream after each output;
            --stream              parse the input value in streaming fashion;
            --stream-errors       implies --stream and report parse error as
                                  an array;
            --seq                 parse input/output as application/json-seq;
            --max-filter-depth n  reject filters nested deeper than n;
            --max-call-depth n    bound non-tail user-function calls;
            --max-instructions n  bound executed bytecode instructions;
            --max-replay-cache n  bound values cached for filter replay;
        -f, --from-file file      load filter from the file;
        -L directory              search modules from the directory;
            --arg name value      set $name to the string value;
            --argjson name value  set $name to the JSON value;
            --slurpfile name file set $name to an array of JSON values read
                                  from the file;
            --rawfile name file   set $name to string contents of file;
            --args                consume remaining arguments as positional
                                  string values;
            --jsonargs            consume remaining arguments as positional
                                  JSON values;
        -e, --exit-status         set exit status code based on the output;
        -V, --version             show the version;
        --build-configuration     show rjq's build configuration;
        -h, --help                show the help;
        --                        terminates argument processing;

      Named arguments are also available as $ARGS.named[], while
      positional arguments are available as $ARGS.positional[].
    HELP
    OPTION_HELP = <<~HELP
      Use rjq --help for help with command-line options,
      or see the jq manpage, or online docs at https://jqlang.github.io/jq
    HELP

    class OptionError < StandardError; end
    class EarlyExit < StandardError
      attr_reader :status

      def initialize(status)
        @status = status
        super()
      end
    end

    def initialize(argv, stdin:, stdout:, stderr:)
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @opts = Runtime::DEFAULT_OPTIONS.merge(variables: { 'ARGS.named' => {}, 'ARGS.positional' => [] })
      @filter = nil
      @files = []
    end

    def run
      parse!
      return run_tests if @opts[:run_tests]

      @opts[:stderr] = @stderr
      @opts[:color] = @stdout.tty? && !ENV.key?('NO_COLOR') if @opts[:color].nil?
      last = nil
      count = 0
      runtime = Runtime.new(@filter || '.', @opts)
      runtime.run_io_streams(input_streams).each do |value|
        last = value
        count += 1
        write_value(runtime, value)
      end
      return exit_status(last, count) if @opts[:exit_status]

      0
    rescue HaltError => e
      @stderr.puts(e.message) if e.value
      e.status
    rescue EarlyExit => e
      e.status
    rescue OptionError => e
      @stderr.puts(e.message)
      @stderr.print(OPTION_HELP)
      2
    rescue JSONParseError => e
      @stderr.puts("rjq: JSON parse error: #{e.message}")
      5
    rescue ParseError, CompileError => e
      @stderr.puts("rjq: compile error: #{e.message}")
      3
    rescue Rjq::RuntimeError => e
      @stderr.puts("rjq: runtime error: #{e.message}")
      5
    rescue SystemStackError
      @stderr.puts('rjq: runtime error: recursion limit exceeded')
      5
    rescue Errno::EPIPE
      0
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
      @stderr.puts("rjq: #{e.message}")
      2
    end

    private

    def parse!
      until @argv.empty?
        arg = @argv.shift
        case arg
        when '--'
          if @filter.nil? && !@opts[:filter_file] && !@argv.empty?
            @filter = @argv.shift
          end
          @files.concat(@argv)
          @argv.clear
        when /\A--/
          parse_long(arg)
        when /\A-(?:\d|\.)/
          if @filter.nil? && !@opts[:filter_file]
            @filter = arg
          else
            @files << arg
          end
        when /\A-[^-]/
          parse_short(arg)
        else
          if @filter.nil? && !@opts[:filter_file]
            @filter = arg
          else
            @files << arg
          end
        end
      end

      return unless @opts[:filter_file]

      @files.unshift(@filter) if @filter
      filter_file = @opts.delete(:filter_file)
      @filter = File.read(filter_file)
      @opts[:source_path] = File.realpath(filter_file)
    end

    def parse_long(arg)
      case arg
      when '--compact-output' then @opts[:compact] = true
      when '--raw-output' then @opts[:raw_output] = true
      when '--raw-output0' then @opts[:raw_output] = @opts[:raw_output0] = true
      when '--join-output' then @opts[:raw_output] = @opts[:join_output] = true
      when '--null-input' then @opts[:null_input] = true
      when '--raw-input' then @opts[:raw_input] = true
      when '--slurp' then @opts[:slurp] = true
      when '--ascii-output' then @opts[:ascii] = true
      when '--sort-keys' then @opts[:sort_keys] = true
      when '--tab' then @opts[:tab] = true
      when '--seq' then @opts[:seq] = true
      when '--stream' then @opts[:stream] = true
      when '--stream-errors' then @opts[:stream] = @opts[:stream_errors] = true
      when '--exit-status' then @opts[:exit_status] = true
      when '--unbuffered' then @opts[:unbuffered] = true
      when '--color-output' then @opts[:color] = true
      when '--monochrome-output' then @opts[:color] = false
      when '--allow-comments' then @opts[:allow_comments] = true
      when '--max-filter-depth'
        @opts[:max_filter_depth] = validate_limit(next_arg('--max-filter-depth'), '--max-filter-depth', minimum: 1)
      when '--max-call-depth'
        @opts[:max_call_depth] = validate_limit(next_arg('--max-call-depth'), '--max-call-depth', minimum: 1)
      when '--max-instructions'
        @opts[:max_instructions] = validate_limit(next_arg('--max-instructions'), '--max-instructions', minimum: 0)
      when '--max-replay-cache'
        @opts[:max_replay_cache] = validate_limit(next_arg('--max-replay-cache'), '--max-replay-cache', minimum: 0)
      when '--indent'
        @opts[:indent] = validate_indent(next_arg('--indent', '--indent takes one parameter'))
        @opts[:tab] = false
      when '--arg' then bind_string(*next_args(2, '--arg takes two parameters (e.g. --arg varname value)'))
      when '--argjson' then bind_json(*next_args(2, '--argjson takes two parameters (e.g. --argjson varname text)'))
      when '--slurpfile' then bind_json_array(*next_args(2,
                                                         '--slurpfile takes two parameters (e.g. --slurpfile varname filename)'))
      when '--rawfile' then bind_raw_file(*next_args(2,
                                                     '--rawfile takes two parameters (e.g. --rawfile varname filename)'))
      when '--args' then consume_positional(json: false)
      when '--jsonargs' then consume_positional(json: true)
      when '--from-file' then @opts[:filter_file] = next_arg('--from-file')
      when '--run-tests' then parse_run_tests
      when '--build-configuration' then print_build_configuration_and_exit
      when '--version' then print_version_and_exit
      when '--help' then print_help_and_exit
      else
        raise OptionError, "rjq: Unknown option #{arg}"
      end
    end

    def parse_short(arg)
      chars = arg.delete_prefix('-').chars
      until chars.empty?
        char = chars.shift
        case char
        when 'c' then @opts[:compact] = true
        when 'r' then @opts[:raw_output] = true
        when 'j' then @opts[:raw_output] = @opts[:join_output] = true
        when 'n' then @opts[:null_input] = true
        when 'R' then @opts[:raw_input] = true
        when 's' then @opts[:slurp] = true
        when 'a' then @opts[:ascii] = true
        when 'S' then @opts[:sort_keys] = true
        when 'e' then @opts[:exit_status] = true
        when 'f'
          @opts[:filter_file] = chars.empty? ? next_arg('-f') : chars.join
          chars.clear
        when 'L'
          (@opts[:library_path] ||= []) << (chars.empty? ? next_arg('-L') : chars.join)
          chars.clear
        when 'V' then print_version_and_exit
        when 'h' then print_help_and_exit
        when 'C', 'M'
          @opts[:color] = char == 'C'
        else
          raise OptionError, "rjq: Unknown option -#{char}"
        end
      end
    end

    def parse_run_tests
      @opts[:run_tests] = true
      @opts[:run_tests_file] = @argv.shift unless @argv.empty?
      @argv.clear
    end

    def bind_string(name, value)
      @opts[:variables][name] = value
      @opts[:variables]['ARGS.named'][name] = value
    end

    def bind_json(name, value)
      parsed = JSON::Parser.parse_one(value)
      @opts[:variables][name] = parsed
      @opts[:variables]['ARGS.named'][name] = parsed
    rescue JSONParseError => e
      raise OptionError, "rjq: invalid JSON text passed to --argjson: #{e.message}"
    end

    def bind_json_array(name, path)
      parsed = JSON::Parser.parse(File.read(path)).to_a
      @opts[:variables][name] = parsed
      @opts[:variables]['ARGS.named'][name] = parsed
    end

    def bind_raw_file(name, path)
      bind_string(name, File.read(path))
    end

    def consume_positional(json:)
      @filter ||= next_arg(json ? '--jsonargs filter' : '--args filter')
      values = @argv.map { |arg| json ? JSON::Parser.parse_one(arg) : arg }
      @opts[:variables]['ARGS.positional'] = values
      @argv.clear
    rescue JSONParseError => e
      raise OptionError, "rjq: invalid JSON text passed to --jsonargs: #{e.message}"
    end

    def next_arg(option, message = "#{option} takes one parameter")
      raise OptionError, "rjq: #{message}" if @argv.empty?

      @argv.shift
    end

    def next_args(count, message)
      raise OptionError, "rjq: #{message}" if @argv.length < count

      @argv.shift(count)
    end

    def validate_indent(value)
      indent = Integer(value)
      raise OptionError, 'rjq: --indent must be between 0 and 7' unless indent.between?(0, 7)

      indent
    rescue ArgumentError
      raise OptionError, 'rjq: --indent must be an integer'
    end

    def validate_limit(value, option, minimum:)
      limit = Integer(value, 10)
      raise OptionError, "rjq: #{option} must be at least #{minimum}" if limit < minimum

      limit
    rescue ArgumentError
      raise OptionError, "rjq: #{option} must be an integer"
    end

    def input_streams
      Enumerator.new do |yielder|
        if @files.empty?
          yielder << [@stdin, nil, false]
          next
        end

        @files.each do |file|
          if file == '-'
            yielder << [@stdin, nil, false]
          else
            yielder << [File.open(file, 'rb'), file, true]
          end
        end
      end
    end

    def write_value(runtime, value)
      if @opts[:raw_output0] && value.is_a?(String) && value.include?("\0")
        raise Rjq::RuntimeError, 'Cannot dump a string containing NUL with --raw-output0 option'
      end

      @stdout.print("\x1e") if @opts[:seq]
      runtime.write_output(value, @stdout)
      @stdout.print(output_separator)
      @stdout.flush if @opts[:unbuffered] && @stdout.respond_to?(:flush)
    end

    def output_separator
      return "\0" if @opts[:raw_output0]
      return '' if @opts[:join_output]

      "\n"
    end

    def exit_status(last, count)
      return 4 if count.zero?
      return 1 if last.nil? || last == false

      0
    end

    def run_tests
      source = @opts[:run_tests_file] ? File.read(@opts[:run_tests_file]) : @stdin.read
      results = run_test_groups(test_groups(source))
      @stdout.puts("#{results.fetch(:passed)} of #{results.fetch(:checked)} tests passed " \
                   "(#{results.fetch(:malformed)} malformed, #{results.fetch(:skipped)} skipped)")
      results.fetch(:failed).zero? && results.fetch(:malformed).zero? ? 0 : 1
    rescue Errno::ENOENT, Errno::EACCES => e
      @stderr.puts(e.message.include?('No such file') ? 'fopen: No such file or directory' : e.message)
      1
    end

    def test_groups(source)
      groups = []
      current = []
      start_line = nil
      fail_mode = false
      source.each_line(chomp: true).with_index(1) do |line, line_number|
        if line.empty?
          groups << [fail_mode, current, start_line] unless current.empty?
          current = []
          start_line = nil
          fail_mode = false
          next
        end
        next if line.start_with?('#')

        if line.start_with?('%%FAIL')
          fail_mode = true
          next
        end
        start_line ||= line_number
        current << line
      end
      groups << [fail_mode, current, start_line] unless current.empty?
      groups
    end

    def run_test_groups(groups)
      groups.each_with_object({ checked: 0, passed: 0, failed: 0, malformed: 0,
                                skipped: 0 }) do |(fail_mode, lines, line_number), results|
        results[:checked] += 1
        unless lines.empty?
          @stdout.puts("Test ##{results.fetch(:checked)}: '#{lines.first}' at line number #{line_number}")
        end
        if lines.length < (fail_mode ? 1 : 3)
          results[:malformed] += 1
        elsif test_group_passed?(fail_mode, lines)
          results[:passed] += 1
        else
          results[:failed] += 1
        end
      end
    end

    def test_group_passed?(fail_mode, lines)
      program, input, *expected = lines
      if fail_mode
        Rjq.compile(program).run(nil).to_a
        return false
      end

      actual = JSON::Parser.parse(input).to_a.flat_map { |value| Rjq.run(program, value).to_a }
      expected_values = expected.map { |line| JSON::Parser.parse_one(line) }
      expected_values.length == actual.length && expected_values.zip(actual).all? do |left, right|
        Value.equal?(left, right)
      end
    rescue Rjq::Error
      fail_mode
    rescue StandardError
      false
    end

    def print_version_and_exit
      @stdout.puts("rjq-#{VERSION}")
      raise EarlyExit, 0
    end

    def print_help_and_exit
      @stdout.print(HELP)
      raise EarlyExit, 0
    end

    def print_build_configuration_and_exit
      @stdout.puts("rjq=#{VERSION}")
      @stdout.puts("ruby=#{RUBY_VERSION}p#{RUBY_PATCHLEVEL} (#{RUBY_PLATFORM})")
      @stdout.puts('regexp-engine=ruby')
      @stdout.puts('native-math=fiddle-libm')
      @stdout.puts('json-parser=incremental')
      raise EarlyExit, 0
    end
  end
end
