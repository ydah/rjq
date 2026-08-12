# frozen_string_literal: true

require 'digest'
require 'spec_helper'

RSpec.describe 'compatibility fixture manifest' do
  it 'pins the jq fixture tag and checksums' do
    directory = File.expand_path('../fixtures/jq', __dir__)
    manifest = Rjq::JSON::Parser.parse_one(File.binread(File.join(directory, 'manifest.json')))

    expect(manifest.fetch('tag')).to eq('jq-1.7.1')
    expect(manifest.fetch('commit')).to eq('71c2ab509a8628dbbad4bc7b3f98a64aa90d3297')
    manifest.fetch('files').each do |name, checksum|
      expect(Digest::SHA256.file(File.join(directory, name)).hexdigest).to eq(checksum)
    end
  end
end
