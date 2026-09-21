# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

# Regenerate documentation when preparing a release.
def after_gem_release_version_increment(version)
	context["utopia:project:agent:context:update"].call
end
