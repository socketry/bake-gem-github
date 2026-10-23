# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/publisher"
require "open3"
require "sus/fixtures/temporary_directory_context"
require "sus/fixtures/isolated_ruby_context"

describe Bake::Gem::GitHub::Publisher do
	include Sus::Fixtures::TemporaryDirectoryContext
	include Sus::Fixtures::IsolatedRubyContext
	
	let(:publisher) {subject.new(root)}
	let(:commit) {git("rev-parse", "HEAD")}
	
	def git(*arguments)
		output, status = Open3.capture2e("git", *arguments, chdir: root)
		raise output unless status.success?
		output.strip
	end
	
	before do
		Bake::Gem::GitHub::Setup.new(root).generate(repository: "socketry/example", checks: ["Test"])
		git("init", "--initial-branch=main")
		git("config", "core.hooksPath", File::NULL)
		git("config", "user.name", "Test")
		git("config", "user.email", "test@example.com")
		git("add", "--all")
		git("commit", "-m", "Initial source")
	end
	
	it "detects a changed retained artifact" do
		FileUtils.mkdir_p(File.join(root, "pkg"))
		File.write(File.join(root, "pkg", "example-1.0.1.gem"), "Original")
		receipt = {file: "example-1.0.1.gem", sha256: Digest::SHA256.hexdigest("Original")}
		File.write(File.join(root, "pkg", "release.json"), JSON.generate(receipt))
		
		expect(publisher.load_receipt).to be == receipt
		File.write(File.join(root, "pkg", "example-1.0.1.gem"), "Changed")
		
		expect{publisher.load_receipt}.to raise_exception(RuntimeError, message: be =~ /digest mismatch/)
	end
	
	it "rejects an artifact path outside pkg" do
		FileUtils.mkdir_p(File.join(root, "pkg"))
		File.write(File.join(root, "pkg", "release.json"), JSON.generate(file: "../example.gem"))
		
		expect{publisher.load_receipt}.to raise_exception(RuntimeError, message: be =~ /filename/)
	end
	
	it "rejects existing tags which name a different commit" do
		commit
		git("tag", "v1.0.1")
		git("commit", "--allow-empty", "-m", "Later source")
		
		expect{publisher.guard_tag("v1.0.1", git("rev-parse", "HEAD"))}.to raise_exception(RuntimeError, message: be =~ /another commit/)
		expect(git("rev-parse", "v1.0.1")).to be == commit
	end
	
	it "rejects unmerged PRs before any git or publishing command" do
		expect(publisher).to receive(:api).with("pulls/42").and_return({"merged" => false})
		expect{publisher.merged(42)}.to raise_exception(RuntimeError, message: be =~ /must be merged/)
	end
	
	it "rejects a PR merged into another branch" do
		expect(publisher).to receive(:api).with("pulls/42").and_return({"merged" => true, "base" => {"ref" => "other"}})
		expect{publisher.merged(42)}.to raise_exception(RuntimeError, message: be =~ /configured branch/)
	end
	
	it "builds unsigned committed source despite legacy signing settings and a dirty checkout" do
		config_path = File.join(root, "config/release.yaml")
		config = YAML.safe_load_file(config_path).merge("signing" => true)
		File.write(config_path, YAML.dump(config))
		File.write(File.join(root, "release.cert"), "Legacy certificate")
		File.write(File.join(root, "example.rb"), "ORIGINAL")
		File.write(File.join(root, "example.gemspec"), <<~RUBY)
			Gem::Specification.new do |spec|
				spec.name = "example"
				spec.version = "1.0.1"
				spec.authors = ["Test"]
				spec.summary = "Test gem"
				spec.files = ["example.rb"]
				spec.cert_chain = ["release.cert"]
				spec.signing_key = "/missing/private-key.pem"
			end
		RUBY
		git("add", "--all")
		git("commit", "-m", "Gem source with legacy signing settings")
		File.write(File.join(root, "example.rb"), "DIRTY")
		result = isolated_ruby(<<~'RUBY', chdir: root, env: {"GEM_SIGNING_KEY" => nil}, requires: ["bundler/setup", "bake/gem/github/publisher"])
			publisher = Bake::Gem::GitHub::Publisher.new(Dir.pwd)
			package_path = publisher.send(:build_package, File.join(Dir.pwd, "pkg"))
			package = Gem::Package.new(package_path)
			package.verify
			package.extract_files("extracted")
			signatures = []
			File.open(package_path, "rb") do |file|
				Gem::Package::TarReader.new(file) do |tar|
					tar.each{|entry| signatures << entry.full_name if entry.full_name.end_with?(".sig")}
				end
			end
			{content: File.read("extracted/example.rb"), signatures: signatures}
		RUBY
		
		expect(result[:content]).to be == "ORIGINAL"
		expect(result[:signatures]).to be == []
	end
end
