require "secupdater"
require "secupdater/publisher"
require "secupdater/publisher/gitlab"

RSpec.describe Secupdater::Publisher::Gitlab do
  subject(:gitlab) { described_class.new("access_token", "123", "main") }

  let(:ecosystem) { Secupdater::Ecosystem::Rubygems.new }
  let(:dep) { Secupdater::DependencySpec.new("css_parser", "ruby", Gem::Version.new("1.0.0")) }
  let(:advisories) { [Secupdater::SecurityAdvisory.new("css_parser", "cve/2024-0001", [">= 1.1.0"])] }
  let(:bump) { Secupdater::DependencySpecDiff.new(dep, "1.0.0", "1.1.0") }
  let(:changes) { [Secupdater::FileChange.new("Gemfile.lock", "update", "abc", "xyz")] }

  let(:headers) do
    {
      "PRIVATE-TOKEN" => "access_token",
      content_type: "application/json"
    }
  end

  let(:existing_merge_requests) { [] }

  let!(:find_mr_stub) do
    stub_request(:get, "https://gitlab.com/api/v4/projects/123/merge_requests")
      .with(query: { source_branch: "security/css_parser-1.1.0", state: "opened" }, headers: headers)
      .to_return(status: 200, body: existing_merge_requests.to_json)
  end

  let!(:create_commit_stub) do
    stub_request(:post, "https://gitlab.com/api/v4/projects/123/repository/commits")
      .with(
        body: {
          branch: "security/css_parser-1.1.0",
          start_branch: "main",
          commit_message: "Upgrade RubyGems dependency css_parser to version 1.1.0",
          actions: [{ action: "update", file_path: "Gemfile.lock", content: "abc" }]
        },
        headers: headers
      )
      .to_return(status: 201, body: "{}")
  end

  let!(:create_mr_stub) do
    stub_request(:post, "https://gitlab.com/api/v4/projects/123/merge_requests")
      .with(body: {
        source_branch: "security/css_parser-1.1.0",
        target_branch: "main",
        remove_source_branch: true,
        labels: [],
        title: "Upgrade RubyGems dependency css_parser to version 1.1.0",
        description: "Upgrade RubyGems dependency css_parser to version 1.1.0 to address the following security advisories:\n\n* cve/2024-0001\n",
      }, headers: headers)
      .to_return(status: 201, body: "{}")
  end

  describe "#call(ecosystem, bump, advisories, changes)" do
    it "creates a commit and a merge request" do
      gitlab.call(ecosystem, bump, advisories, changes)

      expect(create_commit_stub).to have_been_requested
      expect(create_mr_stub).to have_been_requested
    end

    context "deleting a file" do
      let(:changes) { [Secupdater::FileChange.new("Gemfile.lock", "delete", nil, "xyz")] }

      let!(:create_commit_stub) do
        stub_request(:post, "https://gitlab.com/api/v4/projects/123/repository/commits")
          .with(body: hash_including(actions: [{ action: "delete", file_path: "Gemfile.lock" }]))
          .to_return(status: 201, body: "{}")
      end

      it "doesn't send content for the action" do
        gitlab.call(ecosystem, bump, advisories, changes)

        expect(create_commit_stub).to have_been_requested
      end
    end

    context "API returns 4xx" do
      let!(:create_commit_stub) do
        stub_request(:post, "https://gitlab.com/api/v4/projects/123/repository/commits")
          .to_return(status: 400, body: '{"message":"A branch called security/css_parser-1.1.0 already exists"}')
      end

      it "raises Secupdater::PublishFailed including the response body" do
        expect { gitlab.call(ecosystem, bump, advisories, changes) }
          .to raise_error(Secupdater::PublishFailed, /400.*already exists/)

        expect(create_mr_stub).not_to have_been_requested
      end
    end

    context "an MR for the branch already exists" do
      let(:existing_merge_requests) { [{ iid: 1 }] }

      it "doesn't create another one" do
        gitlab.call(ecosystem, bump, advisories, changes)

        expect(find_mr_stub).to have_been_requested
        expect(create_commit_stub).not_to have_been_requested
        expect(create_mr_stub).not_to have_been_requested
      end
    end
  end
end
