# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/repository_context"
require "bake/gem/github/project_client"

describe "GitHub release tasks" do
	include Bake::Gem::GitHub::RepositoryContext
	
	with "gem:github:setup" do
		it "discovers the canonical repository and default branch through gh" do
			bin = File.join(root, "bin")
			FileUtils.mkdir_p(bin)
			File.write(File.join(bin, "gh"), <<~'RUBY')
				#!/usr/bin/env ruby
				require "json"
				abort "Unexpected GitHub command" unless ARGV == ["repo", "view", "--json", "nameWithOwner,defaultBranchRef"]
				puts JSON.generate(nameWithOwner: "socketry/example", defaultBranchRef: {name: "main"})
			RUBY
			File.chmod(0755, File.join(bin, "gh"))
			isolated_project('Bake::Context.load(Dir.pwd).call("gem:github:setup", "checks=Tests", "signing=false")', env: {"PATH" => "#{bin}:#{ENV.fetch('PATH')}"})
			
			expect(YAML.safe_load_file(File.join(repository, "config/release.yaml"))).to have_keys("repository" => be == "socketry/example", "branch" => be == "main")
		end
	end
	
	%w[patch minor major].zip(%w[1.0.1 1.1.0 2.0.0]).each do |bump, version|
		with "gem:github:release:#{bump}" do
			it "prepares the requested release through the public task" do
				result = isolated_project(<<~'RUBY', env: {"BUMP" => bump})
					require "sus/mock"
					project = Bake::Gem::GitHub::ProjectClient.new(Dir.pwd)
					Sus::Mock.new(Bake::Gem::GitHub::Project).replace(:new){project}
					Bake::Context.load(Dir.pwd).call("gem:github:release:#{ENV.fetch('BUMP')}")
				RUBY
				
				expect(result).to be == "https://github.com/socketry/example/pull/42"
				expect(git("branch", "--show-current")).to be == "releases/v#{version}"
			end
		end
	end
	
	with "gem:github:release:resolve" do
		[false, true].each do |release|
			it "writes workflow outputs for the actual merged PR", unique: release do
				output = File.join(root, "output")
				result = isolated_project(<<~'RUBY', env: {"RELEASE" => release.to_s, "RELEASE_PR" => "42", "GITHUB_OUTPUT" => output})
					require "sus/mock"
					project = Bake::Gem::GitHub::ProjectClient.new(Dir.pwd)
					context = Bake::Context.load(Dir.pwd)
					if ENV.fetch("RELEASE") == "true"
						project.prepare(context, "patch")
						project.system("git", "checkout", "--quiet", "main")
						project.system("git", "merge", "--quiet", "--no-ff", "releases/v1.0.1", "-m", "Merge release")
					else
						project.system("git", "commit", "--quiet", "--allow-empty", "-m", "Ordinary change")
					end
					project.system("git", "push", "--quiet", "origin", "main")
					commit = project.readlines("git", "rev-parse", "HEAD").join.strip
					project.responses["repos/socketry/example/pulls/42"] = {
						"number" => 42, "merged" => true, "base" => {"ref" => "main", "repo" => {"full_name" => "socketry/example"}},
						"merge_commit_sha" => commit, "html_url" => "https://github.com/socketry/example/pull/42"
					}
					Sus::Mock.new(Bake::Gem::GitHub::Project).replace(:new){project}
					context.call("gem:github:release:resolve")
				RUBY
				
				expect(result.nil?).to be == !release
				expect(File.readlines(output, chomp: true)).to be == (release ? ["release=true", "commit=#{git('rev-parse', 'HEAD')}"] : ["release=false"])
			end
		end
	end
	
	with "gem:github:release:resume" do
		let(:project) {Bake::Gem::GitHub::ProjectClient.new(repository)}
		let(:context) {Bake::Context.load(repository)}
		
		before do
			expect(Bake::Gem::GitHub::Project).to receive(:new).with(repository).and_return(project)
		end
		
		it "reruns the original publishing run" do
			project.responses["repos/socketry/example/actions/runs/123"] = {"path" => ".github/workflows/release-publish.yaml"}
			
			expect(project).to receive(:system).with("gh", "run", "rerun", "123", "--repo", "socketry/example", chdir: repository).and_return(true)
			context.call("gem:github:release:resume", "run=123")
		end
		
		it "refuses a run belonging to another workflow" do
			project.responses["repos/socketry/example/actions/runs/123"] = {"path" => ".github/workflows/test.yaml"}
			
			expect{context.call("gem:github:release:resume", "run=123")}.to raise_exception(RuntimeError, message: be =~ /Expected a release-publish workflow run/)
			expect(project.writes).to be == []
		end
	end
end
