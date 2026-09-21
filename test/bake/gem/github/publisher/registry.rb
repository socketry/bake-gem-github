# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/publisher"
require "sus/fixtures/temporary_directory_context"

describe Bake::Gem::GitHub::Publisher do
	with "#verify_registry" do
		include Sus::Fixtures::TemporaryDirectoryContext
		let(:publisher) {subject.allocate}
		let(:receipt) {{name: "example", version: "1.0.1", sha256: "expected"}}
		let(:bundle) {File.join(root, "bundle.json")}
		let(:digests) {["expected"]}
		let(:attestations) {[JSON.generate([{bundle: {mediaType: "test"}}])]}
		let(:waits) {[]}
		
		before do
			File.write(bundle, JSON.generate(mediaType: "test"))
			mock(publisher) do |wrapper|
				wrapper.replace(:registry_digest) do |*arguments|
					result = digests.shift
					raise result if result.is_a?(Exception)
					result
				end
				wrapper.replace(:registry_get){|url| attestations.shift}
				wrapper.replace(:sleep){|delay| waits << delay}
			end
		end
		
		def verify
			publisher.send(:verify_registry, receipt, bundle, attempts: 3, delay: 10)
		end
		
		it "waits for an absent version and a pending download without uploading again" do
			digests.unshift(nil, Bake::Gem::GitHub::Publisher::RegistryPending.new("pending"))
			expect{verify}.not.to raise_exception
			expect(waits).to be == [10, 10]
		end
		
		it "waits for an absent registry attestation" do
			digests.unshift("expected")
			attestations.unshift(nil)
			expect{verify}.not.to raise_exception
			expect(waits).to be == [10]
		end
		
		it "stops waiting after the bounded number of attempts" do
			digests.clear
			expect{verify}.to raise_exception(RuntimeError, message: be =~ /propagation did not complete/)
			expect(waits).to be == [10, 10]
		end
		
		it "rejects different bytes immediately" do
			digests.replace(["different"])
			expect{verify}.to raise_exception(RuntimeError, message: be =~ /different bytes/)
			expect(waits).to be == []
		end
		
		it "rejects an unrelated attestation immediately" do
			attestations.replace([JSON.generate([{bundle: {mediaType: "unrelated"}}])])
			expect{verify}.to raise_exception(RuntimeError, message: be =~ /Sigstore bundle/)
			expect(waits).to be == []
		end
		
		it "does not hide registry request errors" do
			digests.replace([RuntimeError.new("Registry request failed: 403")])
			expect{verify}.to raise_exception(RuntimeError, message: be =~ /403/)
			expect(waits).to be == []
		end
	end
	
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
		
		it "follows HTTPS redirects relative to the registry URL" do
			responses[version_path] = response("302")
			responses[version_path]["location"] = "/version.json"
			responses["/version.json"] = response("200", "{}")
			responses[download_path] = response("200", "gem bytes")
			expect(publisher.send(:registry_digest, "example", "1.0.1")).to be == Digest::SHA256.hexdigest("gem bytes")
		end
		
		it "rejects a redirect to an unencrypted download" do
			responses[version_path] = response("302")
			responses[version_path]["location"] = "http://rubygems.org/version.json"
			expect{publisher.send(:registry_digest, "example", "1.0.1")}.to raise_exception(RuntimeError, message: be =~ /requires HTTPS/)
		end
		
		it "bounds registry redirect loops" do
			responses[version_path] = response("302")
			responses[version_path]["location"] = version_path
			expect{publisher.send(:registry_digest, "example", "1.0.1")}.to raise_exception(RuntimeError, message: be =~ /Too many registry redirects/)
		end
	end
end
