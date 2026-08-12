# frozen_string_literal: true

require 'pathname'

module Rjq
  class ModuleResolver
    ResolvedModule = Struct.new(:name, :path, :content, :data, keyword_init: true)

    DEFAULT_MAX_BYTES = 1_048_576

    def initialize(paths: [], use_default_paths: true, max_bytes: DEFAULT_MAX_BYTES)
      configured = paths.map { |path| File.expand_path(path) }
      if use_default_paths
        configured.concat(ENV.fetch('JQ_LIBRARY_PATH', '').split(File::PATH_SEPARATOR).reject(&:empty?))
        configured.concat([File.expand_path('~/.jq'), File.expand_path('~/.rjq')])
      end
      @roots = configured.uniq.freeze
      @max_bytes = max_bytes
      @cache = {}
    end

    def resolve(name, from: nil, metadata: {}, data: false)
      validate_name!(name)
      extension = data ? '.json' : '.jq'
      candidates(name, extension, from, metadata).each do |candidate|
        next unless File.file?(candidate)

        path = File.realpath(candidate)
        validate_root!(path)
        return cached_source(name, path, data)
      end
      raise CompileError, "module #{name.inspect} not found"
    end

    def initial_metadata
      {}
    end

    private

    def candidates(name, extension, from, metadata)
      bases = search_bases(from, metadata)
      filename = name.end_with?(extension) ? name : "#{name}#{extension}"
      bases.flat_map do |base|
        [File.expand_path(filename, base), File.expand_path(File.join(name, File.basename(filename)), base)]
      end.uniq
    end

    def search_bases(from, metadata)
      search = metadata['search']
      if search
        raise CompileError, 'module search metadata must be a string' unless search.is_a?(String)

        return [File.expand_path(search, from ? File.dirname(from) : Dir.pwd)]
      end

      bases = []
      bases << File.dirname(from) if from
      bases.concat(@roots)
      bases.uniq
    end

    def validate_name!(name)
      unless name.is_a?(String) && !name.empty? && !name.include?("\0") && !Pathname.new(name).absolute?
        raise CompileError, 'invalid module path'
      end
    end

    def validate_root!(path)
      roots = @roots.filter_map { |root| File.realpath(root) if File.directory?(root) }
      return if roots.any? { |root| path == root || path.start_with?("#{root}#{File::SEPARATOR}") }

      raise CompileError, "module path escapes configured library roots: #{path}"
    end

    def cached_source(name, path, data)
      key = [path, data]
      @cache[key] ||= begin
        size = File.size(path)
        raise CompileError, "module exceeds #{@max_bytes} byte limit: #{path}" if size > @max_bytes

        ResolvedModule.new(name: name, path: path, content: File.binread(path), data: data).freeze
      end
    end
  end

  Modules = ModuleResolver
end
