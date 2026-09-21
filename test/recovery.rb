# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require_relative "../lib/bake/gem/github/publisher"
require "tmpdir"

# A simulated registry and GitHub finalizer. Core content validation has its own
# real-repository integration tests; this fixture exercises interruption/retry.
class RecoveryPublisher < Bake::Gem::GitHub::Publisher
	attr_accessor :remote_digest, :fail_release, :fail_attestation, :fail_receipt_verification
	attr_reader :commands
	
	def initialize(root)
		super
		@commands = []
		@release = Object.new
		def @release.resolve(reference)
			"a" * 40
		end
		def @release.validate(**options)
			{name: "example", version: "1.0.1", commit: "a" * 40}
		end
	end
	
	def merged(number)
		{"merge_commit_sha" => "a" * 40, "number" => 42}
	end
	
	def system(*arguments, **options)
		@commands << arguments
		raise "Attestation verification failed" if @fail_attestation && arguments[0, 3] == ["gem", "exec", "sigstore-cli:0.2.3"]
		if @fail_receipt_verification && arguments[0, 3] == ["gh", "attestation", "verify"] && arguments[3].end_with?("/release.json")
			raise "Receipt attestation verification failed"
		end
		if arguments[0, 2] == ["gem", "push"]
			@remote_digest = load_receipt.fetch(:sha256)
		end
		raise "GitHub unavailable after upload" if @fail_release && arguments[0, 3] == ["gh", "release", "create"]
		true
	end
	
	def readlines(*arguments, **options)
		@commands << arguments
		return ["[]"] if arguments[0, 3] == ["gh", "release", "list"]
		[]
	end
	
	def api(path)
		{"assets" => []}
	end
	
	private
	
	def guard_environment
	end
	
	def registry_digest(name, version)
		@remote_digest
	end
	
	def registry_get(url)
		JSON.generate([{bundle: {mediaType: "test"}}])
	end
end

describe "Publication recovery" do
	def around
		Dir.mktmpdir do |root|
			@root = root
			Bake::Gem::GitHub::Setup.new(root).generate(repository: "socketry/example", checks: ["Test"], signing: false)
			FileUtils.mkdir_p(File.join(root, "pkg"))
			File.write(File.join(root, "pkg", "example-1.0.1.gem"), "Exact signed bytes")
			File.write(File.join(root, "pkg", "example-1.0.1.gem.sigstore.json"), JSON.generate(mediaType: "test"))
			File.write(File.join(root, "pkg", "provenance.sigstore.json"), "{}")
			receipt = {name: "example", version: "1.0.1", file: "example-1.0.1.gem", sha256: Digest::SHA256.hexdigest("Exact signed bytes"), commit: "a" * 40, repository: "socketry/example", pull_request: 42, pull_request_url: "https://github.com/socketry/example/pull/42"}
			File.write(File.join(root, "pkg", "release.json"), JSON.generate(receipt))
			@publisher = RecoveryPublisher.new(root)
			yield
		end
	end
	
	it "resumes finalization after upload without uploading or rebuilding again" do
		@publisher.fail_release = true
		expect{@publisher.publish(42)}.to raise_exception(RuntimeError, message: be =~ /GitHub unavailable/)
		@publisher.fail_release = false
		@publisher.publish(42)
		uploads = @publisher.commands.select{|args| args[0, 2] == ["gem", "push"]}
		expect(uploads.size).to be == 1
		expect(uploads.first).to be(:include?, "--attestation")
		expect(@publisher.commands.any?{|args| args.include?("push") && args.include?("--tags")}).to be == false
	end
	
	it "stops before publication when required attestation verification fails" do
		@publisher.fail_attestation = true
		expect{@publisher.publish(42)}.to raise_exception(RuntimeError, message: be =~ /Attestation/)
		expect(@publisher.remote_digest).to be_nil
		expect(@publisher.commands.any?{|args| args[0, 2] == ["gem", "push"]}).to be == false
	end
	
	it "refuses a published version containing different bytes" do
		@publisher.remote_digest = Digest::SHA256.hexdigest("Someone else's artifact")
		expect{@publisher.publish(42)}.to raise_exception(RuntimeError, message: be =~ /different bytes/)
		expect(@publisher.commands.any?{|args| args[0, 3] == ["gh", "release", "create"]}).to be == false
	end
	
	it "stops before publication when the receipt attestation is invalid" do
		@publisher.fail_receipt_verification = true
		expect{@publisher.publish(42)}.to raise_exception(RuntimeError, message: be =~ /Receipt attestation/)
		expect(@publisher.remote_digest).to be_nil
		expect(@publisher.commands.any?{|args| args[0, 2] == ["gem", "push"]}).to be == false
	end
	
	it "rejects a receipt identifying another merged source" do
		path = File.join(@root, "pkg", "release.json")
		receipt = JSON.parse(File.read(path))
		receipt["commit"] = "b" * 40
		File.write(path, JSON.generate(receipt))
		expect{@publisher.publish(42)}.to raise_exception(RuntimeError, message: be =~ /not for this merged PR/)
		expect(@publisher.commands).to be == []
	end
end
