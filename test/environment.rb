# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/repository_context"
require "bake/gem/github/publisher"

describe Bake::Gem::GitHub::Publisher do
	include Bake::Gem::GitHub::RepositoryContext
	
	it "builds unsigned committed source without a private key" do
		result = isolated_project(<<~'RUBY', env: {"GEM_SIGNING_KEY" => nil})
			require "bake/gem/github/publisher"
			publisher = Bake::Gem::GitHub::Publisher.new(Dir.pwd)
			path = publisher.send(:build_package, File.join(Dir.pwd, "pkg"))
			package = Gem::Package.new(path)
			{version: package.spec.version.to_s, certificates: package.spec.cert_chain}
		RUBY
		expect(result).to be == {version: "1.0.0", certificates: []}
	end
	
	it "accepts only the configured repository and default branch environment" do
		result = isolated_project(<<~'RUBY', env: {"GITHUB_REPOSITORY" => "socketry/example", "GITHUB_REF" => "refs/heads/main"})
			require "bake/gem/github/publisher"
			Bake::Gem::GitHub::Publisher.new(Dir.pwd).send(:guard_environment)
			true
		RUBY
		expect(result).to be == true
	end
	
	[
		[{"GITHUB_REPOSITORY" => "elsewhere/example", "GITHUB_REF" => "refs/heads/main"}, /configured GitHub repository/],
		[{"GITHUB_REPOSITORY" => "socketry/example", "GITHUB_REF" => "refs/pull/42/merge"}, /default branch workflow/]
	].each do |environment, message|
		it "rejects an unauthorized publishing environment", unique: environment do
			expect do
				isolated_project(<<~'RUBY', env: environment)
					require "bake/gem/github/publisher"
					Bake::Gem::GitHub::Publisher.new(Dir.pwd).send(:guard_environment)
				RUBY
			end.to raise_exception(RuntimeError, message: be =~ message)
		end
	end
	
	it "emits restored artifact outputs for later workflow steps" do
		output = File.join(root, "output")
		isolated_project(<<~'RUBY', env: {"GITHUB_OUTPUT" => output})
			require "bake/gem/github/publisher"
			receipt = {file: "example-1.0.0.gem", commit: "a" * 40}
			Bake::Gem::GitHub::Publisher.new(Dir.pwd).send(:output, receipt, restored: true)
		RUBY
		expect(File.readlines(output, chomp: true)).to be == ["package=pkg/example-1.0.0.gem", "artifact=release-#{'a' * 40}", "restored=true"]
	end
	
	it "clears Bundler variables only inside the gem command" do
		result = isolated_project(<<~'RUBY')
			require "bake/gem/github/publisher"
			publisher = Bake::Gem::GitHub::Publisher.new(Dir.pwd)
			def publisher.system(*arguments, **options)
				{arguments: arguments, gemfile: ENV["BUNDLE_GEMFILE"], directory: options[:chdir]}
			end
			original = ENV.fetch("BUNDLE_GEMFILE")
			result = publisher.send(:gem_command, "push", "example.gem")
			result.merge(restored: ENV["BUNDLE_GEMFILE"] == original)
		RUBY
		expect(result).to be == {arguments: ["gem", "push", "example.gem"], gemfile: nil, directory: File.realpath(repository), restored: true}
	end
end
