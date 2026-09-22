# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/registry"
require "sus/fixtures/temporary_directory_context"

describe Bake::Gem::GitHub::Registry do
	let(:transport) {Object.new}
	let(:http) {Object.new}
	let(:registry) {subject.new(http: transport)}
	let(:responses) {{}}
	let(:requests) {[]}
	let(:version_path) {"/api/v2/rubygems/example/versions/1.0.1.json?platform=ruby"}
	let(:download_path) {"/downloads/example-1.0.1.gem"}
	let(:attestation_path) {"/api/v1/attestations/example-1.0.1.json"}
	let(:bytes) {"gem bytes\x00\xff".b}
	
	def response(code, body = "")
		result = Net::HTTPResponse::CODE_TO_OBJ.fetch(code).new("1.1", code, "")
		mock(result) do |wrapper|
			wrapper.replace(:body){body}
		end
		
		return result
	end
	
	before do
		mock(http) do |wrapper|
			wrapper.replace(:get) do |path|
				requests << path
				responses.fetch(path).shift or raise "Unexpected request: #{path}"
			end
		end
		mock(transport) do |wrapper|
			wrapper.replace(:start) do |host, port, **options, &block|
				expect(host).to be == "rubygems.org"
				expect(port).to be == 443
				expect(options).to be == {use_ssl: true, open_timeout: 15, read_timeout: 60}
				
				block.call(http)
			end
		end
	end
	
	with "#verify" do
		include Sus::Fixtures::TemporaryDirectoryContext
		
		let(:receipt) {{name: "example", version: "1.0.1", sha256: Digest::SHA256.hexdigest(bytes)}}
		let(:bundle) {File.join(root, "bundle.json")}
		let(:waits) {[]}
		
		before do
			File.write(bundle, JSON.generate(mediaType: "test"))
			responses[version_path] = [response("200", "{}")]
			responses[download_path] = [response("200", bytes)]
			responses[attestation_path] = [response("200", JSON.generate([{bundle: {mediaType: "test"}}]))]
			
			mock(registry) do |wrapper|
				wrapper.replace(:sleep){|delay| waits << delay}
			end
		end
		
		def verify
			registry.verify(receipt, bundle, attempts: 3, delay: 10)
		end
		
		it "waits for an absent version and a pending download" do
			responses[version_path].unshift(response("404"), response("200", "{}"))
			responses[download_path].unshift(response("404"))
			
			expect(verify).to be_nil
			expect(waits).to be == [10, 10]
			expect(requests.count(download_path)).to be == 2
		end
		
		it "waits for an absent registry attestation" do
			responses[version_path].unshift(response("200", "{}"))
			responses[download_path].unshift(response("200", bytes))
			responses[attestation_path].unshift(response("404"))
			
			expect(verify).to be_nil
			expect(waits).to be == [10]
		end
		
		it "stops waiting after the bounded number of attempts" do
			responses[version_path] = Array.new(3){response("404")}
			
			expect{verify}.to raise_exception(RuntimeError, message: be =~ /propagation did not complete/)
			expect(waits).to be == [10, 10]
			expect(requests).to be == [version_path] * 3
		end
		
		it "rejects different bytes immediately" do
			responses[download_path] = [response("200", "different")]
			
			expect{verify}.to raise_exception(RuntimeError, message: be =~ /different bytes/)
			expect(waits).to be == []
		end
		
		it "rejects an unrelated attestation immediately" do
			responses[attestation_path] = [response("200", JSON.generate([{bundle: {mediaType: "unrelated"}}]))]
			
			expect{verify}.to raise_exception(RuntimeError, message: be =~ /Sigstore bundle/)
			expect(waits).to be == []
		end
		
		it "does not hide registry request errors" do
			responses[version_path] = [response("403")]
			
			expect{verify}.to raise_exception(RuntimeError, message: be =~ /403/)
			expect(waits).to be == []
		end
	end
	
	with "#digest" do
		it "recognizes an unpublished version without requesting the missing download" do
			responses[version_path] = [response("404")]
			
			expect(registry.digest("example", "1.0.1")).to be_nil
			expect(requests).to be == [version_path]
		end
		
		it "hashes the actual published package bytes" do
			responses[version_path] = [response("200", "{}")]
			responses[download_path] = [response("200", bytes)]
			
			expect(registry.digest("example", "1.0.1")).to be == Digest::SHA256.hexdigest(bytes)
		end
		
		["403", "500"].each do |code|
			it "rejects version API errors", unique: code do
				responses[version_path] = [response(code)]
				
				expect{registry.digest("example", "1.0.1")}.to raise_exception(RuntimeError, message: be == "Registry request failed: #{code}")
			end
		end
		
		it "rejects a forbidden download for an existing version" do
			responses[version_path] = [response("200", "{}")]
			responses[download_path] = [response("403")]
			
			expect{registry.digest("example", "1.0.1")}.to raise_exception(RuntimeError, message: be == "Registry request failed: 403")
		end
		
		it "reports a pending download for an existing version" do
			responses[version_path] = [response("200", "{}")]
			responses[download_path] = [response("404")]
			
			expect{registry.digest("example", "1.0.1")}.to raise_exception(Bake::Gem::GitHub::Registry::Pending)
		end
		
		it "follows HTTPS redirects relative to the registry URL" do
			redirect = response("302")
			redirect["location"] = "/version.json"
			responses[version_path] = [redirect]
			responses["/version.json"] = [response("200", "{}")]
			responses[download_path] = [response("200", bytes)]
			
			expect(registry.digest("example", "1.0.1")).to be == Digest::SHA256.hexdigest(bytes)
		end
		
		it "rejects a redirect to an unencrypted download" do
			redirect = response("302")
			redirect["location"] = "http://rubygems.org/version.json"
			responses[version_path] = [redirect]
			
			expect{registry.digest("example", "1.0.1")}.to raise_exception(RuntimeError, message: be =~ /requires HTTPS/)
		end
		
		it "bounds registry redirect loops" do
			redirect = response("302")
			redirect["location"] = version_path
			responses[version_path] = [redirect] * 6
			
			expect{registry.digest("example", "1.0.1")}.to raise_exception(RuntimeError, message: be =~ /Too many registry redirects/)
		end
	end
end
