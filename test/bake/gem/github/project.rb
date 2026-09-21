# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/repository_context"
require "bake/gem/github/project_client"

describe Bake::Gem::GitHub::Project do
	include Bake::Gem::GitHub::RepositoryContext
	
	with "#prepare" do
		it "prepares, validates, and pushes a release before opening its PR" do
			result = isolated_project(<<~'RUBY')
				project = Bake::Gem::GitHub::ProjectClient.new(Dir.pwd)
				url = project.prepare(Bake::Context.load(Dir.pwd), "patch")
				{url: url, body: project.writes.first}
			RUBY
			expect(result[:url]).to be == "https://github.com/socketry/example/pull/42"
			expect(result[:body]).to be(:include?, "Release example 1.0.1.")
			expect(git("branch", "--show-current")).to be == "releases/v1.0.1"
			expect(git("rev-parse", "HEAD")).to be == git("rev-parse", "refs/heads/releases/v1.0.1", chdir: File.join(root, "remote"))
			expect(File.read(File.join(repository, "releases.md"))).to be(:include?, "## v1.0.1")
			expect(git("tag", "--list")).to be == ""
			git("checkout", "--quiet", "main")
			git("merge", "--quiet", "--no-ff", "releases/v1.0.1", "-m", "Merge release")
			git("push", "--quiet", "origin", "main")
			commit = git("rev-parse", "HEAD")
			project = Bake::Gem::GitHub::ProjectClient.new(repository)
			project.responses["repos/socketry/example/pulls/42"] = {
				"number" => 42, "merged" => true, "base" => {"ref" => "main", "repo" => {"full_name" => "socketry/example"}},
				"merge_commit_sha" => commit, "merged_by" => {"login" => "maintainer"}, "html_url" => result[:url]
			}
			evidence = project.inspect_release(42)
			expect(evidence).to have_keys(name: be == "example", version: be == "1.0.1", commit: be == commit, merged_by: be == "maintainer")
		end
		
		it "validates an existing release PR without creating another" do
			isolated_project('Bake::Gem::GitHub::ProjectClient.new(Dir.pwd).prepare(Bake::Context.load(Dir.pwd), "patch")')
			original = git("rev-parse", "HEAD")
			git("checkout", "--quiet", "main")
			url = isolated_project(<<~'RUBY')
				project = Bake::Gem::GitHub::ProjectClient.new(Dir.pwd)
				project.pulls = [{"headRefName" => "releases/v1.0.1", "url" => "existing"}]
				project.prepare(Bake::Context.load(Dir.pwd), "patch")
			RUBY
			expect(url).to be == "existing"
			expect(git("branch", "--show-current")).to be == "main"
			expect(git("rev-parse", "releases/v1.0.1")).to be == original
		end
		
		it "refuses preparation from another branch" do
			git("checkout", "--quiet", "-b", "feature")
			expect do
				isolated_project('Bake::Gem::GitHub::ProjectClient.new(Dir.pwd).prepare(Bake::Context.load(Dir.pwd), "patch")')
			end.to raise_exception(RuntimeError, message: be =~ /Prepare releases from main/)
		end
		
		it "refuses preparation when the local default branch differs from origin" do
			git("commit", "--quiet", "--allow-empty", "-m", "Local change")
			expect do
				isolated_project('Bake::Gem::GitHub::ProjectClient.new(Dir.pwd).prepare(Bake::Context.load(Dir.pwd), "patch")')
			end.to raise_exception(RuntimeError, message: be =~ /differs from origin/)
		end
	end
	
	with "#merged and #inspect_release" do
		let(:project) {Bake::Gem::GitHub::ProjectClient.new(repository)}
		let(:pull) {{"merged" => true, "base" => {"ref" => "main", "repo" => {"full_name" => "socketry/example"}}, "merge_commit_sha" => git("rev-parse", "HEAD")}}
		
		before do
			project.responses["repos/socketry/example/pulls/42"] = pull
		end
		
		it "accepts a merged commit in the remote default branch history" do
			git("commit", "--quiet", "--allow-empty", "-m", "Later development")
			git("push", "--quiet", "origin", "main")
			expect(project.merged(42)).to be == pull
		end
		
		it "rejects a commit outside the remote default branch history" do
			git("checkout", "--quiet", "-b", "unmerged")
			git("commit", "--quiet", "--allow-empty", "-m", "Unmerged change")
			pull["merge_commit_sha"] = git("rev-parse", "HEAD")
			expect{project.merged(42)}.to raise_exception(Bake::Gem::CommandExecutionError)
		end
		
		it "rejects invalid commit identifiers" do
			pull["merge_commit_sha"] = "--help"
			expect{project.merged(42)}.to raise_exception(RuntimeError, message: be =~ /Invalid merged commit/)
		end
		
		it "does not publish ordinary merged changes" do
			File.write(File.join(repository, "readme.md"), "An ordinary change.\n")
			git("add", "readme.md")
			git("commit", "--quiet", "-m", "Documentation")
			git("push", "--quiet", "origin", "main")
			pull["merge_commit_sha"] = git("rev-parse", "HEAD")
			expect(project.inspect_release(42)).to be_nil
		end
	end
	
	with "#doctor and #apply" do
		let(:project) {Bake::Gem::GitHub::ProjectClient.new(repository)}
		let(:rules) {[]}
		
		before do
			project.responses["repos/socketry/example/rulesets?per_page=100"] = rules
			project.responses["repos/socketry/example/environments"] = {"environments" => []}
		end
		
		it "reports desired and observed settings without writing" do
			expect(Bake::Gem::GitHub::Project).to receive(:new).with(repository).and_return(project)
			result = Bake::Context.load(repository).call("gem:github:setup:plan")
			expect(result[:desired_rules].keys).to be == %w[reviews checks history tags]
			expect(result[:existing_rules]).to be == []
			expect(result[:trusted_publisher][:workflow_filename]).to be == "release-publish.yaml"
			expect(project.writes).to be == []
		end
		
		it "creates missing managed rulesets while preserving unrelated rulesets" do
			rules << {"id" => 123, "name" => "Unrelated policy"}
			expect(Bake::Gem::GitHub::Project).to receive(:new).with(repository).and_return(project)
			Bake::Context.load(repository).call("gem:github:setup:apply")
			expect(project.writes.map{|rule| rule.fetch("name")}).to be == ["Gem release reviews", "Gem release checks", "Gem release history", "Gem release tags"]
			expect(project.requests.drop(1).all?{|request| request.include?("POST")}).to be == true
		end
		
		it "updates existing managed rulesets by ID" do
			Bake::Gem::GitHub::Setup.rules(project.config).values.each_with_index do |rule, index|
				rules << {"id" => index + 1, "name" => rule.fetch(:name)}
			end
			project.apply
			expect(project.requests.drop(1).map{|request| request[2]}).to be == (1..4).map{|id| "repos/socketry/example/rulesets/#{id}"}
			expect(project.requests.drop(1).all?{|request| request.include?("PUT")}).to be == true
		end
		
		it "refuses ambiguous managed rulesets" do
			rules.concat([{"id" => 1, "name" => "Gem release reviews"}, {"id" => 2, "name" => "Gem release reviews"}])
			expect{project.apply}.to raise_exception(RuntimeError, message: be =~ /Multiple rulesets/)
			expect(project.writes).to be == []
		end
	end
end
