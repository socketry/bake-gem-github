# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/project_client"
require "sus/fixtures/temporary_directory_context"

describe Bake::Gem::GitHub::Project do
	include Sus::Fixtures::TemporaryDirectoryContext
	
	let(:project) {Bake::Gem::GitHub::ProjectClient.new(root)}
	let(:environment) do
		{
			"can_admins_bypass" => true,
			"deployment_branch_policy" => {"protected_branches" => false, "custom_branch_policies" => true},
			"protection_rules" => [{"type" => "branch_policy"}],
		}
	end
	
	let(:saved_reviewers) {[{"type" => "Team", "reviewer" => {"id" => 123, "slug" => "managers"}}]}
	let(:saved_environment) do
		{
			"can_admins_bypass" => true,
			"deployment_branch_policy" => {"protected_branches" => false, "custom_branch_policies" => true},
			"protection_rules" => [
				{"type" => "branch_policy"},
				{"type" => "required_reviewers", "prevent_self_review" => false, "reviewers" => saved_reviewers},
			],
		}
	end
	
	before do
		Bake::Gem::GitHub::Setup.new(root).generate(repository: "socketry/example", checks: ["Tests"], reviewers: ["socketry/managers"])
		project.responses["repos/socketry/example/rulesets?per_page=100"] = []
		project.responses["repos/socketry/example/environments"] = {"environments" => [environment]}
		project.responses["repos/socketry/example/environments/rubygems"] = -> do
			project.writes.any?{|payload| payload.key?("reviewers")} ? saved_environment : environment
		end
		project.responses["orgs/socketry/teams/managers"] = {"id" => 123, "privacy" => "closed"}
	end
	
	with "#doctor" do
		it "previews the resolved team and preserves environment defaults without writing" do
			changes = project.doctor.fetch(:environment_changes)
			
			expect(changes.fetch(:name)).to be == "rubygems"
			expect(changes.fetch(:current).fetch(:reviewers)).to be == []
			expect(changes.fetch(:desired)).to be == {
				wait_timer: 0,
				prevent_self_review: false,
				can_admins_bypass: true,
				deployment_branch_policy: environment.fetch("deployment_branch_policy"),
				reviewers: [{type: "Team", id: 123}],
			}
			expect(project.writes).to be == []
		end
		
		it "resolves individual reviewers as well as teams" do
			project.config["reviewers"] << "ioquatix"
			project.responses["users/ioquatix"] = {"id" => 456}
			
			expect(project.doctor.dig(:environment_changes, :desired, :reviewers)).to be == [{type: "Team", id: 123}, {type: "User", id: 456}]
		end
	end
	
	with "#apply" do
		it "updates reviewers without weakening existing environment protections" do
			environment["can_admins_bypass"] = false
			saved_environment["can_admins_bypass"] = false
			saved_environment["protection_rules"] << {"type" => "wait_timer", "wait_timer" => 30}
			saved_environment["protection_rules"].find{|rule| rule["type"] == "required_reviewers"}["prevent_self_review"] = true
			environment["protection_rules"] += [
				{"type" => "wait_timer", "wait_timer" => 30},
				{"type" => "required_reviewers", "prevent_self_review" => true, "reviewers" => [{"type" => "User", "reviewer" => {"id" => 456}}]},
			]
			project.apply
			
			expect(project.writes.last).to be == {
				"wait_timer" => 30,
				"prevent_self_review" => true,
				"can_admins_bypass" => false,
				"deployment_branch_policy" => environment.fetch("deployment_branch_policy"),
				"reviewers" => [{"type" => "Team", "id" => 123}],
			}
			expect(project.requests.last).to be == ["gh", "api", "repos/socketry/example/environments/rubygems"]
			expect(project.writes.size).to be == 5
		end
		
		it "preserves an unrestricted branch policy and enabled administrator bypass" do
			environment["deployment_branch_policy"] = nil
			saved_environment["deployment_branch_policy"] = nil
			project.apply
			
			expect(project.writes.last).to have_keys("deployment_branch_policy" => be_nil, "can_admins_bypass" => be == true)
		end
		
		it "does not update an environment which already has the configured reviewers" do
			environment["protection_rules"] << {"type" => "required_reviewers", "prevent_self_review" => false, "reviewers" => [{"type" => "Team", "reviewer" => {"id" => 123}}]}
			project.apply
			
			expect(project.writes.size).to be == 4
			expect(project.writes.all?{|payload| payload.key?("rules")}).to be == true
		end
		
		it "accepts reordered reviewers and ignores duplicate configured identities" do
			project.config["reviewers"] = ["ioquatix", "socketry/managers", "ioquatix"]
			project.responses["users/ioquatix"] = {"id" => 456}
			saved_reviewers.unshift({"type" => "User", "reviewer" => {"id" => 456}})
			
			project.apply
			expect(project.writes.last.fetch("reviewers")).to be == [{"type" => "Team", "id" => 123}, {"type" => "User", "id" => 456}]
			
			project.apply
			expect(project.writes.count{|payload| payload.key?("reviewers")}).to be == 1
		end
		
		it "rejects a successful write which silently drops every reviewer" do
			saved_reviewers.clear
			
			expect{project.apply}.to raise_exception(RuntimeError, message: be =~ /did not retain.*rubygems.*gem:github:setup:plan/)
			expect(project.writes.last.fetch("reviewers")).to be == [{"type" => "Team", "id" => 123}]
		end
		
		it "rejects a successful write which drops one of the requested reviewers" do
			project.config["reviewers"] << "ioquatix"
			project.responses["users/ioquatix"] = {"id" => 456}
			
			expect{project.apply}.to raise_exception(RuntimeError, message: be =~ /did not retain/)
		end
		
		it "rejects an unexpected reviewer who could approve publication" do
			saved_reviewers << {"type" => "User", "reviewer" => {"id" => 456}}
			
			expect{project.apply}.to raise_exception(RuntimeError, message: be =~ /did not retain/)
		end
		
		it "distinguishes user and team reviewers with the same numeric ID" do
			saved_reviewers.first["type"] = "User"
			
			expect{project.apply}.to raise_exception(RuntimeError, message: be =~ /did not retain/)
		end
		
		it "rejects a successful write which removes the reviewer protection rule" do
			saved_environment["protection_rules"].reject!{|rule| rule["type"] == "required_reviewers"}
			
			expect{project.apply}.to raise_exception(RuntimeError, message: be =~ /did not retain/)
		end
		
		it "rejects a successful write which changes an existing protection" do
			environment["can_admins_bypass"] = false
			
			expect{project.apply}.to raise_exception(RuntimeError, message: be =~ /did not retain/)
			expect(project.writes.last.fetch("can_admins_bypass")).to be == false
		end
		
		it "propagates failure to read back the applied environment" do
			project.responses["repos/socketry/example/environments/rubygems"] = -> do
				raise "GitHub readback failed" unless project.writes.empty?
				environment
			end
			
			expect{project.apply}.to raise_exception(RuntimeError, message: be == "GitHub readback failed")
			expect(project.writes.size).to be == 5
		end
		
		it "leaves environment settings unmanaged when reviewers are omitted" do
			project.config.delete("reviewers")
			project.apply
			
			expect(project.requests.any?{|request| request.fetch(2).include?("environments")}).to be == false
			expect(project.writes.size).to be == 4
			expect(project.doctor.fetch(:environment_changes)).to be_nil
		end
		
		it "refuses invalid reviewers before making external requests" do
			project.config["reviewers"] = []
			
			expect{project.apply}.to raise_exception(ArgumentError, message: be =~ /one to six environment reviewers/)
			expect(project.requests).to be == []
			expect(project.writes).to be == []
		end
		
		it "refuses teams from another organization before writing" do
			project.config["reviewers"] = ["other/managers"]
			
			expect{project.apply}.to raise_exception(RuntimeError, message: be =~ /Reviewer team must belong to socketry/)
			expect(project.writes).to be == []
		end
		
		["repos/socketry/example/environments/rubygems", "orgs/socketry/teams/managers"].each do |path|
			it "stops before writing if an environment or reviewer cannot be read", unique: path do
				mock(project) do |mock|
					mock.wrap(:readlines) do |original, *arguments, **options|
						raise "GitHub request failed" if arguments.fetch(2) == path
						original.call(*arguments, **options)
					end
				end
				
				expect{project.apply}.to raise_exception(RuntimeError, message: be =~ /GitHub request failed/)
				expect(project.writes).to be == []
			end
		end
		
		it "escapes the configured environment name in API requests" do
			project.config["environment"] = "release / gems"
			project.responses["repos/socketry/example/environments/release%20%2F%20gems"] = project.responses.fetch("repos/socketry/example/environments/rubygems")
			project.apply
			
			expect(project.requests.last.fetch(2)).to be == "repos/socketry/example/environments/release%20%2F%20gems"
		end
	end
	
	[:doctor, :apply].each do |operation|
		with "##{operation}" do
			it "rejects secret reviewer teams before changing any settings" do
				project.responses["orgs/socketry/teams/managers"]["privacy"] = "secret"
				
				expect{project.public_send(operation)}.to raise_exception(RuntimeError, message: be =~ /socketry\/managers is Secret.*Visible/)
				expect(project.writes).to be == []
			end
		end
	end
end
