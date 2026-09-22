# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/publication_context"

describe Bake::Gem::GitHub::Publisher do
	include Bake::Gem::GitHub::PublicationContext
	
	with "#publish" do
		it "verifies both package and receipt with the exact publishing identity" do
			commands = []
			mock(publisher) do |wrapper|
				wrapper.wrap(:system) do |original, *arguments, **options|
					commands << [arguments, options] if arguments[0, 3] == ["gh", "attestation", "verify"]
					original.call(*arguments, **options)
				end
			end
			publisher.publish(42)
			
			options = [
				"--repo", "socketry/example", "--bundle", File.join(root, "pkg/provenance.sigstore.json"),
				"--cert-identity", "https://github.com/socketry/example/.github/workflows/release-publish.yaml@refs/heads/main",
				"--source-ref", "refs/heads/main", "--deny-self-hosted-runners"
			]
			
			expect(commands).to be == [
				[["gh", "attestation", "verify", File.join(root, "pkg", receipt.fetch(:file)), *options], {chdir: root}],
				[["gh", "attestation", "verify", File.join(root, "pkg/release.json"), *options], {chdir: root}]
			]
		end
	end
end
