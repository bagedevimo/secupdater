require "secupdater"
require "secupdater/publisher"
require "secupdater/publisher/gitlab"

RSpec.describe Secupdater::Publisher::Gitlab do
  subject(:gitlab) { described_class.new("access_token", "123", "main", "abc123") }

  let(:ecosystem) { Secupdater::Ecosystem::Rubygems.new }
  let(:dep) { Secupdater::DependencySpec.new("css_parser", "ruby", Gem::Version.new("1.0.0")) }
  let(:advisories) { [Secupdater::SecurityAdvisory.new("css_parser", "cve/2024-0001", [">= 1.1.0"])] }
  let(:bump) { Secupdater::DependencySpecDiff.new(dep, "1.0.0", "1.1.0") }
  let(:changes) { [Secupdater::FileChange.new("Gemfile.lock", "update", "abc", "xyz")] }

  let(:api) { "https://gitlab.com/api/v4" }
  let(:project_api) { "#{api}/projects/123" }
  let(:bot_email) { "group_1_bot_abc@noreply.gitlab.com" }

  let(:headers) do
    {
      "PRIVATE-TOKEN" => "access_token",
      content_type: "application/json"
    }
  end

  let(:existing_merge_requests) { [] }
  let(:branch_exists) { false }
  let(:branch_commits) { [{ author_name: "release-utilities", author_email: bot_email }] }
  let(:branch_lockfile) { "old" }

  let(:commit_body) do
    {
      branch: "security/css_parser-1.1.0",
      start_sha: "abc123",
      commit_message: "Upgrade RubyGems dependency css_parser to version 1.1.0",
      actions: [{ action: "update", file_path: "Gemfile.lock", content: "abc" }]
    }
  end

  let!(:find_mr_stub) do
    stub_request(:get, "#{project_api}/merge_requests")
      .with(query: { source_branch: "security/css_parser-1.1.0", target_branch: "main" }, headers: headers)
      .to_return(status: 200, body: existing_merge_requests.to_json)
  end

  let!(:find_branch_stub) do
    stub_request(:get, "#{project_api}/repository/branches/security%2Fcss_parser-1.1.0")
      .to_return(status: branch_exists ? 200 : 404, body: "{}")
  end

  let!(:compare_stub) do
    stub_request(:get, "#{project_api}/repository/compare")
      .with(query: { from: "main", to: "security/css_parser-1.1.0" })
      .to_return(status: 200, body: { commits: branch_commits }.to_json)
  end

  let!(:user_stub) do
    stub_request(:get, "#{api}/user")
      .to_return(status: 200, body: { email: bot_email, commit_email: bot_email, public_email: "" }.to_json)
  end

  let!(:branch_file_stub) do
    stub_request(:get, "#{project_api}/repository/files/Gemfile.lock/raw")
      .with(query: { ref: "security/css_parser-1.1.0" })
      .to_return(status: 200, body: branch_lockfile)
  end

  let!(:create_commit_stub) do
    stub_request(:post, "#{project_api}/repository/commits")
      .with(body: commit_body, headers: headers)
      .to_return(status: 201, body: "{}")
  end

  let!(:force_commit_stub) do
    stub_request(:post, "#{project_api}/repository/commits")
      .with(body: commit_body.merge(force: true), headers: headers)
      .to_return(status: 201, body: "{}")
  end

  let!(:create_mr_stub) do
    stub_request(:post, "#{project_api}/merge_requests")
      .with(body: {
        source_branch: "security/css_parser-1.1.0",
        target_branch: "main",
        remove_source_branch: true,
        labels: ["secupdater"],
        title: "Upgrade RubyGems dependency css_parser to version 1.1.0",
        description: "Upgrade RubyGems dependency css_parser to version 1.1.0 to address the following security advisories:\n\n* cve/2024-0001\n",
      }, headers: headers)
      .to_return(status: 201, body: "{}")
  end

  def publish = gitlab.call(ecosystem, bump, advisories, changes)

  describe "#call(ecosystem, bump, advisories, changes)" do
    context "no branch or MR yet" do
      it "creates the branch from start_sha and a labelled merge request" do
        expect(publish).to eq([:published, nil])

        expect(create_commit_stub).to have_been_requested
        expect(create_mr_stub).to have_been_requested
      end
    end

    context "deleting a file" do
      let(:changes) { [Secupdater::FileChange.new("Gemfile.lock", "delete", nil, "xyz")] }

      let!(:create_commit_stub) do
        stub_request(:post, "#{project_api}/repository/commits")
          .with(body: hash_including(actions: [{ action: "delete", file_path: "Gemfile.lock" }]))
          .to_return(status: 201, body: "{}")
      end

      it "doesn't send content for the action" do
        publish

        expect(create_commit_stub).to have_been_requested
      end
    end

    context "API returns 4xx" do
      let!(:create_commit_stub) do
        stub_request(:post, "#{project_api}/repository/commits")
          .to_return(status: 400, body: '{"message":"A branch called security/css_parser-1.1.0 already exists"}')
      end

      it "raises Secupdater::PublishFailed including the response body" do
        expect { publish }.to raise_error(Secupdater::PublishFailed, /400.*already exists/)

        expect(create_mr_stub).not_to have_been_requested
      end
    end

    context "a closed MR for this version" do
      let(:existing_merge_requests) { [{ iid: 7, state: "closed", labels: ["secupdater"] }] }
      let(:branch_exists) { true }

      it "treats the update as declined, without touching the branch" do
        expect(publish).to eq([:declined, "security/css_parser-1.1.0 was closed in !7, reopen it or remove its secupdater label to have it updated again"])

        expect(a_request(:post, //)).not_to have_been_made
      end

      context "whose branch has since been deleted" do
        let(:branch_exists) { false }

        it "still treats the update as declined" do
          expect(publish.first).to eq(:declined)

          expect(a_request(:post, //)).not_to have_been_made
        end
      end
    end

    context "a closed MR without the secupdater label (e.g. from before labels)" do
      let(:existing_merge_requests) { [{ iid: 7, state: "closed", labels: [] }] }

      it "doesn't count as declined, so opens a new MR" do
        expect(publish).to eq([:published, nil])

        expect(create_mr_stub).to have_been_requested
      end
    end

    context "a merged MR for this version" do
      let(:existing_merge_requests) { [{ iid: 7, state: "merged", labels: ["secupdater"] }] }

      it "doesn't open another" do
        expect(publish).to eq([:declined, "security/css_parser-1.1.0 was merged in !7, reopen it or remove its secupdater label to have it updated again"])

        expect(a_request(:post, //)).not_to have_been_made
      end
    end

    context "an open MR, labelled or not" do
      let(:existing_merge_requests) { [{ iid: 7, state: "opened", labels: [] }, { iid: 3, state: "closed", labels: ["secupdater"] }] }
      let(:branch_exists) { true }

      context "whose branch already has these changes" do
        let(:branch_lockfile) { "abc" }

        it "leaves it alone" do
          expect(publish).to eq([:up_to_date, nil])

          expect(a_request(:post, //)).not_to have_been_made
        end
      end

      context "whose branch is out of date" do
        it "replaces the branch's commit, from start_sha, without opening another MR" do
          expect(publish).to eq([:published, nil])

          expect(force_commit_stub).to have_been_requested
          expect(create_mr_stub).not_to have_been_requested
        end
      end

      context "whose branch has a commit from someone else" do
        let(:branch_commits) do
          [
            { author_name: "release-utilities", author_email: bot_email },
            { author_name: "Jo Bloggs", author_email: "jo@example.com" }
          ]
        end

        it "leaves the branch alone and says why" do
          expect(publish).to eq([:skipped, "security/css_parser-1.1.0 has commits from Jo Bloggs, so it won't be updated"])

          expect(a_request(:post, //)).not_to have_been_made
        end
      end

      context "whose branch has been deleted" do
        let(:branch_exists) { false }

        it "recreates the branch without opening another MR" do
          expect(publish).to eq([:published, nil])

          expect(create_commit_stub).to have_been_requested
          expect(create_mr_stub).not_to have_been_requested
        end
      end
    end

    context "a branch left without an MR (e.g. MR creation failed, or an MR from before labels)" do
      let(:branch_exists) { true }

      it "replaces the branch's commit and opens an MR" do
        expect(publish).to eq([:published, nil])

        expect(force_commit_stub).to have_been_requested
        expect(create_mr_stub).to have_been_requested
      end

      context "that already has these changes" do
        let(:branch_lockfile) { "abc" }

        it "opens an MR without committing" do
          expect(publish).to eq([:published, nil])

          expect(a_request(:post, "#{project_api}/repository/commits")).not_to have_been_made
          expect(create_mr_stub).to have_been_requested
        end
      end
    end
  end
end
