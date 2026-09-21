# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require_relative "project"
require "digest"
require "net/http"
require "openssl"

module Bake
	module Gem
		module GitHub
			# Builds one artifact, preserves it before upload, and resumes without moving existing tags.
			class Publisher < Project
				# Build or restore this workflow run's artifact, after validating the actual merged commit.
				def build(number)
					guard_environment
					evidence = inspect_release(number) or raise "PR does not change the version."
					raise "Checkout must match the merged commit." unless @release.resolve("HEAD") == evidence.fetch(:commit)
					path = File.join(@root, "pkg")
					FileUtils.mkdir_p(path)
					artifact = "release-#{evidence.fetch(:commit)}"
					run = ENV.fetch("GITHUB_RUN_ID")
					artifacts = api("actions/runs/#{run}/artifacts?per_page=100").fetch("artifacts")
					if retained = artifacts.find{|entry| entry.fetch("name") == artifact}
						raise "Retained artifact expired; restore it from the GitHub release before retrying." if retained.fetch("expired")
						system("gh", "run", "download", run, "--repo", @repository, "--name", artifact, "--dir", path, chdir: @root)
						receipt = load_receipt
						[:name, :version, :commit, :repository, :pull_request].each do |key|
							raise "Retained artifact has different #{key}." unless receipt[key] == evidence[key]
						end
						return output(receipt, restored: true)
					end
					filename = "#{evidence.fetch(:name)}-#{evidence.fetch(:version)}.gem"
					if registry_digest(evidence.fetch(:name), evidence.fetch(:version))
						raise "Version is already published but this run has no retained artifact. Restore the original artifact; do not rebuild."
					end
					package = build_package(path)
					raise "Unexpected package filename." unless File.basename(package) == filename
					receipt = evidence.merge(file: filename, sha256: Digest::SHA256.file(package).hexdigest, run_id: run, signing: @config.fetch("signing"))
					File.write(File.join(path, "release.json"), JSON.pretty_generate(receipt) + "\n")
					output(receipt, restored: false)
				end
				
				# Verify both attestations, upload exactly those bytes, then create only the intended tag and release.
				def publish(number)
					guard_environment
					receipt = load_receipt
					pr = merged(number)
					raise "Artifact is not for this merged PR." unless receipt[:commit] == pr.fetch("merge_commit_sha") && receipt[:pull_request] == pr.fetch("number") && receipt[:repository] == @repository
					raise "Checkout must match the artifact source." unless @release.resolve("HEAD") == receipt[:commit]
					metadata = @release.validate(base: "#{receipt[:commit]}^1", candidate: receipt[:commit])
					[:name, :version, :commit].each do |key|
						raise "Artifact #{key} differs from the merged source." unless receipt[key] == metadata[key]
					end
					package = File.join(@root, "pkg", receipt.fetch(:file))
					verify_certificate(package) if @config.fetch("signing")
					bundle = "#{package}.sigstore.json"
					identity = "https://github.com/#{@repository}/.github/workflows/release-publish.yaml@refs/heads/#{@config.fetch('branch')}"
					gem_command("exec", "sigstore-cli:0.2.3", "verify", package, "--bundle", bundle, "--certificate-identity", identity, "--certificate-oidc-issuer", "https://token.actions.githubusercontent.com")
					verify_provenance(package)
					tag = "v#{receipt.fetch(:version)}"
					guard_tag(tag, receipt.fetch(:commit))
					remote_digest = registry_digest(receipt.fetch(:name), receipt.fetch(:version))
					if remote_digest
						raise "Published version has different bytes." unless remote_digest == receipt.fetch(:sha256)
					else
						gem_command("push", package, "--host", "https://rubygems.org", "--attestation", bundle)
					end
					# A failed read after upload is recoverable by rerunning the same workflow.
					raise "Registry artifact does not match; retry after registry propagation." unless registry_digest(receipt.fetch(:name), receipt.fetch(:version)) == receipt.fetch(:sha256)
					attestations = registry_get("https://rubygems.org/api/v1/attestations/#{receipt.fetch(:name)}-#{receipt.fetch(:version)}.json")
					raise "Registry attestation is missing." unless attestations
					registry_bundles = JSON.parse(attestations)
					local_bundle = JSON.parse(File.read(bundle))
					raise "Registry does not contain this artifact's Sigstore bundle." unless contains_bundle?(registry_bundles, local_bundle)
					unless readlines("git", "tag", "--list", tag, chdir: @root).any?
						system("git", "tag", tag, receipt.fetch(:commit), chdir: @root)
					end
					system("git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential", "push", "origin", "refs/tags/#{tag}", chdir: @root)
					releases = JSON.parse(readlines("gh", "release", "list", "--repo", @repository, "--limit", "1000", "--json", "tagName", chdir: @root).join)
					unless releases.any?{|entry| entry.fetch("tagName") == tag}
						Tempfile.create("release-notes") do |file|
							file.write("#{receipt.fetch(:pull_request_url)}\n\nSource: #{receipt.fetch(:commit)}\nSHA256: #{receipt.fetch(:sha256)}\n\nSee releases.md at the release tag for release notes.\n")
							file.flush
							system("gh", "release", "create", tag, "--repo", @repository, "--verify-tag", "--title", "#{receipt.fetch(:name)} #{tag}", "--notes-file", file.path, chdir: @root)
						end
					end
					# Existing immutable assets are checked before upload; never clobber them.
					assets = api("releases/tags/#{tag}").fetch("assets")
					[package, bundle, File.join(@root, "pkg", "release.json"), File.join(@root, "pkg", "provenance.sigstore.json")].each do |file|
						if existing = assets.find{|asset| asset.fetch("name") == File.basename(file)}
							digest = existing.fetch("digest")
							raise "Existing release asset differs: #{file}" unless digest == "sha256:#{Digest::SHA256.file(file).hexdigest}"
						else
							system("gh", "release", "upload", tag, file, "--repo", @repository, chdir: @root)
						end
					end
					receipt
				end
				
				# Load artifact evidence and verify the stored digest and filename.
				def load_receipt
					receipt = JSON.parse(File.read(File.join(@root, "pkg", "release.json")), symbolize_names: true)
					filename = receipt.fetch(:file)
					raise "Invalid artifact filename." unless filename == File.basename(filename) && filename.end_with?(".gem")
					raise "Artifact digest mismatch." unless Digest::SHA256.file(File.join(@root, "pkg", filename)).hexdigest == receipt.fetch(:sha256)
					receipt
				end
				
				# Refuse local or remote tag collisions before uploading a package.
				def guard_tag(tag, commit)
					local = readlines("git", "tag", "--list", tag, chdir: @root)
					raise "Release tag points to another commit." if local.any? && @release.resolve(tag) != commit
					remote = readlines("git", "ls-remote", "--tags", "origin", "refs/tags/#{tag}", "refs/tags/#{tag}^{}", chdir: @root).map{|line| line.split}
					peeled = remote.find{|sha, ref| ref.end_with?("^{}")} || remote.first
					raise "Remote release tag points to another commit." if peeled && peeled.first != commit
				end
				
				private
				
				def gem_command(*arguments)
					if defined?(::Bundler)
						::Bundler.with_unbundled_env{system("gem", *arguments, chdir: @root)}
					else
						system("gem", *arguments, chdir: @root)
					end
				end
				
				def guard_environment
					raise "Publishing requires the configured GitHub repository." unless ENV["GITHUB_REPOSITORY"] == @repository
					raise "Publishing requires the default branch workflow." unless ENV["GITHUB_REF"] == "refs/heads/#{@config.fetch('branch')}"
				end
				
				def contains_bundle?(value, bundle)
					return true if value == bundle
					case value
					when Hash then value.values.any?{|child| contains_bundle?(child, bundle)}
					when Array then value.any?{|child| contains_bundle?(child, bundle)}
					else false
					end
				end
				
				def verify_certificate(path)
					policy = ::Gem::Security::Policy.new("Release", only_trusted: false)
					package = ::Gem::Package.new(path, policy)
					package.verify
					signer = OpenSSL::X509::Certificate.new(package.spec.cert_chain.last)
					expected = OpenSSL::X509::Certificate.new(File.read(File.join(@root, "release.cert")))
					raise "Package signer differs from release.cert." unless signer.to_der == expected.to_der
				end
				
				def build_package(path)
					unless @config.fetch("signing")
						return @release.worktree("HEAD"){|source| @release.bake(source, "gem:build", root: path, signing_key: false)}
					end
					certificate = OpenSSL::X509::Certificate.new(File.read(File.join(@root, "release.cert")))
					key = OpenSSL::PKey.read(ENV.fetch("GEM_SIGNING_KEY"))
					raise "Signing key does not match release.cert." unless certificate.check_private_key(key)
					raise "Signing certificate is not currently valid." unless (certificate.not_before..certificate.not_after).cover?(Time.now)
					Tempfile.create("gem-signing-key") do |file|
						file.chmod(0600)
						file.write(ENV.fetch("GEM_SIGNING_KEY"))
						file.flush
						package = @release.worktree("HEAD"){|source| @release.bake(source, "gem:build", root: path, signing_key: file.path)}
						verify_certificate(package)
						package
					end
				end
				
				def output(receipt, restored:)
					if path = ENV["GITHUB_OUTPUT"]
						File.open(path, "a") do |file|
							file.puts "package=pkg/#{receipt.fetch(:file)}"
							file.puts "artifact=release-#{receipt.fetch(:commit)}"
							file.puts "restored=#{restored}"
						end
					end
					receipt
				end
				
				def verify_provenance(package)
					ref = "refs/heads/#{@config.fetch('branch')}"
					identity = "https://github.com/#{@repository}/.github/workflows/release-publish.yaml@#{ref}"
					# The signed receipt binds the package digest to the release commit, independently of the workflow revision.
					[package, File.join(@root, "pkg", "release.json")].each do |file|
						system("gh", "attestation", "verify", file, "--repo", @repository, "--bundle", File.join(@root, "pkg", "provenance.sigstore.json"), "--cert-identity", identity, "--source-ref", ref, "--deny-self-hosted-runners", chdir: @root)
					end
				end
				
				def registry_digest(name, version)
					# Missing downloads can return 403; use the version API to establish absence.
					return nil unless registry_get("https://rubygems.org/api/v2/rubygems/#{name}/versions/#{version}.json?platform=ruby")
					body = registry_get("https://rubygems.org/downloads/#{name}-#{version}.gem")
					raise "Published gem download is missing; retry after registry propagation." unless body
					Digest::SHA256.hexdigest(body)
				end
				
				def registry_get(url, redirects: 5)
					uri = URI(url)
					raise "Registry redirect requires HTTPS." unless uri.scheme == "https"
					response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60){|http| http.get(uri.request_uri)}
					return nil if response.is_a?(Net::HTTPNotFound)
					if response.is_a?(Net::HTTPRedirection)
						raise "Too many registry redirects." unless redirects > 0
						return registry_get(URI.join(url, response.fetch("location")).to_s, redirects: redirects - 1)
					end
					raise "Registry request failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess)
					response.body
				end
			end
		end
	end
end
