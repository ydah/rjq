# frozen_string_literal: true

require 'cgi'
require 'time'
require 'uri'

module Rjq
  module Builtins
    ZERO_ARITY_BUILTINS = %w[
      empty length utf8bytelength type keys keys_unsorted values arrays objects iterables scalars booleans nulls
      numbers strings not error halt halt_error input inputs debug stderr input_filename input_line_number null true
      false infinite nan isinfinite isnan isnormal add any all flatten floor ceil round sqrt log log2 log10 exp exp2 exp10
      pow10 atan abs cos sin tan acos asin cosh sinh tanh acosh asinh atanh cbrt significand logb gamma tgamma
      lgamma lgamma_r frexp modf fabs nearbyint trunc rint j0 j1 y0 y1 to_entries from_entries to_number tonumber
      tostring tojson fromjson ascii explode implode ascii_downcase ascii_upcase recurse recurse_down paths leaf_paths
      tostream min max sort unique reverse combinations transpose first last env now gmtime localtime mktime fromdate
      todate fromdateiso8601 todateiso8601 date builtins modulemeta
    ].freeze
    ONE_ARITY_BUILTINS = %w[
      has in IN INDEX error halt_error debug flatten range any all with_entries select map map_values split join
      ltrimstr rtrimstr startswith endswith index rindex indices recurse recurse_down path paths leaf_paths getpath
      delpaths del pick walk fromstream truncate_stream min_by max_by sort_by group_by GROUP_BY unique_by UNIQUE_BY
      contains inside combinations bsearch first last nth repeat isempty strftime strflocaltime strptime dateadd datesub
      test match capture scan splits
    ].freeze
    TWO_ARITY_BUILTINS = %w[
      IN INDEX JOIN any all range recurse recurse_down pow atan2 ldexp scalb scalbln drem setpath nth limit until while split test match
      scan splits sub gsub
    ].freeze
    THREE_ARITY_BUILTINS = %w[JOIN range fma sub gsub].freeze
    FOUR_ARITY_BUILTINS = %w[JOIN].freeze

    BUILTIN_ARITIES = [
      [0, ZERO_ARITY_BUILTINS],
      [1, ONE_ARITY_BUILTINS],
      [2, TWO_ARITY_BUILTINS],
      [3, THREE_ARITY_BUILTINS],
      [4, FOUR_ARITY_BUILTINS]
    ].each_with_object({}) do |(arity, names), registry|
      names.each { |name| (registry[name] ||= []) << arity }
    end.transform_values(&:freeze).freeze
    BUILTIN_NAMES = BUILTIN_ARITIES.keys.freeze
    FORMAT_NAMES = %w[@text @json @html @uri @csv @tsv @sh @base64 @base64d @base32 @base32d].freeze
    REGISTRY = BUILTIN_NAMES.to_h { |name| [name, true] }.freeze
    FILTER_ARGUMENT_POSITIONS = {
      'IN' => [0, 1], 'INDEX' => [0, 1], 'JOIN' => [1, 2, 3],
      'any' => [0, 1], 'all' => [0, 1], 'with_entries' => [0], 'select' => [0], 'map' => [0],
      'map_values' => [0], 'recurse' => [0, 1], 'recurse_down' => [0, 1], 'path' => [0], 'paths' => [0],
      'leaf_paths' => [0], 'del' => [0], 'pick' => [0], 'walk' => [0], 'fromstream' => [0],
      'truncate_stream' => [0], 'min_by' => [0], 'max_by' => [0], 'sort_by' => [0], 'group_by' => [0],
      'GROUP_BY' => [0], 'unique_by' => [0], 'UNIQUE_BY' => [0], 'first' => [0], 'last' => [0], 'nth' => [1],
      'limit' => [1], 'until' => [0, 1], 'while' => [0, 1], 'repeat' => [0], 'isempty' => [0],
      'sub' => [1], 'gsub' => [1]
    }.transform_values(&:freeze).freeze

    module_function

    def call(name, input, context, args)
      argument_sets = args.each_with_index.map do |argument, index|
        if FILTER_ARGUMENT_POSITIONS.fetch(name, []).include?(index)
          [argument]
        else
          argument.eval(input, context).map { |value| AST::Literal.new(value) }
        end
      end
      cartesian(argument_sets).flat_map { |resolved_args| dispatch(name, input, context, resolved_args) }
    end

    def dispatch(name, input, context, args)
      return call(name, args.fetch(0).eval(input, context).first, context, []) if name.start_with?('@') && !args.empty?

      case name
      when 'empty'
        []
      when 'length'
        [length(input)]
      when 'utf8bytelength'
        [utf8_byte_length(input)]
      when 'type'
        [Value.type_of(input)]
      when 'keys'
        [keys(input, sorted: true)]
      when 'keys_unsorted'
        [keys(input, sorted: false)]
      when 'values'
        input.nil? ? [] : [input]
      when 'arrays'
        input.is_a?(Array) ? [input] : []
      when 'objects'
        input.is_a?(Hash) ? [input] : []
      when 'iterables'
        input.is_a?(Array) || input.is_a?(Hash) ? [input] : []
      when 'scalars'
        input.is_a?(Array) || input.is_a?(Hash) ? [] : [input]
      when 'booleans'
        [true, false].include?(input) ? [input] : []
      when 'nulls'
        input.nil? ? [input] : []
      when 'numbers'
        input.is_a?(Numeric) ? [input] : []
      when 'strings'
        input.is_a?(String) ? [input] : []
      when 'has'
        [has?(input, eval_arg(args, 0, input, context))]
      when 'in'
        [has?(eval_arg(args, 0, input, context), input)]
      when 'IN'
        [in_sql?(input, context, args)]
      when 'INDEX'
        [index_sql(input, context, args)]
      when 'JOIN'
        [join_sql(input, context, args)]
      when 'not'
        [!Value.truthy?(input)]
      when 'error'
        raise ErrorValue, args.empty? ? input : eval_arg(args, 0, input, context)
      when 'halt'
        raise HaltError, nil
      when 'halt_error'
        raise HaltError.new(input, args.empty? ? 5 : eval_arg(args, 0, input, context).to_i)
      when 'input'
        input_builtin(context)
      when 'inputs'
        inputs_builtin(context)
      when 'input_filename'
        [context.options.fetch(:current_filename, '<stdin>') || '<stdin>']
      when 'input_line_number'
        [context.options.fetch(:current_line, 1)]
      when 'debug', 'stderr'
        emit_diagnostic(name, input, context)
      when 'null'
        [nil]
      when 'true'
        [true]
      when 'false'
        [false]
      when 'infinite'
        [Float::INFINITY]
      when 'nan'
        [Float::NAN]
      when 'isinfinite'
        [input.is_a?(Float) && input.infinite? ? true : false]
      when 'isnan'
        [input.is_a?(Float) && input.nan?]
      when 'isnormal'
        [input.is_a?(Numeric) && input.to_f.finite? && input.to_f != 0.0]
      when 'add'
        [add(input)]
      when 'abs'
        [input.is_a?(Numeric) ? input.abs : input]
      when 'any'
        [any?(input, context, args)]
      when 'all'
        [all?(input, context, args)]
      when 'flatten'
        args.empty? ? [flatten(input)] : args.fetch(0).eval(input, context).map { |depth| flatten(input, depth) }
      when 'range'
        range(input, context, args)
      when 'floor', 'ceil', 'round', 'sqrt', 'log', 'log2', 'log10', 'exp', 'sin', 'cos', 'tan',
           'asin', 'acos', 'atan', 'sinh', 'cosh', 'tanh', 'asinh', 'acosh', 'atanh', 'cbrt',
           'trunc', 'fabs', 'gamma', 'tgamma', 'lgamma', 'significand', 'logb', 'nearbyint',
           'rint', 'frexp', 'modf', 'lgamma_r', 'j0', 'j1', 'y0', 'y1'
        [math_unary(name, input)]
      when 'pow', 'atan2', 'ldexp', 'scalb', 'scalbln', 'fma', 'drem'
        [math_nary(name, input, context, args)]
      when 'exp2'
        [2**numeric(input)]
      when 'exp10', 'pow10'
        [10**numeric(input)]
      when 'to_entries'
        [to_entries(input)]
      when 'from_entries'
        [from_entries(assert_array(input))]
      when 'with_entries'
        [from_entries(map_entries(input, context, args.fetch(0)))]
      when 'select'
        select(input, context, args.fetch(0))
      when 'map'
        [map_filter(input, context, args.fetch(0))]
      when 'map_values'
        [map_values(input, context, args.fetch(0))]
      when 'to_number', 'tonumber'
        [to_number(input)]
      when 'tostring'
        [to_string(input)]
      when 'tojson', '@json'
        [JSON::Dumper.dump(input, indent: nil)]
      when 'fromjson'
        [JSON::Parser.parse_one(assert_string(input))]
      when 'ascii'
        [JSON::Dumper.dump(to_string(input), indent: nil, ascii: true)[1...-1]]
      when 'explode'
        [assert_string(input).each_codepoint.to_a]
      when 'implode'
        [implode(input)]
      when 'split'
        [split(input, context, args)]
      when 'join'
        args.empty? ? [join(input, '')] : args.fetch(0).eval(input, context).map { |separator| join(input, separator) }
      when 'ltrimstr'
        [assert_string(input).delete_prefix(assert_string(eval_arg(args, 0, input, context)))]
      when 'rtrimstr'
        [assert_string(input).delete_suffix(assert_string(eval_arg(args, 0, input, context)))]
      when 'ascii_downcase'
        [assert_string(input).tr('A-Z', 'a-z')]
      when 'ascii_upcase'
        [assert_string(input).tr('a-z', 'A-Z')]
      when 'startswith'
        [assert_string(input).start_with?(assert_string(eval_arg(args, 0, input, context)))]
      when 'endswith'
        [assert_string(input).end_with?(assert_string(eval_arg(args, 0, input, context)))]
      when 'index'
        args.fetch(0).eval(input, context).map { |needle| index_of(input, needle) }
      when 'rindex'
        args.fetch(0).eval(input, context).map { |needle| rindex_of(input, needle) }
      when 'indices'
        args.fetch(0).eval(input, context).map { |needle| indices_of(input, needle) }
      when 'recurse', 'recurse_down'
        recurse(input, context, args)
      when 'path'
        args.fetch(0).paths(input, context)
      when 'paths'
        paths_builtin(input, context, args, leaves_only: false)
      when 'leaf_paths'
        paths_builtin(input, context, args, leaves_only: true)
      when 'getpath'
        [Path.get(input, eval_arg(args, 0, input, context))]
      when 'setpath'
        [Path.set(Value.deep_copy(input), eval_arg(args, 0, input, context), eval_arg(args, 1, input, context))]
      when 'delpaths'
        [delpaths(input, eval_arg(args, 0, input, context))]
      when 'del'
        [delete_paths(input, context, args)]
      when 'pick'
        [pick(input, context, args)]
      when 'walk'
        walk(input, context, args.fetch(0))
      when 'tostream'
        to_stream(input)
      when 'fromstream'
        [from_stream(args.empty? ? input : args.fetch(0).eval(input, context))]
      when 'truncate_stream'
        truncate_stream(input, context, args)
      when 'min'
        [extreme(input, :min)]
      when 'max'
        [extreme(input, :max)]
      when 'min_by'
        [extreme_by(input, context, args.fetch(0), :min)]
      when 'max_by'
        [extreme_by(input, context, args.fetch(0), :max)]
      when 'sort'
        [assert_array(input).sort { |a, b| Value.compare(a, b) }]
      when 'sort_by'
        [sort_by_filter(input, context, args.fetch(0))]
      when 'group_by', 'GROUP_BY'
        [group_by_filter(input, context, args.fetch(0))]
      when 'unique'
        [unique_values(assert_array(input))]
      when 'unique_by', 'UNIQUE_BY'
        [unique_by_filter(input, context, args.fetch(0))]
      when 'reverse'
        [assert_array(input).reverse]
      when 'contains'
        [contains?(input, eval_arg(args, 0, input, context))]
      when 'inside'
        [contains?(eval_arg(args, 0, input, context), input)]
      when 'combinations'
        combinations(input, context, args)
      when 'transpose'
        [transpose(input)]
      when 'bsearch'
        bsearch(input, context, args)
      when 'first'
        first_builtin(input, context, args)
      when 'last'
        last_builtin(input, context, args)
      when 'nth'
        nth(input, context, args)
      when 'limit'
        limit(input, context, args)
      when 'until'
        until_filter(input, context, args)
      when 'while'
        while_filter(input, context, args)
      when 'repeat'
        repeat_filter(input, context, args)
      when 'isempty'
        [args.fetch(0).take(input, context, 1).empty?]
      when 'builtins'
        [BUILTIN_NAMES.flat_map { |builtin| builtin_arities(builtin) }.sort]
      when 'modulemeta'
        [modulemeta(input, context)]
      when 'env'
        [ENV.to_h]
      when 'now'
        [Time.now.to_f]
      when 'gmtime'
        [time_array(Time.at(numeric(input)).utc)]
      when 'localtime'
        [time_array(Time.at(numeric(input)).localtime)]
      when 'mktime'
        [mktime(input)]
      when 'strftime'
        [strftime_builtin(input, context, args)]
      when 'strflocaltime'
        [strftime_builtin(input, context, args, local: true)]
      when 'strptime'
        [strptime(input, context, args)]
      when 'fromdate', 'fromdateiso8601'
        [Time.iso8601(assert_string(input)).to_f]
      when 'todate', 'todateiso8601'
        [Time.at(numeric(input)).utc.iso8601]
      when 'date'
        [Time.now.utc.iso8601]
      when 'dateadd'
        [Time.at(numeric(input) + numeric(eval_arg(args, 0, input, context))).to_f]
      when 'datesub'
        [Time.at(numeric(input) - numeric(eval_arg(args, 0, input, context))).to_f]
      when 'test'
        regex, flags = regexp(input, context, args)
        match = regex.match(assert_string(input))
        [match ? !(flags.include?('n') && match[0].empty?) : false]
      when 'match'
        match_builtin(input, context, args)
      when 'capture'
        capture_builtin(input, context, args)
      when 'scan'
        scan_builtin(input, context, args)
      when 'splits'
        splits_builtin(input, context, args)
      when 'sub'
        substitute(input, context, args, global: false)
      when 'gsub'
        substitute(input, context, args, global: true)
      when '@text'
        [to_string(input)]
      when '@html'
        [html_escape(to_string(input))]
      when '@uri'
        [uri_escape(to_string(input))]
      when '@base64'
        [[to_string(input)].pack('m0')]
      when '@base64d'
        [assert_string(input).unpack1('m0').force_encoding(Encoding::UTF_8)]
      when '@base32'
        [base32_encode(to_string(input))]
      when '@base32d'
        [base32_decode(assert_string(input))]
      when '@csv'
        [format_csv(input)]
      when '@tsv'
        [format_tsv(input)]
      when '@sh'
        [format_sh(input)]
      else
        raise CompileError, "#{name}/#{args.length} is not defined"
      end
    end

    def length(value)
      case value
      when NilClass
        0
      when String
        value.each_char.count
      when Array, Hash
        value.length
      when Numeric
        value.abs
      else
        raise TypeError, "cannot get length of #{Value.type_of(value)}"
      end
    end

    def utf8_byte_length(value)
      return value.bytesize if value.is_a?(String)

      raise TypeError,
            "#{Value.type_of(value)} (#{JSON::Dumper.dump(value, indent: nil)}) only strings have UTF-8 byte length"
    end

    def keys(value, sorted:)
      case value
      when Array
        (0...value.length).to_a
      when Hash
        sorted ? value.keys.sort : value.keys
      else
        raise TypeError, "cannot get keys of #{Value.type_of(value)}"
      end
    end

    def has?(container, key)
      case container
      when Array
        key.is_a?(Numeric) && key.finite? && key >= 0 && key.floor < container.length
      when Hash
        raise TypeError, 'Cannot check whether object has a number key' if key.is_a?(Numeric)

        container.key?(key)
      else
        false
      end
    end

    def input_builtin(context)
      queue = context.options[:input_queue]
      return [queue.shift] if queue && !queue.empty?

      remaining = context.options.fetch(:remaining_inputs, [])
      raise RuntimeError, 'break' if remaining.empty?

      [remaining.first]
    end

    def inputs_builtin(context)
      queue = context.options[:input_queue]
      if queue
        values = queue.dup
        queue.clear
        return values
      end

      context.options.fetch(:remaining_inputs, [])
    end

    def emit_diagnostic(name, input, context)
      io = context.options[:stderr] || $stderr
      if name == 'debug'
        io.puts(JSON::Dumper.dump(['DEBUG:', input], indent: nil))
      else
        io.puts(to_string(input))
      end
      [input]
    end

    def add(value)
      assert_array(value).reduce(nil) do |sum, item|
        sum.nil? ? item : AST::BinaryOp.new(AST::Literal.new(sum), '+', AST::Literal.new(item)).eval(nil, AST::Context.new).first
      end
    end

    def any?(input, context, args)
      if args.length == 2
        return source_any?(args[0], input, context) do |value|
          args[1].eval(value, context).any? { |result| Value.truthy?(result) }
        end
      end

      values = args.empty? ? assert_array(input) : input_values(input, context, args.first)
      values.any? { |value| Value.truthy?(value) }
    end

    def all?(input, context, args)
      if args.length == 2
        return source_all?(args[0], input, context) do |value|
          args[1].eval(value, context).any? { |result| Value.truthy?(result) }
        end
      end

      values = args.empty? ? assert_array(input) : input_values(input, context, args.first)
      values.all? { |value| Value.truthy?(value) }
    end

    def flatten(value, depth = nil)
      raise RuntimeError, 'flatten depth must not be negative' if depth&.negative?
      unless value.is_a?(Array)
        raise TypeError, "Cannot iterate over #{Value.type_of(value)} (#{JSON::Dumper.dump(value, indent: nil)})"
      end
      return value if depth && depth <= 0

      value.flat_map do |item|
        if item.is_a?(Array)
          flatten(item, depth.nil? ? nil : depth - 1)
        else
          item
        end
      end
    end

    def range(input, context, args)
      arg_sets = args.map { |arg| arg.eval(input, context).map { |value| numeric(value) } }
      cartesian(arg_sets).flat_map do |numbers|
        from, to, step =
          case numbers.length
          when 1
            [0, numbers[0], 1]
          when 2
            [numbers[0], numbers[1], 1]
          when 3
            numbers
          else
            raise RuntimeError, 'range expects 1 to 3 arguments'
          end
        raise RuntimeError, 'range step cannot be zero' if step.zero?

        range_values(from, to, step)
      end
    end

    def cartesian(sets)
      return [[]] if sets.empty?

      sets.reduce([[]]) do |acc, values|
        acc.flat_map { |prefix| values.map { |value| prefix + [value] } }
      end
    end

    def range_values(from, to, step)
      out = []
      current = from
      if step.positive?
        while current < to
          out << current
          current += step
        end
      else
        while current > to
          out << current
          current += step
        end
      end
      out
    end

    def math_unary(name, input)
      value = numeric(input)
      case name
      when 'floor' then value.floor
      when 'ceil' then value.ceil
      when 'round' then value.round
      when 'sqrt' then Math.sqrt(value)
      when 'log' then Math.log(value)
      when 'log2' then Math.log2(value)
      when 'log10' then Math.log10(value)
      when 'exp' then Math.exp(value)
      when 'sin' then Math.sin(value)
      when 'cos' then Math.cos(value)
      when 'tan' then Math.tan(value)
      when 'asin' then Math.asin(value)
      when 'acos' then Math.acos(value)
      when 'atan' then Math.atan(value)
      when 'sinh' then Math.sinh(value)
      when 'cosh' then Math.cosh(value)
      when 'tanh' then Math.tanh(value)
      when 'asinh' then Math.asinh(value)
      when 'acosh' then Math.acosh(value)
      when 'atanh' then Math.atanh(value)
      when 'cbrt' then Math.cbrt(value)
      when 'trunc' then value.truncate
      when 'fabs' then value.abs
      when 'gamma', 'tgamma' then Math.gamma(value)
      when 'lgamma' then Math.lgamma(value).first
      when 'lgamma_r' then Math.lgamma(value)
      when 'frexp' then Math.frexp(value)
      when 'modf'
        integral = value.truncate
        [value - integral, integral]
      when 'significand'
        return 0 if value.zero?

        fraction, = Math.frexp(value)
        fraction * 2
      when 'logb'
        return -Float::INFINITY if value.zero?

        Math.log2(value.abs).floor
      when 'nearbyint', 'rint' then value.round
      when 'j0', 'j1', 'y0', 'y1' then MathFunctions.bessel(name, value)
      end
    end

    def math_nary(name, input, context, args)
      values = args.empty? ? [numeric(input)] : args.map { |arg| numeric(arg.eval(input, context).first) }
      case name
      when 'pow' then values[0]**values[1]
      when 'atan2' then Math.atan2(values[0], values[1])
      when 'ldexp', 'scalb', 'scalbln' then Math.ldexp(values[0], values[1].to_i)
      when 'fma' then (values[0] * values[1]) + values[2]
      when 'drem' then values[0].remainder(values[1])
      end
    end

    def to_entries(value)
      case value
      when Hash
        value.map { |key, item| { 'key' => key, 'value' => item } }
      when Array
        value.each_with_index.map { |item, index| { 'key' => index, 'value' => item } }
      else
        raise TypeError, "cannot convert #{Value.type_of(value)} to entries"
      end
    end

    def from_entries(entries)
      entries.each_with_object({}) do |entry, object|
        key = entry['key'] || entry[:key] || entry['Key'] || entry['name'] || entry['Name']
        value = entry.key?('value') ? entry['value'] : entry['Value']
        object[key.to_s] = value
      end
    end

    def map_entries(input, context, filter)
      to_entries(input).flat_map { |entry| filter.eval(entry, context) }
    end

    def select(input, context, filter)
      filter.eval(input, context).filter_map { |value| input if Value.truthy?(value) }
    end

    def map_filter(value, context, filter)
      items = value.is_a?(Hash) ? value.values : assert_array(value)
      items.flat_map { |item| filter.eval(item, context) }
    end

    def map_values(value, context, filter)
      case value
      when Array
        value.filter_map { |item| filter.eval(item, context).first }
      when Hash
        value.each_with_object({}) do |(key, item), out|
          outputs = filter.eval(item, context)
          out[key] = outputs.first unless outputs.empty?
        end
      else
        raise TypeError, "cannot map values of #{Value.type_of(value)}"
      end
    end

    def to_number(value)
      return value if value.is_a?(Numeric)
      raise TypeError, "cannot convert #{Value.type_of(value)} to number" unless value.is_a?(String)

      value.match?(/[.eE]/) ? Float(value) : Integer(value, 10)
    rescue ArgumentError
      raise TypeError, 'invalid numeric string'
    end

    def to_string(value)
      case value
      when String
        value
      else
        JSON::Dumper.dump(value, indent: nil)
      end
    end

    def split(input, context, args)
      string = assert_string(input)
      separator = assert_string(eval_arg(args, 0, input, context))
      return string.each_char.to_a if separator.empty?

      string.split(separator, -1)
    end

    def implode(input)
      raise TypeError, 'implode input must be an array' unless input.is_a?(Array)

      input.map do |item|
        unless item.is_a?(Numeric) && item.finite?
          raise TypeError,
                "#{Value.type_of(item)} (#{JSON::Dumper.dump(item,
                                                             indent: nil)}) can't be imploded, unicode codepoint needs to be numeric"
        end

        codepoint = item.to_i
        codepoint = 0xFFFD if codepoint.negative? || codepoint > 0x10FFFF || codepoint.between?(0xD800, 0xDFFF)
        [codepoint].pack('U')
      end.join
    end

    def join(input, separator)
      out = +''
      assert_array(input).each_with_index do |item, index|
        out << separator.to_s if index.positive?
        case item
        when nil
          nil
        when String, Numeric, TrueClass, FalseClass
          out << to_string(item)
        else
          raise TypeError,
                "string (#{short_dump(out)}) and #{Value.type_of(item)} (#{short_dump(item)}) cannot be added"
        end
      end
      out
    end

    def short_dump(value)
      dumped = JSON::Dumper.dump(value, indent: nil)
      return "#{dumped[0, 11]}..." if value.is_a?(Hash) && dumped.length > 14

      dumped.length > 18 ? "#{dumped[0, 15]}..." : dumped
    end

    def recurse(input, context, args)
      return AST::Recurse.new.eval(input, context) if args.empty?

      out = []
      visit = lambda do |value|
        out << value
        args.first.eval(value, context).each { |child| visit.call(child) }
      end
      if args.length > 1
        visit = lambda do |value|
          out << value
          args.first.eval(value, context).each do |child|
            visit.call(child) if args[1].eval(child, context).any? { |result| Value.truthy?(result) }
          end
        end
      end
      visit.call(input)
      out
    end

    def delpaths(input, paths)
      raise TypeError, 'Paths must be specified as an array' unless paths.is_a?(Array)

      copy = Value.deep_copy(input)
      return nil if paths.any?(&:empty?)

      ordered_delete_paths(paths).each { |path| Path.delete(copy, path) }
      copy
    end

    def delete_paths(input, context, args)
      copy = Value.deep_copy(input)
      paths = args.flat_map { |arg| arg.paths(input, context) }
      return nil if paths.any?(&:empty?)

      ordered_delete_paths(paths).each { |path| Path.delete(copy, path) }
      copy
    end

    def pick(input, context, args)
      paths = args.flat_map { |arg| arg.paths(input, context) }
      return Value.deep_copy(input) if paths.any?(&:empty?)

      paths.each { |path| validate_pick_path(path) }
      root = nil
      paths.each do |path|
        root ||= container_for_path(path)
        Path.set(root, path, Value.deep_copy(Path.get(input, path)))
      end
      root
    end

    def validate_pick_path(path)
      return unless path.any? { |part| part.is_a?(Integer) && part.negative? }

      raise RuntimeError, 'Out of bounds negative array index'
    end

    def container_for_path(path)
      path.first.is_a?(Integer) ? [] : {}
    end

    def paths_builtin(input, context, args, leaves_only:)
      paths = Path.paths(input, leaves_only: leaves_only).reject(&:empty?)
      return paths if args.empty?

      filter = args.fetch(0)
      paths.select do |path|
        filter.eval(Path.get(input, path), context).any? { |value| Value.truthy?(value) }
      end
    end

    def walk(input, context, filter)
      transformed =
        case input
        when Array
          input.each_with_object([]) do |item, out|
            values = walk(item, context, filter)
            out << values.first unless values.empty?
          end
        when Hash
          input.each_with_object({}) do |(key, value), out|
            values = walk(value, context, filter)
            out[key] = values.first unless values.empty?
          end
        else
          input
        end
      filter.eval(transformed, context)
    end

    def to_stream(value)
      out = []
      visit = lambda do |current, path|
        if current.is_a?(Array)
          if current.empty?
            out << [path, []]
          else
            last_path = path
            current.each_with_index { |item, index| last_path = visit.call(item, path + [index]) }
            out << [last_path]
          end
        elsif current.is_a?(Hash)
          if current.empty?
            out << [path, {}]
          else
            last_path = path
            current.each { |key, item| last_path = visit.call(item, path + [key]) }
            out << [last_path]
          end
        else
          out << [path, current]
        end
        path
      end
      visit.call(value, [])
      out
    end

    def from_stream(stream)
      pairs = assert_array(stream)
      root = {}
      pairs.each do |pair|
        pair = assert_array(pair)
        next if pair.length == 1

        path, value = pair
        path = assert_array(path)
        if path.empty?
          root = value
        else
          root = [] if root == {} && path.first.is_a?(Integer)
          Path.set(root, path, value)
        end
      end
      root
    end

    def truncate_stream(input, context, args)
      depth = args.empty? ? numeric(input).to_i : numeric(eval_arg(args, 0, input, context)).to_i
      stream = args.length > 1 ? args[1].eval(input, context) : input
      assert_array(stream).map do |pair|
        pair = assert_array(pair)
        path = assert_array(pair.fetch(0))
        truncated = path.drop(depth)
        pair.length == 1 ? [truncated] : [truncated, pair.fetch(1)]
      end
    end

    def extreme(input, mode)
      array = assert_array(input)
      return nil if array.empty?

      array.public_send(mode) { |a, b| Value.compare(a, b) }
    end

    def extreme_by(input, context, filter, mode)
      array = assert_array(input)
      return nil if array.empty?

      best = array.first
      best_key = filter_key(best, context, filter)
      array.drop(1).each do |item|
        key = filter_key(item, context, filter)
        comparison = Value.compare(key, best_key)
        if (mode == :min && comparison.negative?) || (mode == :max && comparison >= 0)
          best = item
          best_key = key
        end
      end
      best
    end

    def sort_by_filter(input, context, filter)
      assert_array(input).sort { |a, b| Value.compare(filter_key(a, context, filter), filter_key(b, context, filter)) }
    end

    def group_by_filter(input, context, filter)
      sort_by_filter(input, context, filter).chunk do |item|
        filter_key(item, context, filter)
      end.map { |_key, values| values }
    end

    def unique_values(array)
      array = array.sort { |a, b| Value.compare(a, b) }
      out = []
      array.each do |item|
        out << item unless out.any? { |seen| Value.equal?(seen, item) }
      end
      out
    end

    def unique_by_filter(input, context, filter)
      seen = []
      sort_by_filter(input, context, filter).each_with_object([]) do |item, out|
        key = filter_key(item, context, filter)
        next if seen.any? { |value| Value.equal?(value, key) }

        seen << key
        out << item
      end
    end

    def index_sql(input, context, args)
      source =
        if args.length == 2
          args[0].eval(input, context)
        else
          assert_array(input)
        end
      filter = args.length == 2 ? args[1] : args.fetch(0)
      source.to_h do |item|
        [to_string(filter_key(item, context, filter)), item]
      end
    end

    def join_sql(input, context, args)
      index = eval_arg(args, 0, input, context)
      filter = args.fetch(1)
      assert_array(input).map do |item|
        key = to_string(filter_key(item, context, filter))
        [item, index[key]]
      end
    end

    def in_sql?(input, context, args)
      if args.length == 1
        values = args.fetch(0).eval(input, context)
        values = values.first if values.length == 1 && values.first.is_a?(Array)
        return values.any? { |item| Value.equal?(item, input) }
      end

      source = args.fetch(0).eval(input, context)
      needles = args.fetch(1).eval(input, context)
      needles.any? { |needle| source.any? { |item| Value.equal?(item, needle) } }
    end

    def filter_key(value, context, filter)
      result = filter.eval(value, context)
      result.length == 1 ? result.first : result
    end

    def contains?(container, contained)
      case [container, contained]
      in [Hash, Hash]
        contained.all? { |key, value| container.key?(key) && contains?(container[key], value) }
      in [Array, Array]
        contained.all? { |needle| container.any? { |item| contains?(item, needle) } }
      in [String, String]
        container.include?(contained)
      else
        Value.equal?(container, contained)
      end
    end

    def index_of(input, needle)
      if input.is_a?(String)
        return nil if assert_string(needle).empty?

        return input.index(assert_string(needle))
      end

      return unless input.is_a?(Array)

      needle = [needle] unless needle.is_a?(Array)
      max = input.length - assert_array(needle).length
      (0..max).find { |index| array_slice_equal?(input, needle, index) }
    end

    def rindex_of(input, needle)
      if input.is_a?(String)
        return nil if assert_string(needle).empty?

        return input.rindex(assert_string(needle))
      end

      return unless input.is_a?(Array)

      needle = [needle] unless needle.is_a?(Array)
      max = input.length - assert_array(needle).length
      max.downto(0).find { |index| array_slice_equal?(input, needle, index) }
    end

    def indices_of(input, needle)
      if input.is_a?(String)
        positions = []
        offset = 0
        needle = assert_string(needle)
        while (found = input.index(needle, offset))
          positions << found
          offset = found + 1
        end
        return positions
      end
      needle = [needle] unless needle.is_a?(Array)
      max = input.length - needle.length
      (0..max).select { |index| array_slice_equal?(input, needle, index) }
    end

    def array_slice_equal?(input, needle, index)
      needle.each_with_index.all? { |item, offset| Value.equal?(input[index + offset], item) }
    end

    def combinations(input, context, args)
      if args.length == 1 && eval_arg(args, 0, input, context).is_a?(Numeric)
        count = eval_arg(args, 0, input, context).to_i
        arrays = Array.new(count) { assert_array(input) }
      else
        source = args.empty? ? assert_array(input) : eval_arg(args, 0, input, context)
        arrays = assert_array(source)
      end
      arrays.reduce([[]]) do |acc, array|
        assert_array(array)
        acc.flat_map { |prefix| array.map { |item| prefix + [item] } }
      end
    end

    def transpose(input)
      rows = assert_array(input).map { |row| assert_array(row) }
      max = rows.map(&:length).max || 0
      (0...max).map { |index| rows.map { |row| row[index] } }
    end

    def bsearch(input, context, args)
      array = assert_array(input)
      args.flat_map do |arg|
        arg.eval(input, context).map do |needle|
          found = array.bsearch_index { |item| Value.compare(item, needle) >= 0 }
          found && Value.equal?(array[found], needle) ? found : -((found || array.length) + 1)
        end
      end
    end

    def first_builtin(input, context, args)
      values = args.empty? ? assert_array(input) : args.fetch(0).take(input, context, 1)
      values.empty? ? [] : [values.first]
    end

    def last_builtin(input, context, args)
      values = args.empty? ? assert_array(input) : args.fetch(0).eval(input, context)
      values.empty? ? [] : [values.last]
    end

    def nth(input, context, args)
      args.fetch(0).eval(input, context).flat_map do |raw_index|
        index = numeric(raw_index).to_i
        raise RuntimeError, "nth doesn't support negative indices" if index.negative?

        values = args.length > 1 ? args[1].eval(input, context) : assert_array(input)
        index >= values.length ? [] : [values[index]]
      end
    end

    def limit(input, context, args)
      args.fetch(0).eval(input, context).flat_map do |raw_count|
        count = numeric(raw_count).to_i
        next [] if count <= 0

        args.fetch(1).take(input, context, count)
      end
    end

    def until_filter(input, context, args)
      condition, update = args
      value = input
      guard = 0
      until condition.eval(value, context).any? { |item| Value.truthy?(item) }
        value = update.eval(value, context).first
        guard += 1
        raise RuntimeError, 'until exceeded iteration guard' if guard > 100_000
      end
      [value]
    end

    def while_filter(input, context, args)
      condition, update = args
      out = []
      value = input
      guard = 0
      while condition.eval(value, context).any? { |item| Value.truthy?(item) }
        out << value
        value = update.eval(value, context).first
        guard += 1
        raise RuntimeError, 'while exceeded iteration guard' if guard > 100_000
      end
      out
    end

    def repeat_filter(input, context, args)
      out = []
      value = input
      1000.times do
        out << value
        values = args.fetch(0).eval(value, context)
        break if values.empty?

        value = values.first
      end
      out
    end

    def time_array(time)
      [time.year, time.month - 1, time.day, time.hour, time.min, time.sec, time.wday, time.yday - 1]
    end

    def mktime(input)
      values = assert_array(input)
      raise TypeError, 'mktime requires parsed datetime inputs' unless values.first(6).all?(Numeric)

      Time.local(values[0], values[1] + 1, values[2], values[3], values[4], values[5]).to_f
    rescue ArgumentError
      raise TypeError, 'mktime requires parsed datetime inputs'
    end

    def strftime_builtin(input, context, args, local: false)
      format = assert_string(eval_arg(args, 0, input, context))
      time =
        if input.is_a?(Array)
          values = input
          unless values.first(6).all?(Numeric)
            raise TypeError,
                  "#{local ? 'strflocaltime' : 'strftime'}/1 requires parsed datetime inputs"
          end

          if local
            Time.local(values[0], values[1] + 1, values[2], values[3], values[4],
                       values[5])
          else
            Time.utc(values[0], values[1] + 1, values[2], values[3], values[4], values[5])
          end
        else
          raise TypeError, 'strflocaltime/1 requires parsed datetime inputs' if local

          Time.at(numeric(input)).utc
        end
      time.strftime(format)
    rescue ArgumentError
      raise TypeError, "#{local ? 'strflocaltime' : 'strftime'}/1 requires parsed datetime inputs"
    end

    def strptime(input, context, args)
      time_array(Time.strptime(assert_string(input), assert_string(eval_arg(args, 0, input, context))).utc)
    end

    def regexp(input, context, args)
      pattern, flags = regexp_parts(input, context, args)
      options = 0
      options |= Regexp::IGNORECASE if flags.include?('i')
      options |= Regexp::MULTILINE if flags.include?('m') || flags.include?('s')
      options |= Regexp::EXTENDED if flags.include?('x')
      [Regexp.new(pattern, options), flags]
    rescue RegexpError => e
      raise e.message.to_s
    end

    def regexp_parts(input, context, args)
      raw = eval_arg(args, 0, input, context)
      if raw.is_a?(Array)
        [assert_string(raw[0]), raw[1] ? assert_string(raw[1]) : '']
      else
        [assert_string(raw), args.length > 1 ? assert_string(eval_arg(args, 1, input, context)) : '']
      end
    end

    def match_builtin(input, context, args)
      string = assert_string(input)
      regex, flags = regexp(input, context, args)
      global = flags.include?('g')
      matches = global ? string.to_enum(:scan, regex).map { Regexp.last_match } : [regex.match(string)].compact
      matches = matches.reject { |match| match[0].empty? } if flags.include?('n')
      matches.map { |match| match_object(match) }
    end

    def match_object(match)
      {
        'offset' => match.begin(0),
        'length' => match[0].length,
        'string' => match[0],
        'captures' => (1...match.length).map do |index|
          value = match[index]
          if value.nil? && match[0].empty?
            value = ''
            offset = match.begin(0)
          else
            offset = value ? match.begin(index) : -1
          end
          { 'offset' => offset, 'length' => value ? value.length : 0, 'string' => value,
            'name' => capture_name(match, index) }
        end
      }
    end

    def capture_name(match, index)
      match.names.find { |name| match.regexp.named_captures.fetch(name).include?(index) }
    end

    def capture_builtin(input, context, args)
      regex, = regexp(input, context, args)
      match = regex.match(assert_string(input))
      return [] unless match

      [match.names.to_h { |name| [name, match[name]] }]
    end

    def scan_builtin(input, context, args)
      regex, = regexp(input, context, args)
      assert_string(input).scan(regex).map { |item| item.is_a?(Array) && item.length == 1 ? item.first : item }
    end

    def substitute(input, context, args, global:)
      string = assert_string(input)
      regex, = regexp(input, context, [args.fetch(0)] + args[2..].to_a)
      replacement_filters(args.fetch(1)).map do |replacement_filter|
        if global
          gsub_with_filter(string, regex, replacement_filter,
                           context)
        else
          sub_with_filter(string, regex, replacement_filter, context)
        end
      end
    end

    def replacement_filters(node)
      return node.replacement_filters if node.respond_to?(:replacement_filters)
      return replacement_filters(node.left) + replacement_filters(node.right) if node.is_a?(AST::Comma)

      [node]
    end

    def sub_with_filter(string, regex, replacement_filter, context)
      match = regex.match(string)
      return string unless match

      string[0...match.begin(0)] + replacement_for(replacement_filter, match, context) + string[match.end(0)..].to_s
    end

    def gsub_with_filter(string, regex, replacement_filter, context)
      out = +''
      offset = 0
      string.to_enum(:scan, regex).each do
        match = Regexp.last_match
        out << string[offset...match.begin(0)].to_s
        out << replacement_for(replacement_filter, match, context)
        offset = match.end(0)
      end
      out << string[offset..].to_s
    end

    def replacement_for(replacement_filter, match, context)
      assert_string(replacement_filter.eval(capture_values(match), context).first)
    end

    def capture_values(match)
      match.names.to_h { |name| [name, match[name]] }
    end

    def splits_builtin(input, context, args)
      string = assert_string(input)
      pattern, = regexp_parts(input, context, args)
      return [''] + string.each_char.to_a + [''] if pattern.empty?

      regex, = regexp(input, context, args)
      string.split(regex, -1)
    end

    def format_csv(input)
      assert_array(input).map { |item| csv_field(item) }.join(',')
    end

    def html_escape(input)
      CGI.escapeHTML(input).gsub('&#39;', '&apos;')
    end

    def csv_field(item)
      text = item.nil? ? '' : to_string(item)
      needs_quotes = text.match?(/[",\r\n]/)
      escaped = text.gsub('"', '""')
      needs_quotes ? "\"#{escaped}\"" : escaped
    end

    def format_tsv(input)
      assert_array(input).map do |item|
        to_string(item).gsub("\t", '\\t').gsub("\n", '\\n').gsub("\r", '\\r')
      end.join("\t")
    end

    def format_sh(input)
      values = input.is_a?(Array) ? input : [input]
      values.map { |item| sh_quote(to_string(item)) }.join(' ')
    end

    def sh_quote(input)
      "'#{input.gsub("'", "'\\\\''")}'"
    end

    def uri_escape(input)
      input.bytes.map do |byte|
        char = byte.chr
        char.match?(/[A-Za-z0-9_.~-]/) ? char : '%%%02X' % byte
      end.join
    end

    def base32_encode(input)
      alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
      bits = input.bytes.map { |byte| byte.to_s(2).rjust(8, '0') }.join
      bits += '0' * ((5 - (bits.length % 5)) % 5)
      encoded = bits.scan(/.{5}/).map { |chunk| alphabet[chunk.to_i(2)] }.join
      encoded + ('=' * ((8 - (encoded.length % 8)) % 8))
    end

    def base32_decode(input)
      alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
      clean = input.upcase.delete('=')
      bits = clean.each_char.map do |char|
        index = alphabet.index(char)
        raise RuntimeError, "invalid base32 character #{char.inspect}" unless index

        index.to_s(2).rjust(5, '0')
      end.join
      bits[0, (bits.length / 8) * 8].scan(/.{8}/).map { |chunk| chunk.to_i(2) }.pack('C*')
    end

    def input_values(input, context, filter)
      case input
      when Array
        input.flat_map { |item| filter.eval(item, context) }
      else
        filter.eval(input, context)
      end
    end

    def source_any?(node, input, context, &)
      return node.source_any?(input, context, &) if node.respond_to?(:source_any?)

      if node.is_a?(AST::Comma)
        return true if source_any?(node.left, input, context, &)

        return source_any?(node.right, input, context, &)
      end
      node.eval(input, context).any?(&)
    end

    def source_all?(node, input, context, &)
      return node.source_all?(input, context, &) if node.respond_to?(:source_all?)

      if node.is_a?(AST::Comma)
        return false unless source_all?(node.left, input, context, &)

        return source_all?(node.right, input, context, &)
      end
      node.eval(input, context).all?(&)
    end

    def eval_arg(args, index, input, context)
      raise RuntimeError, "missing argument #{index}" unless args[index]

      args[index].eval(input, context).first
    end

    def ordered_delete_paths(paths)
      paths.sort do |left, right|
        parent_cmp = Value.compare(left[0...-1], right[0...-1])
        next parent_cmp unless parent_cmp.zero?

        left_key = left.last
        right_key = right.last
        if left_key.is_a?(Integer) && right_key.is_a?(Integer)
          right_key <=> left_key
        else
          Value.compare(right, left)
        end
      end
    end

    def builtin_arities(name)
      BUILTIN_ARITIES.fetch(name, []).map { |arity| "#{name}/#{arity}" }
    end

    def valid_arity?(name, arity)
      BUILTIN_ARITIES.fetch(name, []).include?(arity)
    end

    def modulemeta(input, context)
      metadata = context.options.fetch(:module_metadata, {})
      raise RuntimeError, "module not found: #{input}" unless metadata.key?(input)

      metadata.fetch(input)
    end

    def assert_array(value)
      raise TypeError, "expected array, got #{Value.type_of(value)}" unless value.is_a?(Array)

      value
    end

    def assert_string(value)
      raise TypeError, "expected string, got #{Value.type_of(value)}" unless value.is_a?(String)

      value
    end

    def numeric(value)
      raise TypeError, "expected number, got #{Value.type_of(value)}" unless value.is_a?(Numeric)

      value
    end
  end
end
