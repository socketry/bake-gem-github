# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "json"
require "rubygems/gemcutter_utilities"
require "rubygems/user_interaction"
require "uri"
require_relative "project"

module Bake
	module Gem
		module GitHub
			# Registers the reviewed release workflow with RubyGems.org using its owner API.
			class TrustedPublisher
				include ::Gem::UserInteraction
				include ::Gem::GemcutterUtilities
				
				# The RubyGems API scope for managing trusted publishers.
				SCOPE = :configure_trusted_publishers
				
				# The provider type accepted by the RubyGems trusted publisher API.
				TYPE = "OIDC::TrustedPublisher::GitHubAction"
				
				# Load the gem identity and reviewed publisher settings from the current project.
				# @parameter root [String] The repository root, which must also be the working directory.
				# @parameter options [Hash] Authentication options passed to {initialize}.
				# @returns [TrustedPublisher] The configured RubyGems client.
				def self.load(root, **options)
					project = Project.new(root)
					name = Helper.new(root).gemspec.name
					
					new(name, project.trusted_publisher, **options)
				end
				
				# Configure an existing gem's expected GitHub Actions publisher.
				# @parameter name [String] The gem name.
				# @parameter settings [Hash] Repository owner/name, workflow filename, and environment.
				# @parameter key [Symbol | Nil] An explicitly selected key in RubyGems credentials.
				# @parameter otp [String | Nil] An optional MFA code; RubyGems can prompt when required.
				def initialize(name, settings, key: nil, otp: nil)
					@path = "api/v1/gems/#{URI.encode_www_form_component(name)}/trusted_publishers"
					@settings = settings.transform_keys(&:to_s)
					@options = {key: key, otp: otp}
					@host = "https://rubygems.org"
					@api_key = nil
				end
				
				# @attribute [Hash] Options used by RubyGems authentication and MFA support.
				attr_reader :options
				
				# Read the matching publisher without changing publisher configuration.
				# @returns [Hash] Whether the publisher is configured and its existing API record, if any.
				# @raises [RuntimeError] If RubyGems cannot list the gem's publishers.
				def status
					sign_in(scope: SCOPE) unless api_key
					publishers = request(:get, expected: "200")
					raise "Invalid RubyGems trusted publishers response." unless publishers.is_a?(Array)
					publisher = publishers.find{|record| matching?(record)}
					
					return {configured: !publisher.nil?, publisher: publisher}
				end
				
				# Register a missing publisher, preserving all existing publisher registrations.
				# @returns [Hash] Whether registration was created and the matching API record.
				# @raises [RuntimeError] If RubyGems rejects registration or returns different settings.
				def register
					current = status
					return {created: false, publisher: current.fetch(:publisher)} if current.fetch(:configured)
					
					publisher = request(:post, expected: "201", payload: {trusted_publisher_type: TYPE, trusted_publisher: @settings})
					raise "RubyGems returned unexpected trusted publisher settings." unless matching?(publisher)
					
					return {created: true, publisher: publisher}
				end
				
				# Use the session key or an explicitly supplied credential, leaving the default push key alone.
				# @returns [String | Nil] The API key used for this session.
				def api_key
					@api_key || ENV["GEM_HOST_API_KEY"] || (options[:key] && verify_api_key(options[:key]))
				end
				
				# Keep newly issued credentials in memory rather than changing the user's credentials file.
				# @parameter host [String] The authenticated RubyGems host.
				# @parameter key [String] The newly issued API key.
				def set_api_key(host, key)
					@api_key = key
				end
				
				private
				
				def get_mfa_params(profile)
					super.merge(expires_at: (Time.now.utc + 900).strftime("%Y-%m-%d %H:%M:%S UTC"))
				end
				
				def matching?(record)
					return false unless record.fetch("trusted_publisher_type") == TYPE
					settings = record.fetch("trusted_publisher")
					
					# Generated publishing workflows run in the configured repository, not a reusable workflow repository:
					@settings.all?{|key, value| settings[key] == value} &&
						settings["workflow_repository_owner"].nil? && settings["workflow_repository_name"].nil?
				end
				
				def request(method, expected:, payload: nil)
					response = rubygems_api_request(method, @path, scope: SCOPE) do |request|
						request["Authorization"] = api_key
						request["Accept"] = "application/json"
						if payload
							request["Content-Type"] = "application/json"
							request.body = JSON.generate(payload)
						end
					end
					unless response.code == expected
						raise "RubyGems trusted publisher #{method.to_s.upcase} failed (HTTP #{response.code}): #{clean_text(response.body)}"
					end
					
					JSON.parse(response.body)
				end
			end
		end
	end
end
