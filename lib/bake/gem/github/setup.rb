# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "erb"
require "yaml"
require "json"
require "fileutils"

module Bake
	module Gem
		module GitHub
			# Generates reviewable repository files without changing remote settings.
			class Setup
				# @parameter root [String] Destination repository.
				def initialize(root)
					@root = File.expand_path(root)
				end
				
				# Generate workflows, policy payloads, and configuration. Refuse conflicting existing files.
				# @parameter repository [String] The canonical GitHub owner and repository name.
				# @parameter branch [String] The default branch receiving release PRs.
				# @parameter checks [Array(String)] Required CI job names; release validation is added automatically.
				# @parameter approvals [Integer] Required approvals, between one and six.
				# @parameter reviewers [Array(String) | Nil] Publishing environment reviewers, as user logins or organization/team names. Nil leaves environment settings unmanaged.
				# @parameter signing [Boolean] Whether publishing requires the certificate and matching private key.
				# @parameter ruby [String] The Ruby version used by release workflows.
				# @returns [Array(String)] Generated paths relative to the repository root.
				# @raises [RuntimeError] If configuration is invalid or an existing generated file differs.
				def generate(repository:, branch: "main", checks:, approvals: 2, reviewers: nil, signing: File.file?(File.join(@root, "release.cert")), ruby: "3.4")
					raise "Expected owner/repository." unless repository.match?(/\A[\w.-]+\/[\w.-]+\z/)
					raise "Unsupported branch name." unless branch.match?(/\A[\w.\/-]+\z/)
					raise "Select the required CI check names." if checks.empty?
					raise "Review count must be between 1 and 6." unless (1..6).include?(approvals)
					
					config = {
						"schema" => 1,
						"repository" => repository,
						"branch" => branch,
						"checks" => (checks + ["Release validation"]).uniq,
						"approvals" => approvals,
						"signing" => signing,
						"ruby" => ruby,
						"environment" => "rubygems",
					}
					config["reviewers"] = reviewers unless reviewers.nil?
					
					files = render(config)
					conflicts = files.keys.select do |name|
						path = File.join(@root, name)
						File.exist?(path) && File.read(path) != files[name]
					end
					
					raise "Existing files differ; review them before regenerating: #{conflicts.join(', ')}" unless conflicts.empty?
					
					write(files)
					
					return files.keys
				end
				
				# Update generated files in the working tree using the existing configuration; return changed paths.
				# @returns [Array(String)] Changed paths relative to the repository root.
				# @raises [RuntimeError] If the configuration schema is unsupported.
				def update
					config = YAML.safe_load_file(File.join(@root, "config/release.yaml"))
					raise "Unsupported release configuration." unless config.fetch("schema") == 1
					
					return write(render(config))
				end
				
				# Native review/check rules allow PR-only administrator bypass; history rules have no bypass.
				# @parameter config [Hash] Release configuration with string keys: `branch`, `approvals`, and `checks`.
				# @returns [Hash] Ruleset payloads keyed by `reviews`, `checks`, `history`, and `tags`.
				def self.rules(config)
					conditions = {ref_name: {include: ["refs/heads/#{config.fetch('branch')}"], exclude: []}}
					common = {target: "branch", enforcement: "active", conditions: conditions}
					bypass = [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "pull_request"}]
					
					return {
						"reviews" => common.merge(
							name: "Gem release reviews",
							bypass_actors: bypass,
							rules: [{
								type: "pull_request",
								parameters: {
									required_approving_review_count: config.fetch("approvals"),
									dismiss_stale_reviews_on_push: true,
									require_last_push_approval: true,
									required_review_thread_resolution: true,
									require_code_owner_review: false,
									allowed_merge_methods: ["merge", "squash", "rebase"],
								},
							}],
						),
						"checks" => common.merge(
							name: "Gem release checks",
							bypass_actors: bypass,
							rules: [{
								type: "required_status_checks",
								parameters: {
									strict_required_status_checks_policy: true,
									do_not_enforce_on_create: false,
									required_status_checks: config.fetch("checks").map{|name| {context: name}},
								},
							}],
						),
						"history" => common.merge(
							name: "Gem release history",
							bypass_actors: [],
							rules: [{type: "deletion"}, {type: "non_fast_forward"}],
						),
						"tags" => {
							name: "Gem release tags",
							target: "tag",
							enforcement: "active",
							bypass_actors: [],
							conditions: {ref_name: {include: ["refs/tags/v*"], exclude: []}},
							rules: [{type: "deletion"}, {type: "non_fast_forward"}],
						},
					}
				end
				
				# Validate an explicit list of publishing environment reviewers.
				# @parameter reviewers [Array(String)] One to six user logins or organization/team names.
				# @raises [ArgumentError] If the list is empty, too long, or contains invalid names.
				def self.validate_reviewers(reviewers)
					unless reviewers.is_a?(Array) && (1..6).include?(reviewers.size) && reviewers.all?{|name| name.is_a?(String) && name.match?(/\A[\w-]+(?:\/[\w-]+)?\z/)}
						raise ArgumentError, "Specify one to six environment reviewers as user logins or organization/team names."
					end
				end
				
				private
				
				def write(files)
					files.filter_map do |name, content|
						path = File.join(@root, name)
						next if File.exist?(path) && File.read(path) == content
						
						FileUtils.mkdir_p(File.dirname(path))
						File.write(path, content)
						
						name
					end
				end
				
				def render(config)
					self.class.validate_reviewers(config["reviewers"]) if config.key?("reviewers")
					branch = config.fetch("branch")
					ruby = config.fetch("ruby")
					signing = config.fetch("signing")
					
					templates = File.expand_path("../../../../templates", __dir__)
					files = {"config/release.yaml" => YAML.dump(config)}
					Dir.glob("*.erb", base: templates).each do |name|
						files[".github/workflows/#{name.delete_suffix('.erb')}"] = ERB.new(File.read(File.join(templates, name)), trim_mode: "-").result(binding)
					end
					
					self.class.rules(config).each do |name, rule|
						files[".github/release-rules/#{name}.json"] = JSON.pretty_generate(rule) + "\n"
					end
					
					return files
				end
			end
		end
	end
end
