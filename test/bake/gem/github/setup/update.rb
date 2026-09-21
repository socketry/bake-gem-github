# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/setup"
require "bake/context"
require "sus/fixtures/temporary_directory_context"

describe Bake::Gem::GitHub::Setup do
	include Sus::Fixtures::TemporaryDirectoryContext
	
	let(:setup) {subject.new(root)}
	
	before do
		setup.generate(repository: "socketry/example", checks: ["Tests"], signing: false)
	end
	
	it "proposes configuration changes and customizations without overwriting them" do
		path = File.join(root, "config/release.yaml")
		config = YAML.safe_load_file(path)
		config["approvals"] = 3
		config["checks"] << "New check"
		File.write(path, YAML.dump(config))
		workflow = File.join(root, ".github/workflows/release-validate.yaml")
		File.write(workflow, "# Custom workflow\n" + File.read(workflow))
		before = Dir.glob("{config,.github}/**/*", File::FNM_DOTMATCH, base: root).select{|name| File.file?(File.join(root, name))}.to_h{|name| [name, File.read(File.join(root, name))]}
		registry = Bake::Registry::Aggregate.new
		registry.append_path(::Gem.loaded_specs.fetch("bake-gem-github").full_gem_path)
		patch = Bake::Context.new(registry, root).call("gem:github:setup:update")
		expect(File.read(patch)).to be(:include?, "-# Custom workflow")
		expect(File.read(patch)).to be(:include?, '+            "context": "New check"')
		before.each do |name, content|
			expect(File.read(File.join(root, name))).to be == content
		end
		expect(system("git", "apply", "--check", patch, chdir: root)).to be == true
		expect(system("git", "apply", patch, chdir: root)).to be == true
		expect(File.read(setup.update)).to be == ""
		expect(YAML.safe_load_file(path)).to be == config
	end
	
	it "restores missing generated files through the patch" do
		path = File.join(root, ".github/releasing.md")
		original = File.read(path)
		File.unlink(path)
		patch = setup.update
		expect(File.exist?(path)).to be == false
		expect(system("git", "apply", patch, chdir: root)).to be == true
		expect(File.read(path)).to be == original
		expect(File.read(setup.update)).to be == ""
	end
	
	it "refuses unsupported configuration schemas" do
		File.write(File.join(root, "config/release.yaml"), YAML.dump("schema" => 2))
		expect{setup.update}.to raise_exception(RuntimeError, message: be =~ /Unsupported release configuration/)
	end
end
