# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

# Inspect external settings before applying the generated policy.
# @parameter publisher [Boolean] Authenticate to RubyGems and check the expected publisher registration.
# @parameter key [Symbol] An explicitly selected RubyGems API key name.
# @parameter otp [String] An optional RubyGems MFA code.
# @returns [Hash] Desired and observed settings for review.
def plan(publisher: false, key: nil, otp: nil)
	result = context.lookup("gem:github:doctor").call
	if publisher
		require "bake/gem/github/trusted_publisher"
		
		result[:trusted_publisher_status] = Bake::Gem::GitHub::TrustedPublisher.load(context.root, key: key, otp: otp).status
	end
	
	return result
end

# Register the configured release workflow as a trusted publisher for an existing gem on RubyGems.org.
# @parameter key [Symbol] An explicitly selected RubyGems API key name.
# @parameter otp [String] An optional RubyGems MFA code.
# @returns [Hash] Whether the publisher was created and its API record.
def publisher(key: nil, otp: nil)
	require "bake/gem/github/trusted_publisher"
	
	Bake::Gem::GitHub::TrustedPublisher.load(context.root, key: key, otp: otp).register
end

# Apply the four managed rulesets and configured environment reviewers using the current gh administrator credentials.
# @returns [Hash] The managed ruleset payloads after successful application.
def apply
	require "bake/gem/github/project"
	
	Bake::Gem::GitHub::Project.new(context.root).apply
end

# Update generated files in the working tree using config/release.yaml and the installed templates.
# @returns [Array(String)] Changed paths relative to the repository root.
def update
	require "bake/gem/github/setup"
	
	Bake::Gem::GitHub::Setup.new(context.root).update
end
