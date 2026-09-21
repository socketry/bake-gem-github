# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require_relative "../lib/bake/gem/github/publisher"

describe Bake::Gem::GitHub::Publisher do
	with "#registry_digest" do
		let(:publisher) {subject.allocate}
		let(:http) {Object.new}
		let(:responses) {{}}
		let(:version_path) {"/api/v2/rubygems/example/versions/1.0.1.json?platform=ruby"}
		let(:download_path) {"/downloads/example-1.0.1.gem"}
		
		def response(code, body = "")
			result = Net::HTTPResponse::CODE_TO_OBJ.fetch(code).new("1.1", code, "")
			mock(result) do |wrapper|
				wrapper.replace(:body){body}
			end
			result
		end
		
		before do
			mock(http) do |wrapper|
				wrapper.replace(:get){|path| responses.fetch(path)}
			end
			mock(Net::HTTP) do |wrapper|
				wrapper.replace(:start) do |*arguments, **options, &block|
					block.call(http)
				end
			end
		end
		
		it "recognizes an unpublished version without requesting the missing download" do
			responses[version_path] = response("404")
			expect(publisher.send(:registry_digest, "example", "1.0.1")).to be_nil
		end
		
		it "hashes the actual published package bytes" do
			responses[version_path] = response("200", "{}")
			responses[download_path] = response("200", "gem bytes\x00\xff".b)
			expect(publisher.send(:registry_digest, "example", "1.0.1")).to be == Digest::SHA256.hexdigest("gem bytes\x00\xff".b)
		end
		
		["403", "500"].each do |code|
			it "rejects version API errors", unique: code do
				responses[version_path] = response(code)
				expect{publisher.send(:registry_digest, "example", "1.0.1")}.to raise_exception(RuntimeError, message: be == "Registry request failed: #{code}")
			end
		end
		
		it "rejects a forbidden download for an existing version" do
			responses[version_path] = response("200", "{}")
			responses[download_path] = response("403")
			expect{publisher.send(:registry_digest, "example", "1.0.1")}.to raise_exception(RuntimeError, message: be == "Registry request failed: 403")
		end
		
		it "rejects a missing download for an existing version" do
			responses[version_path] = response("200", "{}")
			responses[download_path] = response("404")
			expect{publisher.send(:registry_digest, "example", "1.0.1")}.to raise_exception(RuntimeError, message: be =~ /Published gem download is missing/)
		end
	end
end
