# frozen_string_literal: true

require 'fiddle/import'

module Rjq
  module MathFunctions
    CANDIDATE_LIBRARIES = [
      '/usr/lib/libSystem.B.dylib',
      'libm.so.6',
      'libm.so',
      'libm.dylib'
    ].freeze
    NATIVE_SIGNATURES = {
      fma: 'double fma(double, double, double)',
      remainder: 'double remainder(double, double)',
      scalb: 'double scalb(double, double)',
      scalbln: 'double scalbln(double, long)'
    }.freeze

    module_function

    def bessel(name, *values)
      if %w[jn yn].include?(name)
        bessel_library.public_send(name, values.fetch(0).to_i, values.fetch(1).to_f)
      else
        bessel_library.public_send(name, values.fetch(0).to_f)
      end
    end

    def fma(left, right, addend)
      library = native_library(:fma)
      return library.fma(left.to_f, right.to_f, addend.to_f) if library

      raise Rjq::RuntimeError, 'native fused multiply-add is not available on this platform'
    end

    def remainder(left, right)
      library = native_library(:remainder)
      return library.remainder(left.to_f, right.to_f) if library

      raise Rjq::RuntimeError, 'native IEEE remainder is not available on this platform'
    end

    def scalb(value, exponent)
      exponent = exponent.to_f
      return Float::NAN if exponent.nan?
      return portable_scale(value.to_f, exponent.positive? ? 10_000 : -10_000) if exponent.infinite?

      portable_scale(value.to_f, exponent.to_i)
    end

    def scalbln(value, exponent)
      integral_exponent = c_long_exponent(exponent.to_f)
      portable_scale(value.to_f, integral_exponent)
    end

    def native_available?(name)
      !native_library(name).nil?
    end

    def native_library(name)
      @native_libraries ||= {}
      return @native_libraries[name] if @native_libraries.key?(name)

      signature = NATIVE_SIGNATURES.fetch(name)
      @native_libraries[name] = CANDIDATE_LIBRARIES.lazy.filter_map do |library|
        build_native_library(library, signature)
      rescue Fiddle::DLError
        nil
      end.first
    end

    def build_native_library(library, signature)
      Module.new do
        extend Fiddle::Importer

        dlload library
        extern signature
      end
    end

    def c_long_exponent(value)
      bits = Fiddle::SIZEOF_LONG * 8
      minimum = -(1 << (bits - 1))
      maximum = (1 << (bits - 1)) - 1
      return 0 if value.nan?
      return value.positive? ? maximum : minimum if value.infinite?

      [[value.to_i, minimum].max, maximum].min
    end

    def portable_scale(value, exponent)
      return value if value.zero?
      return signed_max(value) if value.infinite?

      _, value_exponent = Math.frexp(value.abs)
      target_exponent = value_exponent + exponent
      return signed_max(value) if target_exponent > 1024
      return value.negative? ? -0.0 : 0.0 if target_exponent < -1074

      result = Math.ldexp(value, exponent)
      result.infinite? ? signed_max(value) : result
    end

    def signed_max(value)
      value.negative? ? -Float::MAX : Float::MAX
    end

    def bessel_library
      @bessel_library ||= load_bessel_library
    end

    def load_bessel_library
      errors = []
      CANDIDATE_LIBRARIES.each do |library|
        return build_bessel_library(library)
      rescue Fiddle::DLError => e
        errors << "#{library}: #{e.message}"
      end

      raise "C math library with Bessel functions is not available (#{errors.join('; ')})"
    end

    def build_bessel_library(library)
      Module.new do
        extend Fiddle::Importer

        dlload library
        extern 'double j0(double)'
        extern 'double j1(double)'
        extern 'double y0(double)'
        extern 'double y1(double)'
        extern 'double jn(int, double)'
        extern 'double yn(int, double)'
      end
    end
  end
end
