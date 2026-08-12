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

    module_function

    def bessel(name, *values)
      if %w[jn yn].include?(name)
        bessel_library.public_send(name, values.fetch(0).to_i, values.fetch(1).to_f)
      else
        bessel_library.public_send(name, values.fetch(0).to_f)
      end
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
