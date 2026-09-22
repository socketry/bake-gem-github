# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "sus/shared"
require "sus/fixtures/temporary_directory_context"
require "bake/gem/github/recovery_publisher"

module Bake
	module Gem
		module GitHub
			PublicationContext = Sus::Shared("a retained release") do
				include Sus::Fixtures::TemporaryDirectoryContext
				
				let(:publisher) {RecoveryPublisher.new(root)}
				let(:receipt) do
					{
						name: "example",
						version: "1.0.1",
						file: "example-1.0.1.gem",
						sha256: Digest::SHA256.hexdigest("Exact signed bytes"),
						commit: "a" * 40,
						repository: "socketry/example",
						pull_request: 42,
						pull_request_url: "https://github.com/socketry/example/pull/42",
					}
				end
				
				before do
					Setup.new(root).generate(repository: "socketry/example", checks: ["Test"], signing: false)
					
					FileUtils.mkdir_p(File.join(root, "pkg"))
					File.write(File.join(root, "pkg", receipt.fetch(:file)), "Exact signed bytes")
					File.write(File.join(root, "pkg", "#{receipt.fetch(:file)}.sigstore.json"), JSON.generate(mediaType: "test"))
					File.write(File.join(root, "pkg", "provenance.sigstore.json"), "{}")
					File.write(File.join(root, "pkg", "release.json"), JSON.generate(receipt))
				end
			end
		end
	end
end
