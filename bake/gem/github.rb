# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

# Generate local release workflows, policy, and documentation for review.
# @parameter checks [Array(String)] Required CI check names, including matrix entries.
# @parameter repository [String] Canonical owner/repository.
# @parameter branch [String] Default branch name.
# @parameter approvals [Integer] Number of approving reviews.
# @parameter signing [Boolean] Require legacy certificate signing.
# @parameter ruby [String] Ruby version for release workflows.
def setup(checks:, repository: nil, branch: nil, approvals: 2, signing: nil, ruby: "3.4")
	require "bake/gem/github/setup"
	require "bake/gem/shell"
	
	helper = Object.new.extend(Bake::Gem::Shell)
	remote = if repository && branch
		{}
	else
		JSON.parse(helper.readlines("gh", "repo", "view", "--json", "nameWithOwner,defaultBranchRef", chdir: context.root).join)
	end
	
	options = {
		repository: repository || remote.fetch("nameWithOwner"),
		branch: branch || remote.fetch("defaultBranchRef").fetch("name"),
		checks: checks,
		approvals: approvals,
		ruby: ruby,
	}
	options[:signing] = signing unless signing.nil?
	
	return Bake::Gem::GitHub::Setup.new(context.root).generate(**options)
end

# Show the desired rules, existing rules, environments, and RubyGems bootstrap values.
def doctor
	require "bake/gem/github/project"
	
	return Bake::Gem::GitHub::Project.new(context.root).doctor
end
