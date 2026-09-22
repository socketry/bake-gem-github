# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

# Inspect external settings before applying the generated policy.
def plan
	context.lookup("gem:github:doctor").call
end

# Apply the four managed rulesets using the current gh administrator credentials.
def apply
	require_relative "../../../lib/bake/gem/github/project"
	
	return Bake::Gem::GitHub::Project.new(context.root).apply
end

# Update generated files in the working tree using config/release.yaml and the installed templates.
def update
	require_relative "../../../lib/bake/gem/github/setup"
	
	return Bake::Gem::GitHub::Setup.new(context.root).update
end
