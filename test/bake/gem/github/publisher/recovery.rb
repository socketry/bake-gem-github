# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/recovery_publisher"
require "sus/fixtures/temporary_directory_context"
require "bake/context"

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
		@publisher = Bake::Gem::GitHub::RecoveryPublisher.new(root)
	end
	
	def restore
		FileUtils.rm_rf(File.join(@root, "pkg"))
		expect(ENV).to receive(:fetch).with("GITHUB_RUN_ID").and_return("123")
		expect(Bake::Gem::GitHub::Publisher).to receive(:new).with(root).and_return(@publisher)
		Bake::Context.load(root).call("gem:github:release:build", "number=42")
	end
	
	it "includes notes for the exact released version before the artifact metadata" do
		File.write(File.join(root, "releases.md"), <<~MARKDOWN)
			# Releases
			
			## Unreleased
			
			Future changes.
			
			## v2.0.0
			
			Newer release.
			
			## v1.0.1
			
			  - Fixed a `bug`.
			
			### Details
			
			Read the [guide](https://example.com/guide).
			
			## v1.0.0
			
			Older release.
		MARKDOWN
		
		receipt = @publisher.publish(42)
		
		expect(@publisher.releases.first.fetch("body")).to be == <<~MARKDOWN
			  - Fixed a `bug`.
			
			## Details
			
			Read the [guide](https://example.com/guide).
			
			https://github.com/socketry/example/pull/42
			
			Source: #{receipt.fetch(:commit)}
			SHA256: #{receipt.fetch(:sha256)}
		MARKDOWN
	end
	
	it "uses the artifact metadata when release notes are missing" do
		receipt = @publisher.publish(42)
		
		expect(@publisher.releases.first.fetch("name")).to be == "v1.0.1"
		expect(@publisher.releases.first.fetch("body")).to be == <<~MARKDOWN
			https://github.com/socketry/example/pull/42
			
			Source: #{receipt.fetch(:commit)}
			SHA256: #{receipt.fetch(:sha256)}
		MARKDOWN
	end
	
	it "preserves the existing draft description when finalization is retried" do
		File.write(File.join(root, "releases.md"), "## v1.0.1\n\nOriginal notes.\n")
		@publisher.fail_release = true
		expect{@publisher.publish(42)}.to raise_exception(RuntimeError, message: be =~ /GitHub unavailable/)
		body = @publisher.releases.first.fetch("body") + "\nMaintainer addition.\n"
		@publisher.releases.first["body"] = body
		@publisher.fail_release = false
		restore
		
		@publisher.publish(42)
		
		expect(@publisher.releases.size).to be == 1
		expect(@publisher.releases.first.fetch("body")).to be == body
		expect(@publisher.releases.first.fetch("draft")).to be == false
	end
	
	it "resumes finalization after upload without uploading or rebuilding again" do
		@publisher.fail_release = true
		expect{@publisher.publish(42)}.to raise_exception(RuntimeError, message: be =~ /GitHub unavailable/)
		@publisher.fail_release = false
		restore
		expect(Bake::Gem::GitHub::Publisher).to receive(:new).with(root).and_return(@publisher)
		Bake::Context.load(root).call("gem:github:release:publish", "number=42")
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
	
	it "uses the created draft response when the release list remains stale" do
		@publisher.stale_release_list = true
		receipt = @publisher.publish(42)
		expect(@publisher.releases.size).to be == 1
		expect(@publisher.releases.first.fetch("draft")).to be == false
		expect(@publisher.remote_digest).to be == receipt.fetch(:sha256)
		expect(@publisher.stored_files.keys.sort).to be == ["example-1.0.1.gem", "example-1.0.1.gem.sigstore.json", "provenance.sigstore.json", "release.json"]
	end
	
	it "restores an existing draft hidden by a stale release list without creating another" do
		@publisher.fail_release = true
		expect{@publisher.publish(42)}.to raise_exception(RuntimeError, message: be =~ /GitHub unavailable/)
		@publisher.stale_release_list = true
		@publisher.fail_release = false
		restore
		@publisher.publish(42)
		expect(@publisher.releases.size).to be == 1
		expect(@publisher.releases.first.fetch("draft")).to be == false
		expect(@publisher.commands.count{|args| args[0, 2] == ["gem", "push"]}).to be == 1
	end
	
	it "does not interpret a failed direct lookup as an absent release" do
		mock(@publisher) do |wrapper|
			wrapper.wrap(:readlines) do |original, *arguments, **options|
				raise "GitHub lookup failed" if arguments[0, 3] == ["gh", "api", "graphql"]
				original.call(*arguments, **options)
			end
		end
		expect{@publisher.publish(42)}.to raise_exception(RuntimeError, message: be =~ /lookup failed/)
		expect(@publisher.releases).to be == []
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
		expect(@publisher.commands.any?{|args| args.include?("POST")}).to be == false
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
