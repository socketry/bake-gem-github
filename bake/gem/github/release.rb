# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require_relative "../../../lib/bake/gem/github/publisher"

# Prepare a patch release and open its PR.
def patch
	Bake::Gem::GitHub::Project.new(context.root).prepare(context, "patch")
end

# Prepare a minor release and open its PR.
def minor
	Bake::Gem::GitHub::Project.new(context.root).prepare(context, "minor")
end

# Prepare a major release and open its PR.
def major
	Bake::Gem::GitHub::Project.new(context.root).prepare(context, "major")
end

# Resolve and validate a merged PR, emitting a commit output for the publishing job.
def resolve(number: ENV.fetch("RELEASE_PR"))
	result = Bake::Gem::GitHub::Project.new(context.root).inspect_release(number)
	if path = ENV["GITHUB_OUTPUT"]
		File.open(path, "a") do |file|
			file.puts "release=#{!result.nil?}"
			file.puts "commit=#{result.fetch(:commit)}" if result
		end
	end
	result
end

# Build or restore the exact artifact for a merged release PR.
def build(number: ENV.fetch("RELEASE_PR"))
	Bake::Gem::GitHub::Publisher.new(context.root).build(number)
end

# Verify, upload and finalize a merged release using its retained artifact.
def publish(number: ENV.fetch("RELEASE_PR"))
	Bake::Gem::GitHub::Publisher.new(context.root).publish(number)
end

# Rerun the original publishing workflow, preserving event identity and artifact bytes.
def resume(run:)
	project = Bake::Gem::GitHub::Project.new(context.root)
	details = project.api("actions/runs/#{Integer(run)}")
	raise "Expected a release-publish workflow run." unless details.fetch("path") == ".github/workflows/release-publish.yaml"
	project.system("gh", "run", "rerun", run.to_s, "--repo", project.config.fetch("repository"), chdir: context.root)
end
