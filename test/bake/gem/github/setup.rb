# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/setup"
require "sus/fixtures/temporary_directory_context"
require "bake/context"

describe Bake::Gem::GitHub::Setup do
	include Sus::Fixtures::TemporaryDirectoryContext
	
	let(:setup) {subject.new(root)}
	
	def generate
		setup.generate(repository: "socketry/example", checks: ["Ruby 3.4"], signing: false)
	end
	
	it "accepts the documented setup command and discovers all workflow tasks" do
		registry = Bake::Registry::Aggregate.new
		registry.append_path(::Gem.loaded_specs.fetch("bake-gem-github").full_gem_path)
		context = Bake::Context.new(registry, root)
		context.call("gem:github:setup", "repository=socketry/example", "branch=main", "checks=Tests,RuboCop", "signing=false", "approvals=2")
		config = YAML.safe_load_file(File.join(root, "config/release.yaml"))
		expect(config.fetch("signing")).to be == false
		expect(config.fetch("approvals")).to be == 2
		%w[resolve build publish resume patch minor major].each do |name|
			expect(context.lookup("gem:github:release:#{name}")).not.to be_nil
		end
	end
	
	it "generates three parseable workflows and idempotent native policy" do
		paths = generate
		expect(generate).to be == paths
		expect(File).not.to be(:exist?, File.join(root, ".github/releasing.md"))
		expect(paths.grep(/workflows/).size).to be == 3
		paths.grep(/workflows/).each do |path|
			workflow = YAML.safe_load_file(File.join(root, path))
			expect(workflow).to have_keys("jobs", "permissions")
		end
		checks = JSON.parse(File.read(File.join(root, ".github/release-rules/checks.json")))
		expect(checks.dig("rules", 0, "parameters", "strict_required_status_checks_policy")).to be == true
		expect(checks.dig("bypass_actors", 0, "bypass_mode")).to be == "pull_request"
	end
	
	it "keeps unmerged validation read-only and retains artifacts before credentials" do
		generate
		validation = File.read(File.join(root, ".github/workflows/release-validate.yaml"))
		expect(validation).not.to be(:include?, "secrets.")
		expect(validation).not.to be(:include?, "id-token")
		expect(validation).not.to be(:include?, "pull_request_target")
		publish = File.read(File.join(root, ".github/workflows/release-publish.yaml"))
		expect(publish).to be(:include?, "github.event.pull_request.merged == true")
		expect(publish.index("actions/upload-artifact@")).to be < publish.index("rubygems/configure-rubygems-credentials@")
		expect(publish).not.to be(:include?, "GEM_SIGNING_KEY")
	end
	
	it "refuses to overwrite manually changed workflows" do
		generate
		path = File.join(root, ".github/workflows/release-validate.yaml")
		File.write(path, "Custom workflow\n")
		expect{generate}.to raise_exception(RuntimeError, message: be =~ /Existing files differ/)
		expect(File.read(path)).to be == "Custom workflow\n"
	end
	
	it "permits a fork checkout only after merged release inspection" do
		generate
		workflow = YAML.safe_load_file(File.join(root, ".github/workflows/release-publish.yaml"))
		inspect = workflow.fetch("jobs").fetch("inspect")
		expect(inspect.fetch("if")).to be == "github.event.pull_request.merged == true"
		expect(inspect.fetch("steps").first.fetch("with")).not.to have_keys("allow-unsafe-pr-checkout", "ref")
		expect(inspect.fetch("steps").last.fetch("run")).to be == "bundle exec bake gem:github:release:resolve"
		publish = workflow.fetch("jobs").fetch("publish")
		expect(publish.fetch("needs")).to be == "inspect"
		expect(publish.fetch("if")).to be == "needs.inspect.outputs.release == 'true'"
		checkout = publish.fetch("steps").first.fetch("with")
		expect(checkout.fetch("ref")).to be == "${{ needs.inspect.outputs.commit }}"
		expect(checkout.fetch("allow-unsafe-pr-checkout")).to be == true
		%w[prepare validate].each do |name|
			workflow = File.read(File.join(root, ".github/workflows/release-#{name}.yaml"))
			expect(workflow).not.to be(:include?, "allow-unsafe-pr-checkout")
		end
	end
	
	it "attests both the gem and its source receipt with native provenance" do
		generate
		workflow = YAML.safe_load_file(File.join(root, ".github/workflows/release-publish.yaml"))
		attest = workflow.fetch("jobs").fetch("publish").fetch("steps").find{|step| step["id"] == "attest"}
		expect(attest.fetch("with")).to be == {"subject-path" => "${{ steps.build.outputs.package }}\npkg/release.json\n"}
	end
end
