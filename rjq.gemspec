# frozen_string_literal: true

require_relative 'lib/rjq/version'

Gem::Specification.new do |spec|
  spec.name = 'rjq'
  spec.version = Rjq::VERSION
  spec.authors = ['Yudai Takada']
  spec.email = ['t.yudai92@gmail.com']

  spec.summary = 'A pure Ruby jq-compatible JSON processor'
  spec.description = 'rjq is a pure Ruby implementation of a practical jq subset with a jq-shaped API.'
  spec.homepage = 'https://github.com/ydah/rjq'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1'

  spec.metadata['allowed_push_host'] = 'https://rubygems.org'
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*.rb', 'bin/*', 'README.md', 'LICENSE.txt']
  spec.bindir = 'bin'
  spec.executables = ['rjq']
  spec.require_paths = ['lib']

  spec.add_dependency 'fiddle', '>= 1.1'
end
