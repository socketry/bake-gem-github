# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

# Generate local release workflows, policy payloads, and configuration for review.
# @parameter checks [Array(String)] Required CI check names, including matrix entries.
# @parameter repository [String] Canonical owner/repository; discovered through GitHub when omitted.
# @parameter branch [String] Default branch name; discovered through GitHub when omitted.
# @parameter approvals [Integer] Number of approving reviews.
# @parameter reviewers [Array(String)] Publishing environment reviewers: user logins or organization/team names. Omit to leave environment settings unmanaged.
# @parameter signing [Boolean] Require certificate signing; when omitted, enable it if `release.cert` exists.
# @parameter ruby [String] Ruby version for release workflows.
# @returns [Array(String)] Generated paths relative to the repository root.
def setup(checks:, repository: nil, branch: nil, approvals: 2, reviewers: nil, signing: nil, ruby: "3.4")
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
		reviewers: reviewers,
		ruby: ruby,
	}
	options[:signing] = signing unless signing.nil?
	
	Bake::Gem::GitHub::Setup.new(context.root).generate(**options)
end

# Show the desired rules and environment reviewers, existing settings, and RubyGems bootstrap values.
# @returns [Hash] Desired and observed settings; RubyGems values describe the expected configuration.
def doctor
	require "bake/gem/github/project"
	
	Bake::Gem::GitHub::Project.new(context.root).doctor
end
