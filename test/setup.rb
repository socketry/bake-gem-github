# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require_relative "../lib/bake/gem/github/setup"
require "tmpdir"
require "bake/context"

describe Bake::Gem::GitHub::Setup do
	def around
		Dir.mktmpdir do |root|
			@root = root
			@setup = subject.new(root)
			yield
		end
	end
	
	def generate
		@setup.generate(repository: "socketry/example", checks: ["Ruby 3.4"], signing: false)
	end
	
	it "accepts the documented setup command and discovers all workflow tasks" do
		registry = Bake::Registry::Aggregate.new
		registry.append_path(File.expand_path("..", __dir__))
		context = Bake::Context.new(registry, @root)
		context.call("gem:github:setup", "repository=socketry/example", "branch=main", "checks=Tests,RuboCop", "signing=false", "approvals=2")
		config = YAML.safe_load_file(File.join(@root, "config/release.yaml"))
		expect(config.fetch("signing")).to be == false
		expect(config.fetch("approvals")).to be == 2
		%w[resolve build publish resume patch minor major].each do |name|
			expect(context.lookup("gem:github:release:#{name}")).not.to be_nil
		end
	end
	
	it "generates three parseable workflows and idempotent native policy" do
		paths = generate
		expect(generate).to be == paths
		expect(paths.grep(/workflows/).size).to be == 3
		paths.grep(/workflows/).each do |path|
			workflow = YAML.safe_load_file(File.join(@root, path))
			expect(workflow).to have_keys("jobs", "permissions")
		end
		checks = JSON.parse(File.read(File.join(@root, ".github/release-rules/checks.json")))
		expect(checks.dig("rules", 0, "parameters", "strict_required_status_checks_policy")).to be == true
		expect(checks.dig("bypass_actors", 0, "bypass_mode")).to be == "pull_request"
	end
	
	it "keeps unmerged validation read-only and retains artifacts before credentials" do
		generate
		validation = File.read(File.join(@root, ".github/workflows/release-validate.yaml"))
		expect(validation).not.to be(:include?, "secrets.")
		expect(validation).not.to be(:include?, "id-token")
		expect(validation).not.to be(:include?, "pull_request_target")
		publish = File.read(File.join(@root, ".github/workflows/release-publish.yaml"))
		expect(publish).to be(:include?, "github.event.pull_request.merged == true")
		expect(publish.index("actions/upload-artifact@")).to be < publish.index("rubygems/configure-rubygems-credentials@")
		expect(publish).not.to be(:include?, "GEM_SIGNING_KEY")
	end
	
	it "refuses to overwrite manually changed workflows" do
		generate
		path = File.join(@root, ".github/workflows/release-validate.yaml")
		File.write(path, "Custom workflow\n")
		expect{generate}.to raise_exception(RuntimeError, message: be =~ /Existing files differ/)
		expect(File.read(path)).to be == "Custom workflow\n"
	end
end
