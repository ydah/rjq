# frozen_string_literal: true

require 'cgi'
require 'date'
require 'time'
require 'uri'

module Rjq
  module Builtins
    ZERO_ARITY_BUILTINS = %w[
      empty length utf8bytelength type keys keys_unsorted values arrays objects iterables scalars booleans nulls
      numbers strings not error halt halt_error input inputs debug stderr input_filename input_line_number null true
      false infinite nan isinfinite isnan isnormal add any all flatten floor ceil round sqrt log log2 log10 exp exp2 exp10
      pow10 atan abs cos sin tan acos asin cosh sinh tanh acosh asinh atanh cbrt significand logb gamma tgamma
      lgamma lgamma_r frexp modf fabs nearbyint trunc rint j0 j1 y0 y1 erf erfc expm1 log1p isfinite finites normals
      get_jq_origin get_prog_origin get_search_list to_entries from_entries to_number tonumber
      tostring tojson fromjson ascii explode implode ascii_downcase ascii_upcase recurse recurse_down paths leaf_paths
      tostream min max sort unique reverse combinations transpose first last env now gmtime localtime mktime fromdate
      todate fromdateiso8601 todateiso8601 date builtins modulemeta
    ].freeze
    ONE_ARITY_BUILTINS = %w[
      has in IN INDEX error halt_error debug flatten range any all with_entries select map map_values split join
      ltrimstr rtrimstr startswith endswith index rindex indices recurse recurse_down path paths leaf_paths getpath
      delpaths del pick walk fromstream truncate_stream min_by max_by sort_by group_by GROUP_BY unique_by UNIQUE_BY
      contains inside combinations bsearch first last nth repeat isempty strftime strflocaltime strptime dateadd datesub
      test match capture scan splits format
    ].freeze
    TWO_ARITY_BUILTINS = %w[
      IN INDEX JOIN any all range recurse recurse_down pow atan2 ldexp scalb scalbln drem setpath nth limit until while split test match
      scan splits sub gsub capture copysign fdim fmax fmin fmod hypot jn nextafter nexttoward remainder yn
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
      'GROUP_BY' => [0], 'unique_by' => [0], 'UNIQUE_BY' => [0], 'first' => [0], 'last' => [0], 'nth' => [0, 1],
      'limit' => [1], 'until' => [0, 1], 'while' => [0, 1], 'repeat' => [0], 'isempty' => [0],
      'sub' => [1], 'gsub' => [1]
    }.transform_values(&:freeze).freeze

    module_function

    def call(name, input, context, args)
      call_stream(name, input, context, args).to_a
    end

    def call_stream(name, input, context, args)
      argument_sets = args.each_with_index.map do |argument, index|
        if FILTER_ARGUMENT_POSITIONS.fetch(name, []).include?(index)
          [argument]
        else
          argument.eval(input, context).map { |value| AST::Literal.new(value) }
        end
      end
      Enumerator.new do |yielder|
        cartesian(argument_sets).each do |resolved_args|
          dispatch(name, input, context, resolved_args).each { |value| yielder << value }
        end
      end
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
        filename = current_input_record(context)&.filename || context.options.fetch(:current_filename, '<stdin>')
        [filename || '<stdin>']
      when 'input_line_number'
        [current_input_record(context)&.line || context.options.fetch(:current_line, 1)]
      when 'debug', 'stderr'
        emit_diagnostic(name, input, context, args)
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
        [normal_number?(input)]
      when 'isfinite'
        [input.is_a?(Numeric) && input.to_f.finite?]
      when 'finites'
        input.is_a?(Numeric) && input.to_f.finite? ? [input] : []
      when 'normals'
        normal_number?(input) ? [input] : []
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
           'rint', 'frexp', 'modf', 'lgamma_r', 'j0', 'j1', 'y0', 'y1', 'erf', 'erfc', 'expm1', 'log1p'
        [math_unary(name, input)]
      when 'pow', 'atan2', 'ldexp', 'scalb', 'scalbln', 'fma', 'drem', 'copysign', 'fdim', 'fmax', 'fmin',
           'fmod', 'hypot', 'jn', 'nextafter', 'nexttoward', 'remainder', 'yn'
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
      when 'format'
        format_builtin(input, context, args)
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
        [decode_base64(input)]
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
      when 'get_jq_origin'
        [context.options.fetch(:jq_origin, File.expand_path('../..', __dir__))]
      when 'get_prog_origin'
        source_path = context.options[:source_path]
        [source_path ? File.dirname(File.expand_path(source_path)) : Dir.pwd]
      when 'get_search_list'
        [search_list(context)]
      else
        raise CompileError, "#{name}/#{args.length} is not defined"
      end
    rescue RegexpError => e
      raise unless defined?(Regexp::TimeoutError) && e.is_a?(Regexp::TimeoutError)

      raise Rjq::RuntimeError, 'regular expression match timeout'
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
      return queue.each_remaining if queue

      context.options.fetch(:remaining_inputs, [])
    end

    def current_input_record(context)
      context.options[:input_queue]&.current_record
    end

    def emit_diagnostic(name, input, context, args)
      io = context.options[:stderr] || $stderr
      diagnostic = args.empty? ? input : eval_arg(args, 0, input, context)
      if name == 'debug'
        io.puts(JSON::Dumper.dump(['DEBUG:', diagnostic], indent: nil))
      else
        io.puts(to_string(diagnostic))
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
      numbers = args.map { |arg| numeric(arg.eval(input, context).first) }
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

    def range_values(from, to, step)
      Enumerator.new do |yielder|
        current = from
        comparison = step.positive? ? -> { current < to } : -> { current > to }
        while comparison.call
          yielder << current
          current += step
        end
      end
    end

    def cartesian(sets)
      return [[]] if sets.empty?

      sets.reduce([[]]) do |acc, values|
        acc.flat_map { |prefix| values.map { |value| prefix + [value] } }
      end
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
      when 'nearbyint', 'rint' then round_to_even(value)
      when 'j0', 'j1', 'y0', 'y1' then MathFunctions.bessel(name, value)
      when 'erf' then Math.erf(value)
      when 'erfc' then Math.erfc(value)
      when 'expm1' then Math.expm1(value)
      when 'log1p' then Math.log1p(value)
      end
    rescue Math::DomainError
      Float::NAN
    end

    def math_nary(name, input, context, args)
      values = args.empty? ? [numeric(input)] : args.map { |arg| numeric(arg.eval(input, context).first) }
      case name
      when 'pow' then values[0]**values[1]
      when 'atan2' then Math.atan2(values[0], values[1])
      when 'ldexp' then Math.ldexp(values[0], values[1].to_i)
      when 'scalb' then MathFunctions.scalb(values[0], values[1])
      when 'scalbln' then MathFunctions.scalbln(values[0], values[1])
      when 'fma' then MathFunctions.fma(values[0], values[1], values[2])
      when 'drem' then MathFunctions.remainder(values[0], values[1])
      when 'copysign' then copy_sign(values[0], values[1])
      when 'fdim' then values.any? { |value| value.to_f.nan? } ? Float::NAN : [values[0] - values[1], 0].max
      when 'fmax' then float_extreme(values[0], values[1], :max)
      when 'fmin' then float_extreme(values[0], values[1], :min)
      when 'fmod' then values[0].remainder(values[1])
      when 'hypot' then Math.hypot(values[0], values[1])
      when 'jn', 'yn' then MathFunctions.bessel(name, values[0].to_i, values[1])
      when 'nextafter', 'nexttoward' then next_float_toward(values[0], values[1])
      when 'remainder' then MathFunctions.remainder(values[0], values[1])
      end
    rescue Math::DomainError, FloatDomainError, ZeroDivisionError
      Float::NAN
    end

    def normal_number?(value)
      return false unless value.is_a?(Numeric)

      float = value.to_f
      float.finite? && float.abs >= Float::MIN
    end

    def round_to_even(value)
      rounded = value.to_f.round(half: :even)
      rounded.zero? && value.to_f.negative? ? -0.0 : rounded
    end

    def copy_sign(magnitude, sign)
      negative = sign.to_f.negative? || (sign.to_f.zero? && (1.0 / sign.to_f).negative?)
      negative ? -magnitude.to_f.abs : magnitude.to_f.abs
    end

    def float_extreme(left, right, mode)
      return right if left.to_f.nan?
      return left if right.to_f.nan?

      [left, right].public_send(mode)
    end

    def next_float_toward(value, target)
      value = value.to_f
      target = target.to_f
      return target if value == target
      return Float::NAN if value.nan? || target.nan?

      value < target ? value.next_float : value.prev_float
    end

    def ieee_remainder(left, right)
      quotient = (left.to_f / right.to_f).round(half: :even)
      left.to_f - (right.to_f * quotient)
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
      if args.length > 1
        regex, flags = regexp(input, context, args)
        matches = string.to_enum(:scan, regex).map { Regexp.last_match }
        matches.reject! { |match| match[0].empty? } if flags.include?('n')
        return split_at_matches(string, matches)
      end

      separator = assert_string(eval_arg(args, 0, input, context))
      return string.each_char.to_a if separator.empty?

      string.split(separator, -1)
    end

    def split_at_matches(string, matches)
      return [string] if matches.empty?

      offset = 0
      matches.map do |match|
        part = string[offset...match.begin(0)].to_s
        offset = match.end(0)
        part
      end << string[offset..].to_s
    end

    def implode(input)
      raise TypeError, 'implode input must be an array' unless input.is_a?(Array)

      input.map do |item|
        unless item.is_a?(Numeric) && !item.to_f.nan?
          raise TypeError,
                "#{Value.type_of(item)} (#{JSON::Dumper.dump(item,
                                                             indent: nil)}) can't be imploded, unicode codepoint needs to be numeric"
        end

        codepoint = item.to_f.finite? ? item.to_i : -1
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
      Enumerator.new do |yielder|
        stack = [[input].each]
        until stack.empty?
          begin
            value = stack.last.next
          rescue StopIteration
            stack.pop
            next
          end
          yielder << value
          children = if args.empty?
                       case value
                       when Array then value.each
                       when Hash then value.each_value
                       else [].each
                       end
                     else
                       filter_stream(args.first, value, context)
                     end
          if args.length > 1
            condition = args[1]
            source_children = children
            children = Enumerator.new do |child_yielder|
              source_children.each do |child|
                filter_stream(condition, child, context).each do |result|
                  child_yielder << child if Value.truthy?(result)
                end
              end
            end
          end
          stack << children.each
        end
      end
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
      Enumerator.new do |yielder|
        stack = [[:visit, value, []]]
        until stack.empty?
          type, current, path = stack.pop
          if type == :emit
            yielder << current
            next
          end

          children = if current.is_a?(Array)
                       current.each_with_index.map { |item, index| [item, path + [index]] }
                     elsif current.is_a?(Hash)
                       current.map { |key, item| [item, path + [key]] }
                     end
          if children.nil?
            yielder << [path, current]
          elsif children.empty?
            yielder << [path, current.class.new]
          else
            last_component = current.is_a?(Array) ? current.length - 1 : current.keys.last
            stack << [:emit, [path + [last_component]], nil]
            children.reverse_each { |child, child_path| stack << [:visit, child, child_path] }
          end
        end
      end
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
      depth = input
      Enumerator.new do |yielder|
        filter_stream(args.fetch(0), nil, context).each do |event|
          path = Path.read_index(event, 0)
          next unless Value.compare(length(path), depth).positive?

          updated = event.nil? ? [] : event.dup
          updated[0] = truncate_path(path, depth)
          yielder << updated
        end
      end
    end

    def truncate_path(path, depth)
      return nil if path.nil?
      unless path.is_a?(Array) || path.is_a?(String)
        raise TypeError, "Cannot index #{Value.type_of(path)} with object"
      end

      start = truncate_boundary(depth, path.is_a?(String) ? path.each_char.count : path.length)
      return path.each_char.drop(start).join if path.is_a?(String)

      path.drop(start)
    end

    def truncate_boundary(depth, length)
      return 0 if depth.nil? || (depth.respond_to?(:nan?) && depth.nan?)
      raise TypeError, 'Array/string slice indices must be integers' unless depth.is_a?(Numeric)
      return depth.negative? ? 0 : length if depth.respond_to?(:infinite?) && depth.infinite?

      index = depth.floor
      index += length if index.negative?
      [[index, 0].max, length].min
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
      decorated_sort(input, context, filter).map(&:first)
    end

    def group_by_filter(input, context, filter)
      decorated_sort(input, context, filter).each_with_object([]) do |(item, key), groups|
        if groups.empty? || !Value.equal?(groups.last.fetch(:key), key)
          groups << { key: key, values: [item] }
        else
          groups.last.fetch(:values) << item
        end
      end.map { |group| group.fetch(:values) }
    end

    def unique_values(array)
      array = array.sort { |a, b| Value.compare(a, b) }
      array.each_with_object([]) do |item, out|
        out << item if out.empty? || !Value.equal?(out.last, item)
      end
    end

    def unique_by_filter(input, context, filter)
      unique = decorated_sort(input, context, filter).each_with_object([]) do |(item, key), out|
        out << [item, key] if out.empty? || !Value.equal?(out.last.last, key)
      end
      unique.map(&:first)
    end

    def decorated_sort(input, context, filter)
      assert_array(input).each_with_index.map do |item, index|
        [item, filter_key(item, context, filter), index]
      end.sort do |left, right|
        comparison = Value.compare(left[1], right[1])
        comparison.zero? ? left[2] <=> right[2] : comparison
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
      tasks = [[:evaluate, container, contained]]
      results = []
      until tasks.empty?
        action, *values = tasks.pop
        case action
        when :evaluate
          candidate, needle = values
          if candidate.is_a?(Hash) && needle.is_a?(Hash)
            entries = needle.to_a
            unless entries.all? { |key, _value| candidate.key?(key) }
              results << false
              next
            end

            tasks << [:hash_all, candidate, entries, 0]
          elsif candidate.is_a?(Array) && needle.is_a?(Array)
            tasks << [:array_all, candidate, needle, 0]
          elsif candidate.is_a?(String) && needle.is_a?(String)
            results << candidate.include?(needle)
          else
            results << Value.equal?(candidate, needle)
          end
        when :hash_all
          candidate, entries, index = values
          if index >= entries.length
            results << true
          else
            key, needle = entries[index]
            tasks << [:hash_after, candidate, entries, index]
            tasks << [:evaluate, candidate.fetch(key), needle]
          end
        when :hash_after
          candidate, entries, index = values
          if results.pop
            tasks << [:hash_all, candidate, entries, index + 1]
          else
            results << false
          end
        when :array_all
          candidate, needles, needle_index = values
          if needle_index >= needles.length
            results << true
          elsif candidate.empty?
            results << false
          else
            tasks << [:array_all_after, candidate, needles, needle_index]
            tasks << [:array_any, candidate, needles.fetch(needle_index), 0]
          end
        when :array_all_after
          candidate, needles, needle_index = values
          if results.pop
            tasks << [:array_all, candidate, needles, needle_index + 1]
          else
            results << false
          end
        when :array_any
          candidate, needle, candidate_index = values
          if candidate_index >= candidate.length
            results << false
          else
            tasks << [:array_any_after, candidate, needle, candidate_index]
            tasks << [:evaluate, candidate.fetch(candidate_index), needle]
          end
        when :array_any_after
          candidate, needle, candidate_index = values
          if results.pop
            results << true
          else
            tasks << [:array_any, candidate, needle, candidate_index + 1]
          end
        end
      end
      results.fetch(0)
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
        return [] if needle.empty?

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
        return [[]] if count.negative?

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
      Enumerator.new do |yielder|
        filter_stream(args.fetch(0), input, context).each do |raw_index|
          if args.length == 1
            yielder << nth_index_value(input, raw_index)
            next
          end

          index = nth_filter_index(raw_index)
          if index.respond_to?(:infinite?) && index.infinite?
            filter_stream(args[1], input, context).each { |_value| nil }
            next
          end

          values = args[1].take(input, context, index + 1)
          yielder << values[index] if index < values.length
        end
      end
    end

    def nth_index_value(input, raw_index)
      index = if raw_index.is_a?(Numeric) && (!raw_index.respond_to?(:finite?) || raw_index.finite?)
                raw_index.to_i
              else
                raw_index
              end
      Path.read_index(input, index)
    end

    def nth_filter_index(value)
      if value.is_a?(Numeric)
        raise RuntimeError, "nth doesn't support negative indices" if value.respond_to?(:nan?) && value.nan?
        raise RuntimeError, "nth doesn't support negative indices" if value < 0
        return value if value.respond_to?(:infinite?) && value.infinite?

        return value.ceil
      end
      if value.nil? || value == true || value == false
        raise RuntimeError, "nth doesn't support negative indices"
      end

      raise TypeError,
            "#{Value.type_of(value)} (#{short_dump(value)}) and number (1) cannot be added"
    end

    def limit(input, context, args)
      args.fetch(0).eval(input, context).flat_map do |raw_count|
        count = numeric(raw_count).ceil
        next [] if count <= 0

        args.fetch(1).take(input, context, count)
      end
    end

    def until_filter(input, context, args)
      condition, update = args
      Enumerator.new do |yielder|
        tasks = [[:visit, input]]
        until tasks.empty?
          type, value = tasks.pop
          if type == :emit
            yielder << value
            next
          end

          actions = condition.eval(value, context).flat_map do |result|
            if Value.truthy?(result)
              [[:emit, value]]
            else
              update.eval(value, context).map { |next_value| [:visit, next_value] }
            end
          end
          tasks.concat(actions.reverse)
        end
      end
    end

    def while_filter(input, context, args)
      condition, update = args
      Enumerator.new do |yielder|
        tasks = [[:visit, input]]
        until tasks.empty?
          type, value = tasks.pop
          if type == :emit
            yielder << value
            next
          end

          actions = condition.eval(value, context).flat_map do |result|
            next [] unless Value.truthy?(result)

            [[:emit, value]] + update.eval(value, context).map { |next_value| [:visit, next_value] }
          end
          tasks.concat(actions.reverse)
        end
      end
    end

    def repeat_filter(input, context, args)
      Enumerator.new do |yielder|
        loop do
          args.fetch(0).eval(input, context).each { |value| yielder << value }
        end
      end
    end

    def time_array(time)
      [time.year, time.month - 1, time.day, time.hour, time.min, time.sec, time.wday, time.yday - 1]
    end

    def mktime(input)
      values = assert_array(input)
      raise TypeError, 'mktime requires parsed datetime inputs' unless values.first(6).all?(Numeric)

      Time.utc(values[0], values[1] + 1, values[2], values[3], values[4], values[5]).to_f
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
      parsed = DateTime.strptime(assert_string(input), assert_string(eval_arg(args, 0, input, context)))
      [parsed.year, parsed.month - 1, parsed.day, parsed.hour, parsed.min, parsed.sec, parsed.wday, parsed.yday - 1]
    rescue Date::Error
      raise RuntimeError, 'date does not match format'
    end

    def regexp(input, context, args)
      pattern, flags = regexp_parts(input, context, args)
      unknown_flags = flags.each_char.uniq - %w[g i m n p s l x]
      raise RuntimeError, "unsupported regular expression flag: #{unknown_flags.first}" unless unknown_flags.empty?

      dot_matches_newline = flags.include?('m') || flags.include?('p')
      pattern = jq_regexp_pattern(pattern, dot_matches_newline: dot_matches_newline)
      options = 0
      options |= Regexp::IGNORECASE if flags.include?('i')
      options |= Regexp::MULTILINE if flags.include?('m') || flags.include?('p')
      options |= Regexp::EXTENDED if flags.include?('x')
      timeout = context.options[:regexp_timeout]
      regex = if timeout.nil?
                Regexp.new(pattern, options)
              elsif Regexp.respond_to?(:timeout)
                Regexp.new(pattern, options, timeout: timeout)
              else
                raise RuntimeError, 'regular expression timeout is not supported by this Ruby'
              end
      [regex, flags]
    rescue RegexpError, ArgumentError => e
      raise RuntimeError, e.message.to_s
    end

    def jq_regexp_pattern(pattern, dot_matches_newline:)
      chars = pattern.each_char.to_a
      transformed, = transform_regexp_segment(chars, 0, line_anchors: false,
                                                        dot_matches_newline: dot_matches_newline)
      transformed
    end

    def transform_regexp_segment(chars, index, line_anchors:, dot_matches_newline:, stop_at_group_end: false)
      output = +''
      while index < chars.length
        char = chars[index]
        if char == '\\'
          output << char
          index += 1
          output << chars[index] if index < chars.length
        elsif char == '['
          character_class, index = consume_regexp_character_class(chars, index)
          output << character_class
          next
        elsif char == '(' && (inline = scoped_regexp_options(chars, index))
          enabled, disabled, body_index = inline
          child_line_anchors = option_state(line_anchors, enabled, disabled, 'm')
          child_dot_matches_newline = option_state(dot_matches_newline, enabled, disabled, 's')
          body, next_index, closed = transform_regexp_segment(
            chars, body_index, line_anchors: child_line_anchors,
                               dot_matches_newline: child_dot_matches_newline, stop_at_group_end: true
          )
          output << if closed
                      ruby_regexp_group(enabled, disabled, dot_matches_newline, child_dot_matches_newline, body)
                    else
                      chars[index...body_index].join + body
                    end
          index = next_index
          next
        elsif char == '('
          body, next_index, closed = transform_regexp_segment(
            chars, index + 1, line_anchors: line_anchors,
                              dot_matches_newline: dot_matches_newline, stop_at_group_end: true
          )
          output << "(#{body}"
          output << ')' if closed
          index = next_index
          next
        elsif char == ')' && stop_at_group_end
          return [output, index + 1, true]
        elsif char == '^'
          output << (line_anchors ? '^' : '\\A')
        elsif char == '$'
          output << (line_anchors ? '$' : '\\Z')
        else
          output << char
        end
        index += 1
      end
      [output, index, !stop_at_group_end]
    end

    def consume_regexp_character_class(chars, index)
      output = +'['
      index += 1
      if chars[index] == '^'
        output << '^'
        index += 1
      end
      if chars[index] == ']'
        output << '\\]'
        index += 1
      end
      while index < chars.length
        char = chars[index]
        if char == '\\'
          output << char
          index += 1
          output << chars[index] if index < chars.length
        elsif char == '[' && %w[: . =].include?(chars[index + 1])
          marker = chars[index + 1]
          closing = "#{marker}]"
          while index < chars.length
            output << chars[index]
            index += 1
            next unless output.end_with?(closing)

            break
          end
          next
        elsif char == ']'
          output << char
          return [output, index + 1]
        else
          output << char
        end
        index += 1
      end
      [output, index]
    end

    def scoped_regexp_options(chars, index)
      return unless chars[index, 2] == ['(', '?']

      cursor = index + 2
      enabled = +''
      while cursor < chars.length && %w[i m s x].include?(chars[cursor])
        enabled << chars[cursor]
        cursor += 1
      end
      disabled = +''
      if chars[cursor] == '-'
        cursor += 1
        while cursor < chars.length && %w[i m s x].include?(chars[cursor])
          disabled << chars[cursor]
          cursor += 1
        end
      end
      return unless chars[cursor] == ':' && !(enabled.empty? && disabled.empty?)

      [enabled, disabled, cursor + 1]
    end

    def option_state(current, enabled, disabled, option)
      return true if enabled.include?(option)
      return false if disabled.include?(option)

      current
    end

    def ruby_regexp_group(enabled, disabled, parent_dotall, child_dotall, body)
      ruby_enabled = enabled.each_char.select { |option| %w[i x].include?(option) }
      ruby_disabled = disabled.each_char.select { |option| %w[i x].include?(option) }
      ruby_enabled << 'm' if child_dotall && !parent_dotall
      ruby_disabled << 'm' if parent_dotall && !child_dotall
      options = ruby_enabled.join
      options += "-#{ruby_disabled.join}" unless ruby_disabled.empty?
      options.empty? ? "(?:#{body})" : "(?#{options}:#{body})"
    end

    def format_builtin(input, context, args)
      format_name = assert_string(eval_arg(args, 0, input, context))
      supported = %w[text json html uri csv tsv sh base64 base64d]
      raise RuntimeError, "format #{format_name.inspect} is not supported" unless supported.include?(format_name)

      dispatch("@#{format_name}", input, context, [])
    end

    def search_list(context)
      configured = context.options.fetch(:library_path, [])
      return configured.map { |path| File.expand_path(path) } unless configured.empty?

      environment = ENV.fetch('JQ_LIBRARY_PATH', '').split(File::PATH_SEPARATOR).reject(&:empty?)
      (environment + [File.expand_path('~/.jq'), File.expand_path('~/.rjq')]).uniq
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
      replacement_filters(args.fetch(1)).flat_map do |replacement_filter|
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
      return [string] unless match

      replacements_for(replacement_filter, match, context).map do |replacement|
        string[0...match.begin(0)] + replacement + string[match.end(0)..].to_s
      end
    end

    def gsub_with_filter(string, regex, replacement_filter, context)
      matches = string.to_enum(:scan, regex).map { Regexp.last_match }
      return [string] if matches.empty?

      first_replacements = replacements_for(replacement_filter, matches.first, context)
      first_replacements.each_index.filter_map do |branch|
        out = +''
        offset = 0
        complete = matches.each_with_index.all? do |match, index|
          replacements = index.zero? ? first_replacements : replacements_for(replacement_filter, match, context)
          replacement = replacements[branch]
          next false unless replacement

          out << string[offset...match.begin(0)].to_s
          out << replacement
          offset = match.end(0)
          true
        end
        next unless complete

        out << string[offset..].to_s
      end
    end

    def replacements_for(replacement_filter, match, context)
      replacement_filter.eval(capture_values(match), context).map { |value| assert_string(value) }
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
      return '' if item.nil?
      return to_string(item) if item.is_a?(Numeric) || item == true || item == false
      unless item.is_a?(String)
        raise TypeError, "#{Value.type_of(item)} (#{short_dump(item)}) is not valid in a csv row"
      end

      "\"#{item.gsub('"', '""')}\""
    end

    def format_tsv(input)
      assert_array(input).map do |item|
        next '' if item.nil?
        next to_string(item) if item.is_a?(Numeric) || item == true || item == false
        unless item.is_a?(String)
          raise TypeError, "#{Value.type_of(item)} (#{short_dump(item)}) is not valid in a tsv row"
        end

        item.gsub("\t", '\\t').gsub("\n", '\\n').gsub("\r", '\\r')
      end.join("\t")
    end

    def format_sh(input)
      values = input.is_a?(Array) ? input : [input]
      values.map do |item|
        case item
        when String then sh_quote(item)
        when Numeric, TrueClass, FalseClass, NilClass then to_string(item)
        else
          raise TypeError, "#{Value.type_of(item)} (#{short_dump(item)}) can not be escaped for shell"
        end
      end.join(' ')
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
      encoded = +''
      buffer = 0
      bits = 0
      input.each_byte do |byte|
        buffer = (buffer << 8) | byte
        bits += 8
        while bits >= 5
          bits -= 5
          encoded << alphabet[(buffer >> bits) & 31]
        end
        buffer &= (1 << bits) - 1
      end
      encoded << alphabet[(buffer << (5 - bits)) & 31] if bits.positive?
      encoded + ('=' * ((8 - (encoded.length % 8)) % 8))
    end

    def decode_base64(input)
      string = assert_string(input)
      string.unpack1('m0').force_encoding(Encoding::UTF_8)
    rescue ArgumentError
      raise RuntimeError, "string (#{JSON::Dumper.dump(input, indent: nil)}) is not valid base64 data"
    end

    def base32_decode(input)
      alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
      clean = input.upcase.delete('=')
      output = +''.b
      buffer = 0
      bits = 0
      clean.each_char do |char|
        index = alphabet.index(char)
        raise RuntimeError, "invalid base32 character #{char.inspect}" unless index

        buffer = (buffer << 5) | index
        bits += 5
        if bits >= 8
          bits -= 8
          output << ((buffer >> bits) & 0xFF)
          buffer &= (1 << bits) - 1
        end
      end
      output
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

    def filter_stream(filter, input, context)
      return filter.stream(input, context) if filter.respond_to?(:stream)

      filter.eval(input, context).each
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
