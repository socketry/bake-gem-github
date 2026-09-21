# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require_relative "../lib/bake/gem/github/publisher"

describe Bake::Gem::GitHub::Publisher do
	with "#verify_provenance" do
		let(:publisher) do
			instance = subject.allocate
			instance.instance_variable_set(:@root, "/release")
			instance.instance_variable_set(:@repository, "socketry/example")
			instance.instance_variable_set(:@config, {"branch" => "main"})
			instance
		end
		
		it "verifies both package and receipt with the exact publishing identity" do
			commands = []
			mock(publisher) do |wrapper|
				wrapper.replace(:system) do |*arguments, **options|
					commands << [arguments, options]
					true
				end
			end
			publisher.send(:verify_provenance, "/release/pkg/example.gem")
			
			options = [
				"--repo", "socketry/example", "--bundle", "/release/pkg/provenance.sigstore.json",
				"--cert-identity", "https://github.com/socketry/example/.github/workflows/release-publish.yaml@refs/heads/main",
				"--source-ref", "refs/heads/main", "--deny-self-hosted-runners"
			]
			expect(commands).to be == [
				[["gh", "attestation", "verify", "/release/pkg/example.gem", *options], {chdir: "/release"}],
				[["gh", "attestation", "verify", "/release/pkg/release.json", *options], {chdir: "/release"}]
			]
		end
	end
end
