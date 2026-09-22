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
	
	before do
		Bake::Gem::GitHub::Setup.new(root).generate(repository: "socketry/example", checks: ["Tests"], reviewers: ["socketry/managers"])
		project.responses["repos/socketry/example/rulesets?per_page=100"] = []
		project.responses["repos/socketry/example/environments"] = {"environments" => [environment]}
		project.responses["repos/socketry/example/environments/rubygems"] = environment
		project.responses["orgs/socketry/teams/managers"] = {"id" => 123}
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
			expect(project.requests.last[0, 5]).to be == ["gh", "api", "repos/socketry/example/environments/rubygems", "--method", "PUT"]
			expect(project.writes.size).to be == 5
		end
		
		it "preserves an unrestricted branch policy and enabled administrator bypass" do
			environment["deployment_branch_policy"] = nil
			project.apply
			
			expect(project.writes.last).to have_keys("deployment_branch_policy" => be_nil, "can_admins_bypass" => be == true)
		end
		
		it "does not update an environment which already has the configured reviewers" do
			environment["protection_rules"] << {"type" => "required_reviewers", "prevent_self_review" => false, "reviewers" => [{"type" => "Team", "reviewer" => {"id" => 123}}]}
			project.apply
			
			expect(project.writes.size).to be == 4
			expect(project.writes.all?{|payload| payload.key?("rules")}).to be == true
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
			project.responses["repos/socketry/example/environments/release%20%2F%20gems"] = environment
			project.apply
			
			expect(project.requests.last.fetch(2)).to be == "repos/socketry/example/environments/release%20%2F%20gems"
		end
	end
end
