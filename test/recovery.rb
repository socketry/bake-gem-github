# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require_relative "../lib/bake/gem/github/publisher"
require "sus/fixtures/temporary_directory_context"

# A simulated registry and GitHub finalizer. Core content validation has its own
# real-repository integration tests; this fixture exercises interruption/retry.
class RecoveryPublisher < Bake::Gem::GitHub::Publisher
	attr_accessor :remote_digest, :fail_release, :fail_attestation, :fail_receipt_verification
	attr_accessor :releases, :artifacts, :fail_preservation
	attr_reader :commands, :stored_files
	
	def initialize(root)
		super
		@commands = []
		@releases = []
		@artifacts = []
		@stored_files = {}
		@release = Object.new
		def @release.resolve(reference)
			"a" * 40
		end
		def @release.validate(**options)
			{name: "example", version: "1.0.1", commit: "a" * 40}
		end
	end
	
	def merged(number)
		{"merge_commit_sha" => "a" * 40, "number" => 42, "html_url" => "https://github.com/socketry/example/pull/42"}
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
		case arguments[0, 3]
		when ["gh", "release", "create"]
			@releases << {"tag_name" => arguments[3], "draft" => true, "target_commitish" => arguments[arguments.index("--target") + 1], "assets" => []}
		when ["gh", "release", "upload"]
			raise "Preservation failed" if @fail_preservation
			file = arguments[4]
			@stored_files[File.basename(file)] = File.binread(file)
			@releases.first.fetch("assets") << {"name" => File.basename(file), "digest" => "sha256:#{Digest::SHA256.file(file).hexdigest}"}
		when ["gh", "release", "download"], ["gh", "run", "download"]
			path = arguments[arguments.index("--dir") + 1]
			@stored_files.each{|name, content| File.binwrite(File.join(path, name), content)}
		when ["gh", "release", "edit"]
			raise "GitHub unavailable after upload" if @fail_release
			@releases.first["draft"] = false
		end
		true
	end
	
	def readlines(*arguments, **options)
		@commands << arguments
		return [JSON.generate([@releases])] if arguments[0, 2] == ["gh", "api"]
		[]
	end
	
	def api(path)
		{"artifacts" => @artifacts}
	end
	
	private
	
	def gem_command(*arguments)
		system("gem", *arguments, chdir: @root)
	end
	
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
	include Sus::Fixtures::TemporaryDirectoryContext
	
	def before
		@root = root
		Bake::Gem::GitHub::Setup.new(root).generate(repository: "socketry/example", checks: ["Test"], signing: false)
		FileUtils.mkdir_p(File.join(root, "pkg"))
		File.write(File.join(root, "pkg", "example-1.0.1.gem"), "Exact signed bytes")
		File.write(File.join(root, "pkg", "example-1.0.1.gem.sigstore.json"), JSON.generate(mediaType: "test"))
		File.write(File.join(root, "pkg", "provenance.sigstore.json"), "{}")
		receipt = {name: "example", version: "1.0.1", file: "example-1.0.1.gem", sha256: Digest::SHA256.hexdigest("Exact signed bytes"), commit: "a" * 40, repository: "socketry/example", pull_request: 42, pull_request_url: "https://github.com/socketry/example/pull/42"}
		File.write(File.join(root, "pkg", "release.json"), JSON.generate(receipt))
		@publisher = RecoveryPublisher.new(root)
	end
	
	def restore
		FileUtils.rm_rf(File.join(@root, "pkg"))
		expect(ENV).to receive(:fetch).with("GITHUB_RUN_ID").and_return("123")
		@publisher.build(42)
	end
	
	it "resumes finalization after upload without uploading or rebuilding again" do
		@publisher.fail_release = true
		expect{@publisher.publish(42)}.to raise_exception(RuntimeError, message: be =~ /GitHub unavailable/)
		@publisher.fail_release = false
		restore
		@publisher.publish(42)
		uploads = @publisher.commands.select{|args| args[0, 2] == ["gem", "push"]}
		expect(uploads.size).to be == 1
		expect(uploads.first).to be(:include?, "--attestation")
		expect(@publisher.commands.any?{|args| args.include?("push") && args.include?("--tags")}).to be == false
		expect(@publisher.releases.first.fetch("draft")).to be == false
		preserve = @publisher.commands.index{|args| args[0, 3] == ["gh", "release", "upload"]}
		upload = @publisher.commands.index{|args| args[0, 2] == ["gem", "push"]}
		expect(preserve).to be < upload
	end
	
	it "does not upload to RubyGems if draft asset preservation fails" do
		@publisher.fail_preservation = true
		expect{@publisher.publish(42)}.to raise_exception(RuntimeError, message: be =~ /Preservation failed/)
		expect(@publisher.remote_digest).to be_nil
	end
	
	it "restores expired workflow artifacts from the GitHub release" do
		@publisher.publish(42)
		@publisher.artifacts = [{"name" => "release-#{'a' * 40}", "expired" => true}]
		expect(restore.fetch(:sha256)).to be == @publisher.remote_digest
		@publisher.publish(42)
		expect(@publisher.commands.count{|args| args[0, 2] == ["gem", "push"]}).to be == 1
	end
	
	it "can still restore an available workflow artifact" do
		@publisher.publish(42)
		@publisher.releases = []
		@publisher.artifacts = [{"name" => "release-#{'a' * 40}", "expired" => false}]
		expect(restore.fetch(:sha256)).to be == @publisher.remote_digest
	end
	
	it "refuses to rebuild when the workflow artifact expired without a release backup" do
		@publisher.artifacts = [{"name" => "release-#{'a' * 40}", "expired" => true}]
		expect{restore}.to raise_exception(RuntimeError, message: be =~ /expired/)
	end
	
	it "refuses to rebuild a published version without either backup" do
		@publisher.remote_digest = @publisher.load_receipt.fetch(:sha256)
		expect{restore}.to raise_exception(RuntimeError, message: be =~ /already published/)
	end
	
	it "builds an unpublished version and records the originating run" do
		mock(@publisher) do |wrapper|
			wrapper.replace(:build_package) do |path|
				file = File.join(path, "example-1.0.1.gem")
				File.write(file, "new gem")
				file
			end
		end
		receipt = restore
		expect(receipt.fetch(:run_id)).to be == "123"
		expect(receipt.fetch(:sha256)).to be == Digest::SHA256.hexdigest("new gem")
	end
	
	it "rejects an unexpected package filename before recording it" do
		expect(@publisher).to receive(:build_package).and_return("different.gem")
		expect{restore}.to raise_exception(RuntimeError, message: be =~ /Unexpected package filename/)
	end
	
	it "requires a complete release backup before restoring" do
		@publisher.publish(42)
		@publisher.releases.first.fetch("assets").pop
		expect{restore}.to raise_exception(RuntimeError, message: be =~ /incomplete/)
	end
	
	it "rejects another source commit in the restored receipt" do
		@publisher.publish(42)
		receipt = JSON.parse(@publisher.stored_files.fetch("release.json"))
		receipt["commit"] = "b" * 40
		@publisher.stored_files["release.json"] = JSON.generate(receipt)
		expect{restore}.to raise_exception(RuntimeError, message: be =~ /different commit/)
	end
	
	it "refuses a draft release targeting another commit" do
		@publisher.releases = [{"tag_name" => "v1.0.1", "draft" => true, "target_commitish" => "b" * 40}]
		expect{@publisher.publish(42)}.to raise_exception(RuntimeError, message: be =~ /another commit/)
		expect(@publisher.remote_digest).to be_nil
	end
	
	it "refuses duplicate release records for the same tag" do
		@publisher.releases = [{"tag_name" => "v1.0.1"}] * 2
		expect{@publisher.publish(42)}.to raise_exception(RuntimeError, message: be =~ /Multiple GitHub releases/)
		expect(@publisher.remote_digest).to be_nil
	end
	
	it "does not overwrite conflicting release assets" do
		@publisher.publish(42)
		@publisher.releases.first.fetch("assets").first["digest"] = "sha256:wrong"
		expect{@publisher.publish(42)}.to raise_exception(RuntimeError, message: be =~ /Existing release asset differs/)
		expect(@publisher.commands.count{|args| args[0, 3] == ["gh", "release", "upload"]}).to be == 4
	end
	
	it "requires confirmation that a newly created draft is retained" do
		mock(@publisher) do |wrapper|
			wrapper.replace(:readlines){|*arguments, **options| arguments[0, 2] == ["gh", "api"] ? ["[[]]"] : []}
		end
		expect{@publisher.publish(42)}.to raise_exception(RuntimeError, message: be =~ /Draft release was not retained/)
		expect(@publisher.remote_digest).to be_nil
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
