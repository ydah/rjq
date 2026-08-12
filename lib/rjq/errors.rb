# frozen_string_literal: true

module Rjq
  class Error < StandardError; end

  class ParseError < Error; end

  class CompileError < Error; end

  class RuntimeError < Error
    attr_reader :outputs

    def prepend_outputs(values)
      @outputs = Array(values) + Array(@outputs)
      self
    end

    def take_outputs
      values = Array(@outputs)
      @outputs = nil
      values
    end
  end

  # Execution budgets are process-safety boundaries and cannot be caught by
  # jq filters such as `try` or `?`.
  class ResourceLimitError < RuntimeError; end

  class TypeError < RuntimeError; end

  class InvalidPathError < TypeError
    attr_reader :result

    def initialize(message, result, outputs: nil)
      @result = result
      prepend_outputs(outputs)
      super(message)
    end
  end

  class ErrorValue < RuntimeError
    attr_reader :value

    def initialize(value, outputs: nil)
      @value = value
      super(value.to_s)
      prepend_outputs(outputs)
    end
  end

  # Halting terminates the whole jq program. It is deliberately not a
  # RuntimeError: try/catch and the optional operator only catch ordinary
  # filter failures.
  class HaltError < Error
    attr_reader :value, :status

    def initialize(value = nil, status = 0)
      @value = value
      @status = status
      super(value.nil? ? 'halt_error' : value.to_s)
    end
  end

  class JSONParseError < Error; end

  class BreakSignal < RuntimeError
    attr_reader :label, :value, :outputs

    def initialize(label, value = nil, outputs: nil)
      @label = label
      @value = value
      @outputs = outputs
      super("break #{label}")
    end
  end
end
