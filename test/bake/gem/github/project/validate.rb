# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/repository_context"
require "bake/gem/github/project_client"

describe Bake::Gem::GitHub::Project do
	include Bake::Gem::GitHub::RepositoryContext
	
	let(:project) {Bake::Gem::GitHub::ProjectClient.new(repository)}
	
	with "#validate" do
		it "accepts a single generated release commit through the public task" do
			isolated_project('Bake::Context.load.call("gem:release:branch:patch")')
			commit = git("rev-parse", "HEAD")
			git("checkout", "--quiet", "main")
			result = isolated_project('Bake::Context.load.call("gem:github:release:validate", "base=main", "candidate=releases/v1.0.1")')
			
			expect(result).to have_keys(version: be == "1.0.1", bump: be == "patch", commit: be == commit, base: be == git("rev-parse", "main"))
		end
		
		it "accepts ordinary PRs containing multiple commits without GitHub access" do
			git("checkout", "--quiet", "-b", "feature")
			2.times do |index|
				File.write(File.join(repository, "readme.md"), "Change #{index}.\n")
				git("add", "readme.md")
				git("commit", "--quiet", "-m", "Change #{index}")
			end
			
			expect(project.validate(base: "main")).to be_nil
			expect(project.requests).to be == []
		end
		
		it "rejects a correct release tree split across multiple commits" do
			isolated_project('Bake::Context.load.call("gem:release:branch:patch")')
			expected_tree = git("rev-parse", "HEAD^{tree}")
			git("reset", "--quiet", "--mixed", "main")
			git("add", "lib/example/version.rb")
			git("commit", "--quiet", "-m", "Bump version")
			git("add", "releases.md")
			git("commit", "--quiet", "-m", "Update release notes")
			
			expect(git("rev-parse", "HEAD^{tree}")).to be == expected_tree
			expect{project.validate(base: "main")}.to raise_exception(RuntimeError, message: be =~ /exactly one commit/)
		end
		
		it "rejects an extra empty commit on a release PR" do
			isolated_project('Bake::Context.load.call("gem:release:branch:patch")')
			git("commit", "--quiet", "--allow-empty", "-m", "Extra commit")
			
			expect{project.validate(base: "main")}.to raise_exception(RuntimeError, message: be =~ /Amend or regenerate/)
		end
		
		it "still rejects unrelated changes in a single release commit" do
			isolated_project('Bake::Context.load.call("gem:release:branch:patch")')
			File.write(File.join(repository, "unrelated.md"), "Unrelated content.\n")
			git("add", "unrelated.md")
			git("commit", "--quiet", "--amend", "--no-edit")
			
			expect{project.validate(base: "main")}.to raise_exception(RuntimeError, message: be =~ /stale or contains unrelated changes/)
		end
	end
end
