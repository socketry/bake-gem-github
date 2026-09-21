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
				
				# Generate workflows, policy payloads, and maintainer instructions. Refuse conflicting existing files.
				def generate(repository:, branch: "main", checks:, approvals: 2, signing: File.file?(File.join(@root, "release.cert")), ruby: "3.4")
					raise "Expected owner/repository." unless repository.match?(/\A[\w.-]+\/[\w.-]+\z/)
					raise "Unsupported branch name." unless branch.match?(/\A[\w.\/-]+\z/)
					raise "Select the required CI check names." if checks.empty?
					raise "Review count must be between 1 and 6." unless (1..6).include?(approvals)
					config = {"schema" => 1, "repository" => repository, "branch" => branch, "checks" => (checks + ["Release validation"]).uniq, "approvals" => approvals, "signing" => signing, "ruby" => ruby, "environment" => "rubygems"}
					templates = File.expand_path("../../../../templates", __dir__)
					files = {"config/release.yaml" => YAML.dump(config)}
					Dir.glob("*.erb", base: templates).each do |name|
						files[".github/workflows/#{name.delete_suffix('.erb')}"] = ERB.new(File.read(File.join(templates, name)), trim_mode: "-").result(binding)
					end
					self.class.rules(config).each do |name, rule|
						files[".github/release-rules/#{name}.json"] = JSON.pretty_generate(rule) + "\n"
					end
					files[".github/RELEASING.md"] = File.read(File.join(templates, "RELEASING.md"))
					conflicts = files.keys.select{|name| File.exist?(File.join(@root, name)) && File.read(File.join(@root, name)) != files[name]}
					raise "Existing files differ; review them before regenerating: #{conflicts.join(', ')}" unless conflicts.empty?
					files.each do |name, content|
						path = File.join(@root, name)
						FileUtils.mkdir_p(File.dirname(path))
						File.write(path, content) unless File.exist?(path)
					end
					files.keys
				end
				
				# Native review/check rules allow PR-only administrator bypass; history rules have no bypass.
				def self.rules(config)
					conditions = {ref_name: {include: ["refs/heads/#{config.fetch('branch')}"], exclude: []}}
					common = {target: "branch", enforcement: "active", conditions: conditions}
					bypass = [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "pull_request"}]
					{
						"reviews" => common.merge(name: "Gem release reviews", bypass_actors: bypass, rules: [{type: "pull_request", parameters: {required_approving_review_count: config.fetch("approvals"), dismiss_stale_reviews_on_push: true, require_last_push_approval: true, required_review_thread_resolution: true, require_code_owner_review: false, allowed_merge_methods: ["merge", "squash"]}}]),
						"checks" => common.merge(name: "Gem release checks", bypass_actors: bypass, rules: [{type: "required_status_checks", parameters: {strict_required_status_checks_policy: true, do_not_enforce_on_create: false, required_status_checks: config.fetch("checks").map{|name| {context: name}}}}]),
						"history" => common.merge(name: "Gem release history", bypass_actors: [], rules: [{type: "deletion"}, {type: "non_fast_forward"}]),
						"tags" => {name: "Gem release tags", target: "tag", enforcement: "active", bypass_actors: [], conditions: {ref_name: {include: ["refs/tags/v*"], exclude: []}}, rules: [{type: "deletion"}, {type: "non_fast_forward"}]}
					}
				end
			end
		end
	end
end
