# frozen_string_literal: true

require_relative 'lib/rjq/version'

Gem::Specification.new do |spec|
  spec.name = 'rjq'
  spec.version = Rjq::VERSION
  spec.authors = ['Yudai Takada']
  spec.email = ['t.yudai92@gmail.com']

  spec.summary = 'A Ruby implementation of a practical jq subset'
  spec.description = 'rjq implements a practical jq 1.7.1-compatible subset with a command line and Ruby API.'
  spec.homepage = 'https://github.com/ydah/rjq'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1'

  spec.metadata['allowed_push_host'] = 'https://rubygems.org'
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = "#{spec.homepage}/tree/main"
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['bug_tracker_uri'] = "#{spec.homepage}/issues"
  spec.metadata['documentation_uri'] = "#{spec.homepage}#readme"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*.rb', 'bin/*', '*.md', 'LICENSE.txt']
  spec.bindir = 'bin'
  spec.executables = ['rjq']
  spec.require_paths = ['lib']

  spec.add_dependency 'fiddle', '>= 1.1'
end
