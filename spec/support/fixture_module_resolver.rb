# frozen_string_literal: true

class FixtureModuleResolver
  MODULES = {
    'a' => 'def a: "a";',
    'b' => 'def a: "b"; def b: "c";',
    'c' => 'def a: 0; def c: "acmehbah";',
    'shadow1' => 'def e: 2;',
    'shadow2' => 'def e: 3;',
    'test_bind_order' => 'def check: true;'
  }.freeze
  DATA = {
    'data' => '[{"this":"is a test","that":"is too"}]'
  }.freeze

  def resolve(name, from: nil, metadata: {}, data: false)
    content = (data ? DATA : MODULES)[name]
    raise Rjq::CompileError, "module #{name.inspect} not found" unless content

    extension = data ? 'json' : 'jq'
    Rjq::ModuleResolver::ResolvedModule.new(
      name: name,
      path: "/fixture/modules/#{name}.#{extension}",
      content: content,
      data: data
    ).freeze
  end

  def initial_metadata
    {
      'c' => {
        'whatever' => nil,
        'deps' => [
          { 'as' => 'foo', 'is_data' => false, 'relpath' => 'a' },
          { 'search' => './', 'as' => 'd', 'is_data' => false, 'relpath' => 'd' },
          { 'search' => './', 'as' => 'd2', 'is_data' => false, 'relpath' => 'd' },
          { 'search' => './../lib/jq', 'as' => 'e', 'is_data' => false, 'relpath' => 'e' },
          { 'search' => './../lib/jq', 'as' => 'f', 'is_data' => false, 'relpath' => 'f' },
          { 'as' => 'd', 'is_data' => true, 'relpath' => 'data' }
        ],
        'defs' => ['a/0', 'c/0']
      }
    }
  end
end
