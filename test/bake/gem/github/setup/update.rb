# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/setup"
require "bake/gem/github/repository_context"

describe Bake::Gem::GitHub::Setup do
	include Bake::Gem::GitHub::RepositoryContext
	
	let(:setup) {subject.new(repository)}
	
	with "#update" do
		it "leaves generated updates in the working tree for selective review" do
			workflow = File.join(repository, ".github/workflows/release-validate.yaml")
			File.write(workflow, "# Custom workflow\n" + File.read(workflow))
			File.write(File.join(repository, ".github/workflows/custom.yaml"), "Custom workflow\n")
			git("add", "--all")
			git("commit", "--quiet", "-m", "Repository customizations")
			original = git("rev-parse", "HEAD")
			path = File.join(repository, "config/release.yaml")
			config = YAML.safe_load_file(path)
			config["approvals"] = 3
			config["reviewers"] = ["socketry/managers"]
			config["checks"] << "New check"
			File.write(path, YAML.dump(config))
			registry = Bake::Registry::Aggregate.new
			registry.append_path(::Gem.loaded_specs.fetch("bake-gem-github").full_gem_path)
			changed = Bake::Context.new(registry, repository).call("gem:github:setup:update")
			
			expect(changed.sort).to be == [".github/release-rules/checks.json", ".github/release-rules/reviews.json", ".github/workflows/release-validate.yaml"]
			diff = git("diff")
			
			expect(diff).to be(:include?, "-# Custom workflow")
			expect(diff).to be(:include?, '+            "context": "New check"')
			expect(git("rev-parse", "HEAD")).to be == original
			expect(git("diff", "--cached")).to be == ""
			expect(File.read(File.join(repository, ".github/workflows/custom.yaml"))).to be == "Custom workflow\n"
			expect(setup.update).to be == []
			expect(git("diff")).to be == diff
			expect(YAML.safe_load_file(path)).to be == config
		end
		
		it "restores missing generated files" do
			path = File.join(repository, ".github/workflows/release-validate.yaml")
			original = File.read(path)
			File.unlink(path)
			
			expect(setup.update).to be == [".github/workflows/release-validate.yaml"]
			expect(File.read(path)).to be == original
			expect(setup.update).to be == []
			expect(File).not.to be(:exist?, File.join(repository, ".github/releasing.md"))
		end
		
		it "refuses unsupported configuration schemas" do
			File.write(File.join(repository, "config/release.yaml"), YAML.dump("schema" => 2))
			
			expect{setup.update}.to raise_exception(RuntimeError, message: be =~ /Unsupported release configuration/)
		end
	end
end
