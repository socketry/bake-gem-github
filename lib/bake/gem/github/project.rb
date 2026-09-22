# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/release"
require "yaml"
require "tempfile"
require "uri"
require_relative "setup"

module Bake
	module Gem
		module GitHub
			# GitHub operations invoked by local tasks and repository workflows.
			class Project
				include Shell
				
				# Load the reviewed repository release policy.
				# @parameter root [String] The repository root containing `config/release.yaml`.
				# @raises [RuntimeError] If the configuration schema is unsupported.
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
				# @parameter path [String] An API path relative to this repository.
				# @returns [Hash | Array] The decoded GitHub response, retaining string keys.
				# @raises [Bake::Gem::CommandExecutionError] If the GitHub request fails.
				def api(path)
					JSON.parse(readlines("gh", "api", "repos/#{@repository}/#{path}", chdir: @root).join)
				end
				
				# Prepare a release through core Bake tasks, then push and create its pull request.
				#
				# The process must already be in the repository root because {Bake::Gem::Helper} evaluates its gemspec.
				# Refresh preserves the previous release commit before replacing the remote branch with an explicit push lease.
				#
				# @parameter context [Bake::Context] The consumer context used to invoke core release tasks.
				# @parameter bump [String] The stable version increment: `patch`, `minor`, or `major`.
				# @parameter refresh [Boolean] Whether to regenerate an existing release from the current base.
				# @returns [String] The new or existing release PR URL.
				# @raises [RuntimeError] If the checkout, existing PR, or generated release content is unsuitable.
				# @raises [Bake::Gem::CommandExecutionError] If a Git or GitHub operation fails, including a conflicting push.
				def prepare(context, bump, refresh: false)
					Release::BUMPS.fetch(bump)
					helper = Helper.new(@root)
					helper.guard_clean
					
					branch = @config.fetch("branch")
					raise "Prepare releases from #{branch}." unless helper.current_branch == branch
					system("git", "fetch", "origin", branch, "--tags", chdir: @root)
					raise "Local branch differs from origin/#{branch}." unless @release.resolve("HEAD") == @release.resolve("origin/#{branch}")
					
					pull_request = find_release_pull_request(branch)
					version = Version.new(helper.gemspec.version.segments, nil).increment(Release::BUMPS.fetch(bump)).join
					release_branch = "releases/v#{version}"
					if pull_request && pull_request.fetch("headRefName") != release_branch
						raise "Existing release PR uses #{pull_request.fetch('headRefName')}; use its bump type or close it first."
					end
					
					base = @release.resolve("HEAD")
					release_ref = "refs/heads/#{release_branch}"
					remote_commit = fetch_release_branch(release_ref)
					candidate = remote_commit || local_release_commit(release_branch)
					
					if candidate && refresh
						candidate = refresh_release(candidate, base: base, bump: bump, version: version)
					elsif !candidate
						context.lookup("gem:release:branch:#{bump}").call
						candidate = @release.resolve("HEAD")
					end
					
					metadata = @release.validate(base: base, candidate: candidate)
					raise "Release branch does not contain the requested version #{version}." unless metadata.fetch(:version) == version
					
					push("--force-with-lease=#{release_ref}:#{remote_commit}", "#{candidate}:#{release_ref}")
					return pull_request.fetch("url") if pull_request
					
					return create_release_pull_request(
						helper.gemspec.name, version,
						branch: branch, release_branch: release_branch, base: base,
					)
				end
				
				# Resolve a merged PR through GitHub, and require its actual merge commit in default-branch history.
				# @parameter number [String | Integer] The positive PR number.
				# @returns [Hash] GitHub PR data with string keys, including `number` and `merge_commit_sha`.
				# @raises [RuntimeError] If the PR is invalid, unmerged, or targets another repository or branch.
				# @raises [Bake::Gem::CommandExecutionError] If its commit is outside the default branch history or a command fails.
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
				# @parameter number [String | Integer] The merged PR number.
				# @returns [Hash | Nil] Release metadata with symbol keys, or nil for an ordinary PR. Includes `name`, `version`, `commit`, `base`, `bump`, `repository`, `pull_request`, `merged_by`, and `pull_request_url`.
				# @raises [RuntimeError] If the merged source does not match the independently generated release.
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
				# @returns [Hash] Desired rules, existing rules, environments, optional environment changes, and expected Trusted Publisher settings. This does not verify RubyGems ownership or publisher configuration.
				def doctor
					{
						desired_rules: Setup.rules(@config),
						existing_rules: api("rulesets?per_page=100"),
						environments: api("environments"),
						environment_changes: environment_changes,
						trusted_publisher: {
							repository_owner: @repository.split("/").first,
							repository_name: @repository.split("/").last,
							workflow_filename: "release-publish.yaml",
							environment: @config.fetch("environment"),
						}
					}
				end
				
				# Apply the named rulesets and configured reviewers for an existing environment. Invoke after reviewing doctor output.
				# Preserves the environment's wait timer, self-review prevention, administrator bypass, and branch restrictions.
				# @returns [Hash] The desired ruleset payloads after successful application.
				# @raises [RuntimeError] If more than one existing ruleset has a managed name.
				# @raises [Bake::Gem::CommandExecutionError] If an API operation fails; earlier updates may already have completed.
				def apply
					changes = environment_changes
					existing = api("rulesets?per_page=100")
					rules = Setup.rules(@config)
					rules.each_value do |rule|
						matches = existing.select{|current| current.fetch("name") == rule.fetch(:name)}
						raise "Multiple rulesets match #{rule[:name]}." if matches.size > 1
						current = matches.first
						path = "repos/#{@repository}/rulesets"
						path += "/#{current.fetch('id')}" if current
						
						write_api(path, rule, method: current ? "PUT" : "POST")
					end
					
					if changes && changes.fetch(:current) != changes.fetch(:desired)
						write_api("repos/#{@repository}/#{environment_path}", changes.fetch(:desired), method: "PUT")
					end
					
					return rules
				end
				
				private
				
				def environment_path
					"environments/#{URI.encode_www_form_component(@config.fetch('environment')).gsub('+', '%20')}"
				end
				
				# Resolve reviewers before making any changes, and preserve unrelated environment settings.
				def environment_changes
					return nil unless @config.key?("reviewers")
					Setup.validate_reviewers(@config["reviewers"])
					
					environment = api(environment_path)
					protections = environment.fetch("protection_rules").to_h{|rule| [rule.fetch("type"), rule]}
					reviews = protections.fetch("required_reviewers", {})
					current = {
						wait_timer: protections.fetch("wait_timer", {}).fetch("wait_timer", 0),
						prevent_self_review: reviews.fetch("prevent_self_review", false),
						can_admins_bypass: environment.fetch("can_admins_bypass"),
						deployment_branch_policy: environment.fetch("deployment_branch_policy"),
						reviewers: reviews.fetch("reviewers", []).map{|entry| {type: entry.fetch("type"), id: entry.fetch("reviewer").fetch("id")}},
					}
					reviewers = @config.fetch("reviewers").map{|name| resolve_reviewer(name)}
					
					return {name: @config.fetch("environment"), current: current, desired: current.merge(reviewers: reviewers)}
				end
				
				def resolve_reviewer(name)
					if name.include?("/")
						organization, team = name.split("/", 2)
						raise "Reviewer team must belong to #{@repository.split('/').first}." unless organization.casecmp?(@repository.split("/").first)
						path = "orgs/#{organization}/teams/#{team}"
						type = "Team"
					else
						path = "users/#{name}"
						type = "User"
					end
					response = JSON.parse(readlines("gh", "api", path, chdir: @root).join)
					
					return {type: type, id: response.fetch("id")}
				end
				
				def write_api(path, payload, method:)
					return Tempfile.create("release-settings") do |file|
						file.write(JSON.generate(payload))
						file.flush
						system("gh", "api", path, "--method", method, "--input", file.path, chdir: @root)
					end
				end
				
				# Find the repository's sole release PR, excluding forks.
				def find_release_pull_request(branch)
					response = readlines(
						"gh", "pr", "list", "--repo", @repository, "--base", branch,
						"--state", "open", "--json", "headRefName,url,isCrossRepository",
						"--limit", "1000", chdir: @root,
					)
					pull_requests = JSON.parse(response.join).select do |pull_request|
						!pull_request["isCrossRepository"] && pull_request.fetch("headRefName").start_with?("releases/v")
					end
					raise "Multiple release PRs are open; select one before preparing another release." if pull_requests.size > 1
					
					return pull_requests.first
				end
				
				# Fetch the remote branch and return the commit used for the push lease.
				def fetch_release_branch(reference)
					remote = readlines("git", "ls-remote", "--heads", "origin", reference, chdir: @root)
					return nil if remote.empty?
					
					system("git", "fetch", "origin", reference, chdir: @root)
					
					return @release.resolve("FETCH_HEAD")
				end
				
				# Locate preparation which stopped before pushing its branch.
				def local_release_commit(branch)
					return nil if readlines("git", "branch", "--list", branch, chdir: @root).empty?
					
					return @release.resolve("refs/heads/#{branch}")
				end
				
				# Preserve the previous release before regenerating it from the current base.
				def refresh_release(candidate, base:, bump:, version:)
					backup_ref = "refs/heads/release-backups/v#{version}/#{candidate}"
					push("#{candidate}:#{backup_ref}")
					
					return @release.worktree(base) do |path|
						@release.bake(path, "gem:release:version:#{bump}")
						readlines("git", "rev-parse", "HEAD", chdir: path).join.strip
					end
				end
				
				# Open a PR for the already validated and pushed release branch.
				def create_release_pull_request(name, version, branch:, release_branch:, base:)
					body = <<~BODY
						Release #{name} #{version}.

						Prepared from #{base}. The complete release tree is regenerated during validation. \
						Merging publishes the resulting commit through release-publish.yaml after native \
						reviews and required CI (or explicit administrator bypass).
					BODY
					
					return Tempfile.create("release-pr") do |file|
						file.write(body)
						file.flush
						
						readlines(
							"gh", "pr", "create", "--repo", @repository, "--base", branch,
							"--head", release_branch, "--title", "Release v#{version}",
							"--body-file", file.path, chdir: @root,
						).join.strip
					end
				end
				
				def push(*arguments)
					system("git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential", "push", "origin", *arguments, chdir: @root)
				end
			end
		end
	end
end
