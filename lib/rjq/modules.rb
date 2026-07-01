# frozen_string_literal: true

module Rjq
  class Modules
    def initialize(paths = [])
      @paths = paths
    end

    def resolve(name)
      candidates = @paths + ENV.fetch('JQ_LIBRARY_PATH', '').split(File::PATH_SEPARATOR)
      candidates += [File.expand_path('~/.jq'), File.expand_path('~/.rjq')]
      candidates.map { |path| File.join(path, "#{name}.jq") }.find { |candidate| File.file?(candidate) }
    end
  end
end
