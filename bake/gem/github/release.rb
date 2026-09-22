# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/project"

# Prepare a patch release and open its PR.
# @parameter refresh [Boolean] Preserve and regenerate an existing release branch.
# @returns [String] The release PR URL.
def patch(refresh: false)
	Bake::Gem::GitHub::Project.new(context.root).prepare(context, "patch", refresh: refresh)
end

# Prepare a minor release and open its PR.
# @parameter refresh [Boolean] Preserve and regenerate an existing release branch.
# @returns [String] The release PR URL.
def minor(refresh: false)
	Bake::Gem::GitHub::Project.new(context.root).prepare(context, "minor", refresh: refresh)
end

# Prepare a major release and open its PR.
# @parameter refresh [Boolean] Preserve and regenerate an existing release branch.
# @returns [String] The release PR URL.
def major(refresh: false)
	Bake::Gem::GitHub::Project.new(context.root).prepare(context, "major", refresh: refresh)
end

# Resolve and validate a merged PR, emitting a commit output for the publishing job.
# @parameter number [String] The merged PR number; defaults to `RELEASE_PR`.
# @returns [Hash | Nil] Release metadata, or nil for an ordinary PR.
def resolve(number: ENV.fetch("RELEASE_PR"))
	result = Bake::Gem::GitHub::Project.new(context.root).inspect_release(number)
	
	if path = ENV["GITHUB_OUTPUT"]
		File.open(path, "a") do |file|
			file.puts "release=#{!result.nil?}"
			file.puts "commit=#{result.fetch(:commit)}" if result
		end
	end
	
	return result
end

# Build or restore the exact artifact for a merged release PR.
# @parameter number [String] The merged release PR number; defaults to `RELEASE_PR`.
# @returns [Hash] The built or restored release receipt.
def build(number: ENV.fetch("RELEASE_PR"))
	require "bake/gem/github/publisher"
	
	return Bake::Gem::GitHub::Publisher.new(context.root).build(number)
end

# Verify, upload and finalize a merged release using its retained artifact.
# @parameter number [String] The merged release PR number; defaults to `RELEASE_PR`.
# @returns [Hash] The published release receipt.
def publish(number: ENV.fetch("RELEASE_PR"))
	require "bake/gem/github/publisher"
	
	return Bake::Gem::GitHub::Publisher.new(context.root).publish(number)
end

# Rerun the original publishing workflow, preserving event identity and artifact bytes.
# @parameter run [String] The original release-publish workflow run ID.
# @returns [Boolean] True when GitHub accepts the rerun request.
def resume(run:)
	project = Bake::Gem::GitHub::Project.new(context.root)
	details = project.api("actions/runs/#{Integer(run)}")
	raise "Expected a release-publish workflow run." unless details.fetch("path") == ".github/workflows/release-publish.yaml"
	
	return project.system("gh", "run", "rerun", run.to_s, "--repo", project.config.fetch("repository"), chdir: context.root)
end
