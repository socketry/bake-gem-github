# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "console"
require "digest"
require "json"
require "net/http"

module Bake
	module Gem
		module GitHub
			# Reads RubyGems package bytes and verifies registry propagation of the release attestations.
			class Registry
				# A registered package is not yet available from the download service.
				class Pending < RuntimeError
				end
				
				# Configure the HTTP transport used for registry requests.
				# @parameter http [Interface(:start)] The transport providing Net::HTTP-compatible sessions.
				def initialize(http: Net::HTTP)
					@http = http
				end
				
				# Compute a published package's digest, distinguishing absence from propagation delays.
				# @parameter name [String] The gem name.
				# @parameter version [String] The stable gem version.
				# @returns [String | Nil] The SHA256 digest, or nil if the version is not registered.
				# @raises [Pending] If the version is registered but its download is absent.
				# @raises [RuntimeError] If a request fails or a redirect violates the HTTPS policy.
				def digest(name, version)
					# Missing downloads can return 403; use the version API to establish absence:
					return nil unless get("https://rubygems.org/api/v2/rubygems/#{name}/versions/#{version}.json?platform=ruby")
					
					body = get("https://rubygems.org/downloads/#{name}-#{version}.gem")
					raise Pending, "Published gem download is missing; retry after registry propagation." unless body
					
					return Digest::SHA256.hexdigest(body)
				end
				
				# Wait for the published bytes and attestation to match the retained release.
				# @parameter receipt [Hash] Symbol-keyed release evidence containing `name`, `version`, and `sha256`.
				# @parameter bundle [String] The local Sigstore bundle path.
				# @parameter attempts [Integer] The maximum number of verification attempts.
				# @parameter delay [Numeric] Seconds to wait between attempts.
				# @returns [Nil] When both the bytes and attestation match.
				# @raises [RuntimeError] If verification fails or registry propagation times out.
				def verify(receipt, bundle, attempts: 7, delay: 10)
					local_bundle = JSON.parse(File.read(bundle))
					attempts.times do |attempt|
						begin
							if remote_digest = digest(receipt.fetch(:name), receipt.fetch(:version))
								raise "Published version has different bytes." unless remote_digest == receipt.fetch(:sha256)
								if attestations = get("https://rubygems.org/api/v1/attestations/#{receipt.fetch(:name)}-#{receipt.fetch(:version)}.json")
									raise "Registry does not contain this artifact's Sigstore bundle." unless contains_bundle?(JSON.parse(attestations), local_bundle)
									return
								end
							end
						rescue Pending
							# The version API can become visible before the gem download.
						end
						
						if attempt < attempts - 1
							Console.info(self, "Waiting for RubyGems to serve the release.")
							sleep(delay)
						end
					end
					raise "Registry propagation did not complete; rerun this workflow to resume from the retained release."
				end
				
				private
				
				def get(url, redirects: 5)
					uri = URI(url)
					raise "Registry redirect requires HTTPS." unless uri.scheme == "https"
					
					response = @http.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60){|http| http.get(uri.request_uri)}
					return nil if response.is_a?(Net::HTTPNotFound)
					
					if response.is_a?(Net::HTTPRedirection)
						raise "Too many registry redirects." unless redirects > 0
						return get(URI.join(url, response.fetch("location")).to_s, redirects: redirects - 1)
					end
					raise "Registry request failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess)
					
					return response.body
				end
				
				def contains_bundle?(value, bundle)
					return true if value == bundle
					case value
					when Hash
						return value.values.any?{|child| contains_bundle?(child, bundle)}
					when Array
						return value.any?{|child| contains_bundle?(child, bundle)}
					else
						return false
					end
				end
			end
		end
	end
end
