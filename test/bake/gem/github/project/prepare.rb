# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/repository_context"
require "bake/gem/github/project_client"

describe Bake::Gem::GitHub::Project do
	include Bake::Gem::GitHub::RepositoryContext
	
	with "#prepare" do
		def prepare(refresh: false, pulls: [])
			isolated_project(<<~'RUBY', env: {"REFRESH" => refresh.to_s, "PULLS" => JSON.generate(pulls)})
				project = Bake::Gem::GitHub::ProjectClient.new(Dir.pwd)
				project.pulls = JSON.parse(ENV.fetch("PULLS"))
				project.prepare(Bake::Context.load(Dir.pwd), "patch", refresh: ENV.fetch("REFRESH") == "true")
			RUBY
		end
		
		let(:pull) {{"headRefName" => "releases/v1.0.1", "url" => "existing", "isCrossRepository" => false}}
		
		def advance_main
			git("checkout", "--quiet", "main")
			File.write(File.join(repository, "releases.md"), "## Unreleased\n\nAn additional change.\n")
			git("add", "releases.md")
			git("commit", "--quiet", "-m", "Document the additional change")
			git("push", "--quiet", "origin", "main")
		end
		
		it "resumes PR creation after the release branch was pushed" do
			expect do
				isolated_project(<<~'RUBY')
					require "sus/mock"
					project = Bake::Gem::GitHub::ProjectClient.new(Dir.pwd)
					Sus::Mock.new(project).wrap(:readlines) do |original, *arguments, **options|
						raise "PR creation interrupted" if arguments[0, 3] == ["gh", "pr", "create"]
						original.call(*arguments, **options)
					end
					project.prepare(Bake::Context.load(Dir.pwd), "patch")
				RUBY
			end.to raise_exception(RuntimeError, message: be =~ /PR creation interrupted/)
			original = git("rev-parse", "HEAD")
			git("checkout", "--quiet", "main")
			expect(prepare).to be == "https://github.com/socketry/example/pull/42"
			expect(git("rev-parse", "releases/v1.0.1", chdir: File.join(root, "remote"))).to be == original
		end
		
		it "resumes a prepared local branch that has not been pushed" do
			isolated_project('Bake::Context.load(Dir.pwd).call("gem:release:branch:patch")')
			original = git("rev-parse", "HEAD")
			git("checkout", "--quiet", "main")
			prepare
			expect(git("rev-parse", "releases/v1.0.1", chdir: File.join(root, "remote"))).to be == original
		end
		
		it "rejects stale generated content without changing the release branch" do
			prepare
			original = git("rev-parse", "HEAD")
			advance_main
			expect{prepare(pulls: [pull])}.to raise_exception(RuntimeError, message: be =~ /Release content is stale/)
			expect(git("rev-parse", "releases/v1.0.1", chdir: File.join(root, "remote"))).to be == original
		end
		
		it "preserves manual edits before refreshing an existing PR from the current base" do
			prepare
			File.write(File.join(repository, "manual.md"), "Keep this for review.\n")
			git("add", "manual.md")
			git("commit", "--quiet", "-m", "Manual release edits")
			git("push", "--quiet", "origin", "releases/v1.0.1")
			original = git("rev-parse", "HEAD")
			advance_main
			expect(prepare(refresh: true, pulls: [pull])).to be == "existing"
			remote = File.join(root, "remote")
			expect(git("rev-parse", "release-backups/v1.0.1/#{original}", chdir: remote)).to be == original
			expect(git("show", "release-backups/v1.0.1/#{original}:manual.md", chdir: remote)).to be == "Keep this for review."
			expect(git("show", "releases/v1.0.1:releases.md", chdir: remote)).to be == "## v1.0.1\n\nAn additional change."
			expect(git("rev-parse", "releases/v1.0.1^", chdir: remote)).to be == git("rev-parse", "main")
			expect(git("rev-parse", "releases/v1.0.1")).to be == original
		end
		
		it "does not replace a concurrent remote update during refresh" do
			prepare
			original = git("rev-parse", "HEAD")
			advance_main
			expect do
				isolated_project(<<~'RUBY')
					require "sus/mock"
					project = Bake::Gem::GitHub::ProjectClient.new(Dir.pwd)
					Sus::Mock.new(project).wrap(:system) do |call, *arguments, **options|
						if arguments.any?{|argument| argument.start_with?("--force-with-lease=")}
							commit = project.readlines("git", "commit-tree", "releases/v1.0.1^{tree}", "-p", "releases/v1.0.1", "-m", "Concurrent edit").join.strip
							call.call("git", "push", "--quiet", "origin", "#{commit}:refs/heads/releases/v1.0.1")
						end
						call.call(*arguments, **options)
					end
					project.prepare(Bake::Context.load(Dir.pwd), "patch", refresh: true)
				RUBY
			end.to raise_exception(Bake::Gem::CommandExecutionError)
			expect(git("show", "-s", "--format=%s", "releases/v1.0.1", chdir: File.join(root, "remote"))).to be == "Concurrent edit"
			expect(git("rev-parse", "release-backups/v1.0.1/#{original}", chdir: File.join(root, "remote"))).to be == original
		end
		
		it "refuses multiple open release PRs" do
			expect{prepare(pulls: [pull, pull.merge("headRefName" => "releases/v1.1.0")])}.to raise_exception(RuntimeError, message: be =~ /Multiple release PRs/)
		end
		
		it "refuses to change the bump type of an existing PR" do
			expect{prepare(pulls: [pull.merge("headRefName" => "releases/v1.1.0")])}.to raise_exception(RuntimeError, message: be =~ /use its bump type/)
		end
		
		it "rejects a valid release stored under another version's branch name" do
			isolated_project('Bake::Context.load(Dir.pwd).call("gem:release:branch:minor")')
			git("branch", "--move", "releases/v1.0.1")
			git("checkout", "--quiet", "main")
			expect{prepare}.to raise_exception(RuntimeError, message: be =~ /requested version 1.0.1/)
		end
		
		it "does not mistake a fork release PR for the repository release branch" do
			expect(prepare(pulls: [pull.merge("isCrossRepository" => true)])).to be == "https://github.com/socketry/example/pull/42"
		end
	end
end
