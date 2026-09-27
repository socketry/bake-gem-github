# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/trusted_publisher"
require "rubygems/vendored_net_http"
require "time"

describe Bake::Gem::GitHub::TrustedPublisher do
	let(:settings) {{repository_owner: "socketry", repository_name: "example", workflow_filename: "release-publish.yaml", environment: "rubygems"}}
	let(:client) {subject.new("example", settings, otp: "123456")}
	let(:transport) {Object.new}
	let(:requests) {[]}
	let(:responses) {[]}
	let(:record) {{"id" => 1, "trusted_publisher_type" => subject::TYPE, "trusted_publisher" => settings.transform_keys(&:to_s)}}
	let(:path) {"/api/v1/gems/example/trusted_publishers"}
	
	def response(code, body)
		result = ::Gem::Net::HTTPResponse::CODE_TO_OBJ.fetch(code).new("1.1", code, "")
		mock(result) do |wrapper|
			wrapper.replace(:body){body}
		end
		
		return result
	end
	
	before do
		client.set_api_key(client.host, "test-token")
		mock(::Gem::RemoteFetcher) do |wrapper|
			wrapper.replace(:fetcher){transport}
		end
		mock(transport) do |wrapper|
			wrapper.replace(:request) do |uri, method, &block|
				expect(uri.scheme).to be == "https"
				expect(uri.host).to be == "rubygems.org"
				request = method.new(uri.request_uri)
				block.call(request)
				requests << request
				responses.shift or raise "Unexpected request: #{request.method} #{request.path}"
			end
		end
	end
	
	it "registers the configured publisher once and recognizes it on reruns" do
		responses.push(response("200", "[]"), response("201", JSON.generate(record)), response("200", JSON.generate([record])))
		
		expect(client.register).to be == {created: true, publisher: record}
		expect(client.register).to be == {created: false, publisher: record}
		expect(requests.map(&:method)).to be == ["GET", "POST", "GET"]
		requests.each do |request|
			expect(request.path).to be == path
			expect(request["Authorization"]).to be == "test-token"
			expect(request["OTP"]).to be == "123456"
			expect(request["Accept"]).to be == "application/json"
		end
		expect(requests[1]["Content-Type"]).to be == "application/json"
		expect(JSON.parse(requests[1].body)).to be == record.reject{|key, _| key == "id"}
	end
	
	it "reports a missing publisher without creating it" do
		responses << response("200", "[]")
		
		expect(client.status).to be == {configured: false, publisher: nil}
		expect(requests.map(&:method)).to be == ["GET"]
	end
	
	it "preserves unrelated registrations when adding the expected publisher" do
		unrelated = record.merge("id" => 2, "trusted_publisher_type" => "AnotherProvider")
		responses.push(response("200", JSON.generate([unrelated])), response("201", JSON.generate(record)))
		
		expect(client.register).to be == {created: true, publisher: record}
		expect(requests.map(&:method)).to be == ["GET", "POST"]
	end
	
	{
		"repository_owner" => "another-owner",
		"repository_name" => "another-repository",
		"workflow_filename" => "push_gem.yml",
		"environment" => nil,
		"workflow_repository_owner" => "socketry",
		"workflow_repository_name" => "workflows",
	}.each do |key, value|
		it "requires matching repository, workflow, and environment restrictions", unique: key do
			record.fetch("trusted_publisher")[key] = value
			responses << response("200", JSON.generate([record]))
			
			expect(client.status).to be == {configured: false, publisher: nil}
		end
	end
	
	["401", "403", "404", "500"].each do |code|
		it "does not create a publisher when listing fails", unique: code do
			responses << response(code, "Request rejected")
			
			expect{client.register}.to raise_exception(RuntimeError, message: be =~ /GET failed \(HTTP #{code}\): Request rejected/)
			expect(requests.map(&:method)).to be == ["GET"]
		end
	end
	
	it "reports registration errors" do
		responses.push(response("200", "[]"), response("422", "Invalid publisher"))
		
		expect{client.register}.to raise_exception(RuntimeError, message: be =~ /POST failed \(HTTP 422\): Invalid publisher/)
	end
	
	it "rejects a successful registration with unexpected settings" do
		record.fetch("trusted_publisher")["environment"] = nil
		responses.push(response("200", "[]"), response("201", JSON.generate(record)))
		
		expect{client.register}.to raise_exception(RuntimeError, message: be =~ /unexpected trusted publisher settings/)
	end
	
	it "rejects a malformed publisher list" do
		responses << response("200", "{}")
		
		expect{client.register}.to raise_exception(RuntimeError, message: be =~ /Invalid RubyGems trusted publishers response/)
		expect(requests.map(&:method)).to be == ["GET"]
	end
	
	it "rejects invalid JSON without attempting registration" do
		responses << response("200", "not JSON")
		
		expect{client.register}.to raise_exception(JSON::ParserError)
		expect(requests.map(&:method)).to be == ["GET"]
	end
	
	it "uses RubyGems MFA prompts to retry a challenged request" do
		responses.push(
			response("401", "You have enabled multifactor authentication"),
			response("404", "WebAuthn unavailable"),
			response("200", JSON.generate([record]))
		)
		expect(client).to receive(:say)
		expect(client).to receive(:ask).with("Code: ").and_return("654321")
		
		expect(client.status).to be == {configured: true, publisher: record}
		expect(requests.map(&:path)).to be == [path, "/api/v1/webauthn_verification", path]
		expect(requests.last["OTP"]).to be == "654321"
	end
	
	with "authentication" do
		before do
			client.set_api_key(client.host, nil)
			mock(ENV) do |wrapper|
				wrapper.wrap(:[]) do |original, key|
					key == "GEM_HOST_API_KEY" ? nil : original.call(key)
				end
			end
		end
		
		it "uses an explicitly supplied environment key" do
			expect(ENV).to receive(:[]).with("GEM_HOST_API_KEY").and_return("environment-token")
			
			expect(client.api_key).to be == "environment-token"
		end
		
		it "uses an explicitly selected saved key" do
			client.options[:key] = :publisher
			expect(::Gem.configuration).to receive(:api_keys).twice.and_return({publisher: "named-token"})
			
			expect(client.api_key).to be == "named-token"
		end
		
		it "creates a scoped, expiring session key without reading or writing saved credentials" do
			expect(::Gem.configuration).not.to receive(:api_keys)
			expect(::Gem.configuration).not.to receive(:rubygems_api_key=)
			expect(::Gem.configuration).not.to receive(:set_api_key)
			mock(client) do |wrapper|
				wrapper.replace(:say){}
				wrapper.replace(:ask){"maintainer@example.com"}
				wrapper.replace(:ask_for_password){"test-password"}
			end
			responses.push(
				response("200", "---\nmfa: ui_and_api\n"),
				response("200", "session-token"),
				response("200", "[]")
			)
			started = Time.now.utc
			
			expect(client.status).to be == {configured: false, publisher: nil}
			expect(requests.map(&:path)).to be == ["/api/v1/profile/me.yaml", "/api/v1/api_key", path]
			params = URI.decode_www_form(requests[1].body).to_h
			
			expect(params.keys.sort).to be == ["configure_trusted_publishers", "expires_at", "name"]
			expect(params.fetch("configure_trusted_publishers")).to be == "true"
			expires_at = Time.strptime(params.fetch("expires_at"), "%Y-%m-%d %H:%M:%S %Z")
			
			expect(expires_at).to be >= started - 1 + 900
			expect(expires_at).to be <= Time.now.utc + 900
			expect(requests.last["Authorization"]).to be == "session-token"
			expect(client.api_key).to be == "session-token"
		end
	end
end
