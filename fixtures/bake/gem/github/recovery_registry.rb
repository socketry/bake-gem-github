# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/registry"

module Bake
	module Gem
		module GitHub
			# Use the real propagation verifier against simulated published content.
			class RecoveryRegistry < Registry
				def initialize(publisher)
					@publisher = publisher
				end
				
				def digest(name, version)
					@publisher.remote_digest
				end
				
				private
				
				def get(url)
					JSON.generate([{bundle: {mediaType: "test"}}])
				end
			end
		end
	end
end
