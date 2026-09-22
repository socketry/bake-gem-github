# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require_relative "project"
require_relative "backup"
require_relative "registry"
require "bake/releases"
require "digest"
require "openssl"

module Bake
	module Gem
		module GitHub
			# Builds one artifact, preserves it before upload, and resumes without moving existing tags.
			class Publisher < Project
				# Compatibility name for a registered package whose download is pending.
				RegistryPending = Registry::Pending
				
				# Load repository policy and the registry used to verify published artifacts.
				# @parameter root [String] The repository root containing `config/release.yaml`.
				# @parameter registry [Registry] The registry providing package digests and attestation verification.
				def initialize(root, registry: Registry.new)
					super(root)
					@registry = registry
				end
				
				# Build or restore this workflow run's artifact, after validating the actual merged commit.
				# @parameter number [String | Integer] The merged release PR number.
				# @returns [Hash] The release receipt. Extends {Project#inspect_release} metadata with `file`, `sha256`, `run_id`, and `signing`; writes the receipt to `pkg/release.json` and Actions outputs when configured.
				# @raises [RuntimeError] If the workflow identity, source, or retained artifact is invalid, or published bytes cannot be recovered.
				def build(number)
					guard_environment
					evidence = inspect_release(number) or raise "PR does not change the version."
					raise "Checkout must match the merged commit." unless @release.resolve("HEAD") == evidence.fetch(:commit)
					
					path = File.join(@root, "pkg")
					FileUtils.mkdir_p(path)
					
					artifact = "release-#{evidence.fetch(:commit)}"
					run = ENV.fetch("GITHUB_RUN_ID")
					artifacts = api("actions/runs/#{run}/artifacts?per_page=100").fetch("artifacts")
					retained = artifacts.find{|entry| entry.fetch("name") == artifact}
					
					if retained && !retained.fetch("expired")
						system("gh", "run", "download", run, "--repo", @repository, "--name", artifact, "--dir", path, chdir: @root)
					elsif release = github_release("v#{evidence.fetch(:version)}")
						restore_release(release, evidence, path)
					elsif retained
						raise "Retained artifact expired and no GitHub release is available. Restore the original files before retrying."
					else
						receipt = build_receipt(evidence, path, run)
						return output(receipt, restored: false)
					end
					
					receipt = restored_receipt(evidence)
					
					return output(receipt, restored: true)
				end
				
				# Verify both attestations, upload exactly those bytes, then create only the intended tag and release.
				# @parameter number [String | Integer] The merged release PR number.
				# @returns [Hash] The verified receipt after registry verification and GitHub finalization.
				# @raises [RuntimeError] If source, signatures, registry content, tags, or release assets conflict, or propagation times out.
				# @raises [Bake::Gem::CommandExecutionError] If a verification or publishing command fails; rerunning resumes from retained artifacts.
				def publish(number)
					guard_environment
					receipt = load_receipt
					verify_source(receipt, number)
					
					package = File.join(@root, "pkg", receipt.fetch(:file))
					bundle = "#{package}.sigstore.json"
					verify_artifact(package, bundle)
					
					tag = "v#{receipt.fetch(:version)}"
					guard_tag(tag, receipt.fetch(:commit))
					remote_digest = @registry.digest(receipt.fetch(:name), receipt.fetch(:version))
					if remote_digest
						raise "Published version has different bytes." unless remote_digest == receipt.fetch(:sha256)
					end
					
					# Preserve verified bytes independently of workflow attempts before uploading:
					release = preserve_release(receipt)
					unless remote_digest
						gem_command("push", package, "--host", "https://rubygems.org", "--attestation", bundle)
					end
					
					@registry.verify(receipt, bundle)
					finalize_release(release, tag, receipt.fetch(:commit))
					
					return receipt
				end
				
				# Load artifact evidence and verify the stored digest and filename.
				# @returns [Hash] The receipt with symbol keys, including the verified `file` and `sha256`.
				# @raises [RuntimeError] If the package filename is invalid or its bytes do not match the receipt.
				def load_receipt
					receipt = JSON.parse(File.read(File.join(@root, "pkg", "release.json")), symbolize_names: true)
					filename = receipt.fetch(:file)
					raise "Invalid artifact filename." unless filename == File.basename(filename) && filename.end_with?(".gem")
					raise "Artifact digest mismatch." unless Digest::SHA256.file(File.join(@root, "pkg", filename)).hexdigest == receipt.fetch(:sha256)
					
					return receipt
				end
				
				# Refuse local or remote tag collisions before uploading a package.
				# @parameter tag [String] The version tag to publish.
				# @parameter commit [String] The intended release commit.
				# @returns [Nil] If local and remote tags are absent or already identify the intended commit.
				# @raises [RuntimeError] If an existing tag identifies another commit.
				def guard_tag(tag, commit)
					local = readlines("git", "tag", "--list", tag, chdir: @root)
					raise "Release tag points to another commit." if local.any? && @release.resolve(tag) != commit
					
					remote = readlines("git", "ls-remote", "--tags", "origin", "refs/tags/#{tag}", "refs/tags/#{tag}^{}", chdir: @root).map{|line| line.split}
					peeled = remote.find{|sha, ref| ref.end_with?("^{}")} || remote.first
					raise "Remote release tag points to another commit." if peeled && peeled.first != commit
				end
				
				private
				
				# Restore original files from a complete archive or a legacy set of assets.
				def restore_release(release, evidence, path)
					guard_release(release, evidence.fetch(:commit))
					filename = "#{evidence.fetch(:name)}-#{evidence.fetch(:version)}.gem"
					files = release_files(file: filename)
					
					if backup = release.fetch("assets").find{|asset| asset.fetch("name") == "release.tar"}
						contents = read_backup(release, backup, files)
						
						# Check every local file before writing any restored content:
						contents.each do |name, content|
							file = File.join(path, name)
							raise "Existing artifact differs: #{name}" if File.exist?(file) && File.binread(file) != content
						end
						
						return contents.each do |name, content|
							File.binwrite(File.join(path, name), content)
						end
					else
						names = release.fetch("assets").map{|asset| asset.fetch("name")}
						unless files.all?{|file| names.include?(File.basename(file))}
							raise "Retained release is incomplete; restore the original files before retrying."
						end
						
						return system(
							"gh", "release", "download", release.fetch("tag_name"), "--repo", @repository,
							"--dir", path, *files.flat_map{|file| ["--pattern", File.basename(file)]}, chdir: @root,
						)
					end
				end
				
				# Build only an unpublished version and retain the source identity and package digest.
				def build_receipt(evidence, path, run)
					filename = "#{evidence.fetch(:name)}-#{evidence.fetch(:version)}.gem"
					if @registry.digest(evidence.fetch(:name), evidence.fetch(:version))
						raise "Version is already published but this run has no retained artifact. Restore the original artifact; do not rebuild."
					end
					
					package = build_package(path)
					raise "Unexpected package filename." unless File.basename(package) == filename
					
					receipt = evidence.merge(
						file: filename,
						sha256: Digest::SHA256.file(package).hexdigest,
						run_id: run,
						signing: @config.fetch("signing"),
					)
					File.write(File.join(path, "release.json"), JSON.pretty_generate(receipt) + "\n")
					
					return receipt
				end
				
				# Compare recovered evidence with the independently validated release source.
				def restored_receipt(evidence)
					receipt = load_receipt
					[:name, :version, :commit, :repository, :pull_request].each do |key|
						raise "Retained artifact has different #{key}." unless receipt[key] == evidence[key]
					end
					
					return receipt
				end
				
				# Bind the receipt to the actual merged PR and regenerated release content.
				def verify_source(receipt, number)
					pull_request = merged(number)
					unless receipt[:commit] == pull_request.fetch("merge_commit_sha") &&
						receipt[:pull_request] == pull_request.fetch("number") &&
						receipt[:repository] == @repository
						raise "Artifact is not for this merged PR."
					end
					raise "Checkout must match the artifact source." unless @release.resolve("HEAD") == receipt[:commit]
					
					metadata = @release.validate(base: "#{receipt[:commit]}^1", candidate: receipt[:commit])
					return [:name, :version, :commit].each do |key|
						raise "Artifact #{key} differs from the merged source." unless receipt[key] == metadata[key]
					end
				end
				
				# Verify the optional certificate signature and both attestation formats.
				def verify_artifact(package, bundle)
					verify_certificate(package) if @config.fetch("signing")
					
					identity = "https://github.com/#{@repository}/.github/workflows/release-publish.yaml@refs/heads/#{@config.fetch('branch')}"
					gem_command(
						"exec", "sigstore-cli:0.2.3", "verify", package, "--bundle", bundle,
						"--certificate-identity", identity,
						"--certificate-oidc-issuer", "https://token.actions.githubusercontent.com",
					)
					
					return verify_provenance(package)
				end
				
				# Publish the version tag and draft only after registry verification completes.
				def finalize_release(release, tag, commit)
					unless readlines("git", "tag", "--list", tag, chdir: @root).any?
						system("git", "tag", tag, commit, chdir: @root)
					end
					push("refs/tags/#{tag}")
					
					if release.fetch("draft")
						return system("gh", "release", "edit", tag, "--repo", @repository, "--draft=false", "--verify-tag", chdir: @root)
					end
				end
				
				# Create a draft using notes from the exact release checkout.
				def create_draft(receipt, tag)
					notes = Bake::Releases.notes(tag, path: File.join(@root, "releases.md"))
					metadata = "#{receipt.fetch(:pull_request_url)}\n\nSource: #{receipt.fetch(:commit)}\nSHA256: #{receipt.fetch(:sha256)}\n"
					
					return Tempfile.create("release") do |file|
						file.write(JSON.generate(
							tag_name: tag,
							draft: true,
							target_commitish: receipt.fetch(:commit),
							name: tag,
							body: [notes, metadata].compact.join("\n"),
						))
						file.flush
						
						# Use the creation response because the release list can remain stale:
						JSON.parse(readlines(
							"gh", "api", "repos/#{@repository}/releases", "--method", "POST",
							"--input", file.path, chdir: @root,
						).join)
					end
				end
				
				# Refuse to overwrite individual assets containing different bytes.
				def verify_assets(assets, files)
					files.each do |file|
						if existing = assets.find{|asset| asset.fetch("name") == File.basename(file)}
							unless existing.fetch("digest") == "sha256:#{Digest::SHA256.file(file).hexdigest}"
								raise "Existing release asset differs: #{file}"
							end
						end
					end
				end
				
				# Preserve the complete set before uploading individual assets.
				def preserve_backup(release, files)
					if asset = release.fetch("assets").find{|entry| entry.fetch("name") == "release.tar"}
						contents = read_backup(release, asset, files)
						unless files.all?{|file| contents.fetch(File.basename(file)) == File.binread(file)}
							raise "Existing release backup differs."
						end
					else
						backup_path = File.join(@root, "pkg/release.tar")
						Backup.write(backup_path, files)
						
						return system("gh", "release", "upload", release.fetch("tag_name"), backup_path, "--repo", @repository, chdir: @root)
					end
				end
				
				def github_release(tag)
					pages = JSON.parse(readlines("gh", "api", "--paginate", "--slurp", "repos/#{@repository}/releases?per_page=100", chdir: @root).join)
					matches = pages.flatten(1).select{|release| release.fetch("tag_name") == tag}
					raise "Multiple GitHub releases have the same tag." if matches.size > 1
					
					if release = matches.first
						return api("releases/#{release.fetch('id')}")
					end
					
					# Resolve pending tags directly when the REST list has not caught up:
					owner, name = @repository.split("/", 2)
					query = "query($owner: String!, $name: String!, $tag: String!) { repository(owner: $owner, name: $name) { release(tagName: $tag) { databaseId } } }"
					result = JSON.parse(readlines(
						"gh", "api", "graphql", "-f", "query=#{query}", "-f", "owner=#{owner}", "-f",
						"name=#{name}", "-f", "tag=#{tag}", chdir: @root,
					).join)
					if release = result.fetch("data").fetch("repository").fetch("release")
						return api("releases/#{release.fetch('databaseId')}")
					end
				end
				
				def guard_release(release, commit)
					if release.fetch("draft") && release.fetch("target_commitish") != commit
						raise "Draft release targets another commit."
					end
				end
				
				def release_files(receipt)
					[receipt.fetch(:file), "#{receipt.fetch(:file)}.sigstore.json", "release.json", "provenance.sigstore.json"].map{|name| File.join(@root, "pkg", name)}
				end
				
				def preserve_release(receipt)
					tag = "v#{receipt.fetch(:version)}"
					release = github_release(tag) || create_draft(receipt, tag)
					guard_release(release, receipt.fetch(:commit))
					
					assets = release.fetch("assets")
					files = release_files(receipt)
					verify_assets(assets, files)
					preserve_backup(release, files)
					
					files.each do |file|
						unless assets.any?{|asset| asset.fetch("name") == File.basename(file)}
							system("gh", "release", "upload", tag, file, "--repo", @repository, chdir: @root)
						end
					end
					
					return release
				end
				
				def read_backup(release, asset, files)
					Tempfile.create("release-backup") do |file|
						system(
							"gh", "release", "download", release.fetch("tag_name"), "--repo", @repository,
							"--pattern", "release.tar", "--output", file.path, "--clobber", chdir: @root,
						)
						raise "Release backup digest mismatch." unless asset.fetch("digest") == "sha256:#{Digest::SHA256.file(file.path).hexdigest}"
						Backup.read(file.path, files.map{|path| File.basename(path)})
					end
				end
				
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
					
					return Tempfile.create("gem-signing-key") do |file|
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
					
					return receipt
				end
				
				def verify_provenance(package)
					ref = "refs/heads/#{@config.fetch('branch')}"
					identity = "https://github.com/#{@repository}/.github/workflows/release-publish.yaml@#{ref}"
					
					# The signed receipt binds the package digest to the release commit, independently of the workflow revision:
					return [package, File.join(@root, "pkg", "release.json")].each do |file|
						system(
							"gh", "attestation", "verify", file, "--repo", @repository, "--bundle",
							File.join(@root, "pkg", "provenance.sigstore.json"), "--cert-identity", identity,
							"--source-ref", ref, "--deny-self-hosted-runners", chdir: @root,
						)
					end
				end
			end
		end
	end
end
