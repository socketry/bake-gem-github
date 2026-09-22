# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/release"
require "yaml"
require "tempfile"
require_relative "setup"

module Bake
	module Gem
		module GitHub
			# GitHub operations invoked by local tasks and repository workflows.
			class Project
				include Shell
				
				# Load the reviewed repository release policy.
				def initialize(root)
					@root = File.expand_path(root)
					@config = YAML.safe_load_file(File.join(@root, "config/release.yaml"))
					raise "Unsupported release configuration." unless @config.fetch("schema") == 1
					@repository = @config.fetch("repository")
					@release = Release.new(@root)
				end
				
				# @attribute [Hash] Reviewed desired policy.
				attr_reader :config
				
				# Execute a GitHub API read. Failures never imply that a resource is absent.
				def api(path)
					JSON.parse(readlines("gh", "api", "repos/#{@repository}/#{path}", chdir: @root).join)
				end
				
				# Prepare a release through core Bake tasks, then push and create its pull request.
				def prepare(context, bump, refresh: false)
					Release::BUMPS.fetch(bump)
					helper = Helper.new(@root)
					helper.guard_clean
					
					branch = @config.fetch("branch")
					raise "Prepare releases from #{branch}." unless helper.current_branch == branch
					system("git", "fetch", "origin", branch, "--tags", chdir: @root)
					raise "Local branch differs from origin/#{branch}." unless @release.resolve("HEAD") == @release.resolve("origin/#{branch}")
					
					pulls = JSON.parse(readlines(
						"gh", "pr", "list", "--repo", @repository, "--base", branch, "--state", "open",
						"--json", "headRefName,url,isCrossRepository", "--limit", "1000", chdir: @root,
					).join)
					pulls = pulls.select{|pr| !pr["isCrossRepository"] && pr.fetch("headRefName").start_with?("releases/v")}
					raise "Multiple release PRs are open; select one before preparing another release." if pulls.size > 1
					
					existing = pulls.first
					version = Version.new(helper.gemspec.version.segments, nil).increment(Release::BUMPS.fetch(bump)).join
					name = "releases/v#{version}"
					raise "Existing release PR uses #{existing.fetch('headRefName')}; use its bump type or close it first." if existing && existing.fetch("headRefName") != name
					
					base = @release.resolve("HEAD")
					ref = "refs/heads/#{name}"
					remote = readlines("git", "ls-remote", "--heads", "origin", ref, chdir: @root).first
					if remote
						system("git", "fetch", "origin", ref, chdir: @root)
						remote = @release.resolve("FETCH_HEAD")
					end
					
					candidate = remote
					if !candidate && readlines("git", "branch", "--list", name, chdir: @root).any?
						candidate = @release.resolve(ref)
					end
					
					if candidate && refresh
						# Preserve the complete previous tree before replacing the release branch:
						backup = "refs/heads/release-backups/v#{version}/#{candidate}"
						push("#{candidate}:#{backup}")
						candidate = @release.worktree(base) do |path|
							@release.bake(path, "gem:release:version:#{bump}")
							readlines("git", "rev-parse", "HEAD", chdir: path).join.strip
						end
					elsif !candidate
						context.lookup("gem:release:branch:#{bump}").call
						candidate = @release.resolve("HEAD")
					end
					
					metadata = @release.validate(base: base, candidate: candidate)
					raise "Release branch does not contain the requested version #{version}." unless metadata.fetch(:version) == version
					
					push("--force-with-lease=#{ref}:#{remote}", "#{candidate}:#{ref}")
					return existing.fetch("url") if existing
					
					body = <<~BODY
						Release #{helper.gemspec.name} #{version}.

						Prepared from #{base}. The complete release tree is regenerated during validation. \
						Merging publishes the resulting commit through release-publish.yaml after native \
						reviews and required CI (or explicit administrator bypass).
					BODY
					
					return Tempfile.create("release-pr") do |file|
						file.write(body)
						file.flush
						readlines(
							"gh", "pr", "create", "--repo", @repository, "--base", branch, "--head", name,
							"--title", "Release v#{version}", "--body-file", file.path, chdir: @root,
						).join.strip
					end
				end
				
				# Resolve a merged PR through GitHub, and require its actual merge commit in default-branch history.
				def merged(number)
					raise "Expected a PR number." unless number.to_s.match?(/\A[1-9]\d*\z/)
					pr = api("pulls/#{number}")
					raise "PR must be merged into the configured branch." unless pr["merged"] && pr.dig("base", "ref") == @config.fetch("branch") && pr.dig("base", "repo", "full_name") == @repository
					
					commit = pr.fetch("merge_commit_sha")
					raise "Invalid merged commit." unless commit.match?(/\A[0-9a-f]{40,64}\z/)
					
					system("git", "fetch", "origin", @config.fetch("branch"), "--tags", chdir: @root)
					system("git", "merge-base", "--is-ancestor", commit, "origin/#{@config.fetch('branch')}", chdir: @root)
					
					return pr
				end
				
				# Resolve release identity; ordinary merged PRs do not publish.
				def inspect_release(number)
					pr = merged(number)
					
					commit = pr.fetch("merge_commit_sha")
					metadata = @release.validate(base: "#{commit}^1", candidate: commit, optional: true)
					if metadata
						return metadata.merge(
							repository: @repository,
							pull_request: pr.fetch("number"),
							merged_by: pr.dig("merged_by", "login"),
							pull_request_url: pr.fetch("html_url"),
						)
					end
				end
				
				# Return a read-only comparison of managed settings and current repository settings.
				def doctor
					{
						desired_rules: Setup.rules(@config),
						existing_rules: api("rulesets?per_page=100"),
						environments: api("environments"),
						trusted_publisher: {
							repository_owner: @repository.split("/").first,
							repository_name: @repository.split("/").last,
							workflow_filename: "release-publish.yaml",
							environment: @config.fetch("environment"),
						}
					}
				end
				
				# Apply only the named rulesets generated by setup. Invoke after reviewing doctor output.
				def apply
					existing = api("rulesets?per_page=100")
					return Setup.rules(@config).each_value do |rule|
						matches = existing.select{|current| current.fetch("name") == rule.fetch(:name)}
						raise "Multiple rulesets match #{rule[:name]}." if matches.size > 1
						current = matches.first
						path = "repos/#{@repository}/rulesets"
						path += "/#{current.fetch('id')}" if current
						
						Tempfile.create("release-rule") do |file|
							file.write(JSON.generate(rule))
							file.flush
							system("gh", "api", path, "--method", current ? "PUT" : "POST", "--input", file.path, chdir: @root)
						end
					end
				end
				
				private
				
				def push(*arguments)
					system("git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential", "push", "origin", *arguments, chdir: @root)
				end
			end
		end
	end
end
