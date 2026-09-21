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
		Bake::Gem::GitHub::Setup.new(root).generate(repository: "socketry/example", checks: ["Test"], signing: false)
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
	
	it "certificate-signs committed source and excludes dirty checkout content" do
		key = OpenSSL::PKey::RSA.new(2048)
		certificate = OpenSSL::X509::Certificate.new
		certificate.version = 2
		certificate.serial = 1
		certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=Release Test")
		certificate.public_key = key.public_key
		certificate.not_before = Time.now - 60
		certificate.not_after = Time.now + 3600
		certificate.sign(key, OpenSSL::Digest.new("SHA256"))
		File.write(File.join(root, "release.cert"), certificate.to_pem)
		File.write(File.join(root, "example.rb"), "ORIGINAL")
		File.write(File.join(root, "example.gemspec"), <<~RUBY)
			Gem::Specification.new do |spec|
				spec.name = "example"
				spec.version = "1.0.1"
				spec.authors = ["Test"]
				spec.summary = "Test gem"
				spec.files = ["example.rb"]
				spec.cert_chain = ["release.cert"]
			end
		RUBY
		git("add", "--all")
		git("commit", "-m", "Gem source and public certificate")
		File.write(File.join(root, "example.rb"), "DIRTY")
		result = isolated_ruby(<<~'RUBY', chdir: root, env: {"GEM_SIGNING_KEY" => key.to_pem}, requires: ["bundler/setup", "bake/gem/github/publisher"])
			publisher = Bake::Gem::GitHub::Publisher.new(Dir.pwd)
			publisher.config["signing"] = true
			package_path = publisher.send(:build_package, File.join(Dir.pwd, "pkg"))
			package = Gem::Package.new(package_path, Gem::Security::Policy.new("Release", only_trusted: false))
			package.verify
			package.extract_files("extracted")
			{content: File.read("extracted/example.rb"), signer: OpenSSL::X509::Certificate.new(package.spec.cert_chain.last).to_der}
		RUBY
		expect(result[:content]).to be == "ORIGINAL"
		expect(result[:signer]).to be == certificate.to_der
	end
end
