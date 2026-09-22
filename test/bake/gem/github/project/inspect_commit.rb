# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/repository_context"
require "bake/gem/github/project_client"

describe Bake::Gem::GitHub::Project do
	include Bake::Gem::GitHub::RepositoryContext
	
	let(:project) {Bake::Gem::GitHub::ProjectClient.new(repository)}
	let(:commit) {git("rev-parse", "HEAD")}
	let(:pull) do
		{
			"number" => 42, "merged" => true, "merged_at" => "2026-09-22T00:00:00Z",
			"base" => {"ref" => "main", "repo" => {"full_name" => "socketry/example"}},
			"merge_commit_sha" => commit, "html_url" => "https://github.com/socketry/example/pull/42"
		}
	end
	let(:pages) {[[pull]]}
	
	def configure_pull
		project.responses["repos/socketry/example/commits/#{commit}/pulls?per_page=100"] = pages
		project.responses["repos/socketry/example/pulls/42"] = pull
	end
	
	with "#inspect_commit" do
		["--help", "main", "a" * 39, "a" * 41, "a" * 65, "a" * 40 + "/pulls"].each do |value|
			it "rejects invalid commit identifiers before calling GitHub", unique: value do
				expect{project.inspect_commit(value)}.to raise_exception(RuntimeError, message: be =~ /full pushed commit SHA/)
				expect(project.requests).to be == []
			end
		end
		
		with "ordinary changes" do
			before do
				git("commit", "--quiet", "--allow-empty", "-m", "Ordinary change")
				git("push", "--quiet", "origin", "main")
				configure_pull
			end
			
			it "does not publish an ordinary merged PR" do
				expect(project.inspect_commit(commit)).to be_nil
			end
			
			it "does not publish an ordinary direct push" do
				pages.clear
				
				expect(project.inspect_commit(commit)).to be_nil
			end
		end
		
		with "release changes" do
			before do
				isolated_project('Bake::Gem::GitHub::ProjectClient.new(Dir.pwd).prepare(Bake::Context.load(Dir.pwd), "patch")')
				git("checkout", "--quiet", "main")
				git("merge", "--quiet", "--no-ff", "releases/v1.0.1", "-m", "Merge release")
				git("push", "--quiet", "origin", "main")
				configure_pull
			end
			
			it "resolves the release after later commits land on the default branch" do
				git("commit", "--quiet", "--allow-empty", "-m", "Later development")
				git("push", "--quiet", "origin", "main")
				result = project.inspect_commit(commit)
				
				expect(result).to have_keys(version: be == "1.0.1", commit: be == commit, pull_request: be == 42)
				expect(result[:commit]).not.to be == git("rev-parse", "HEAD")
			end
			
			it "accepts a merged fork PR" do
				pull["head"] = {"repo" => {"full_name" => "contributor/example"}}
				
				expect(project.inspect_commit(commit)).to have_keys(commit: be == commit, pull_request: be == 42)
			end
			
			it "finds the exact merged PR across all response pages" do
				pages.unshift([pull.merge("merge_commit_sha" => "a" * 40)])
				
				expect(project.inspect_commit(commit)).to have_keys(pull_request: be == 42)
				expect(project.requests.first).to be == ["gh", "api", "repos/socketry/example/commits/#{commit}/pulls?per_page=100", "--paginate", "--slurp"]
			end
			
			it "rejects release changes without a matching merged PR" do
				pages.clear
				
				expect{project.inspect_commit(commit)}.to raise_exception(RuntimeError, message: be =~ /no matching merged PR/)
			end
			
			[
				{"merged_at" => nil},
				{"merge_commit_sha" => "a" * 40},
				{"base" => {"ref" => "other", "repo" => {"full_name" => "socketry/example"}}},
				{"base" => {"ref" => "main", "repo" => {"full_name" => "other/example"}}}
			].each do |change|
				it "rejects unrelated PR associations", unique: change.inspect do
					pages.replace([[pull.merge(change)]])
					
					expect{project.inspect_commit(commit)}.to raise_exception(RuntimeError, message: be =~ /no matching merged PR/)
				end
			end
			
			it "rejects ambiguous merged PR associations" do
				pages << [pull.merge("number" => 43)]
				
				expect{project.inspect_commit(commit)}.to raise_exception(RuntimeError, message: be =~ /Multiple merged PRs/)
			end
			
			it "rechecks the PR merge commit against the pushed commit" do
				git("commit", "--quiet", "--allow-empty", "-m", "Unrelated merge")
				git("push", "--quiet", "origin", "main")
				project.responses["repos/socketry/example/pulls/42"] = pull.merge("merge_commit_sha" => git("rev-parse", "HEAD"))
				
				expect{project.inspect_commit(commit)}.to raise_exception(RuntimeError, message: be =~ /does not match the pushed commit/)
			end
			
			it "rechecks that the PR is merged" do
				project.responses["repos/socketry/example/pulls/42"] = pull.merge("merged" => false)
				
				expect{project.inspect_commit(commit)}.to raise_exception(RuntimeError, message: be =~ /PR must be merged/)
			end
			
			it "propagates GitHub lookup failures" do
				error = Bake::Gem::CommandExecutionError.new("GitHub unavailable", nil)
				expect(project).to receive(:readlines).and_raise(error)
				
				expect{project.inspect_commit(commit)}.to raise_exception(Bake::Gem::CommandExecutionError)
			end
		end
		
		with "squash merges" do
			before do
				isolated_project('Bake::Gem::GitHub::ProjectClient.new(Dir.pwd).prepare(Bake::Context.load(Dir.pwd), "patch")')
				git("checkout", "--quiet", "main")
				git("merge", "--quiet", "--squash", "releases/v1.0.1")
				git("commit", "--quiet", "-m", "Squash release")
				git("push", "--quiet", "origin", "main")
				configure_pull
			end
			
			it "resolves the squash commit to its release PR" do
				expect(project.inspect_commit(commit)).to have_keys(version: be == "1.0.1", commit: be == commit, pull_request: be == 42)
			end
		end
	end
end
