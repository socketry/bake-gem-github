# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/project"
require "bake/context"

module Bake
	module Gem
		module GitHub
			# Substitute GitHub transport while retaining real Git and Bake operations.
			class ProjectClient < Project
				attr_accessor :pulls, :responses
				attr_reader :requests, :writes
				
				def initialize(root)
					super
					@pulls = []
					@responses = {}
					@requests = []
					@writes = []
				end
				
				def readlines(*arguments, **options)
					return super unless arguments.first == "gh"
					@requests << arguments
					case arguments[1, 2]
					when ["pr", "list"]
						[JSON.generate(@pulls)]
					when ["pr", "create"]
						@writes << File.read(arguments[arguments.index("--body-file") + 1])
						["https://github.com/socketry/example/pull/42\n"]
					else
						response = @responses.fetch(arguments.fetch(2))
						response = response.call if response.respond_to?(:call)
						[JSON.generate(response)]
					end
				end
				
				def system(*arguments, **options)
					return super unless arguments.first == "gh"
					@requests << arguments
					@writes << JSON.parse(File.read(arguments[arguments.index("--input") + 1]))
					true
				end
			end
		end
	end
end
