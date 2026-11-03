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

  let(:target_diffs_since_branch) { [] }

  let!(:target_moved_on_stub) do
    stub_request(:get, "#{project_api}/repository/compare")
      .with(query: { from: "security/css_parser-1.1.0", to: "abc123" })
      .to_return(status: 200, body: { commits: [], diffs: target_diffs_since_branch }.to_json)
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
      .to_return(status: 201, body: { iid: 9 }.to_json)
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

        context "but main has changed other files since the branch was cut" do
          let(:target_diffs_since_branch) { [{ old_path: "app/models/user.rb", new_path: "app/models/user.rb" }] }

          it "leaves it alone" do
            expect(publish).to eq([:up_to_date, nil])

            expect(a_request(:post, //)).not_to have_been_made
          end
        end

        context "but main's Gemfile.lock has changed since the branch was cut (e.g. another MR made some of the same bumps)" do
          let(:target_diffs_since_branch) { [{ old_path: "Gemfile.lock", new_path: "Gemfile.lock" }] }

          it "replaces the branch's commit, from start_sha, so it doesn't show changes main already has" do
            expect(publish).to eq([:published, nil])

            expect(force_commit_stub).to have_been_requested
            expect(create_mr_stub).not_to have_been_requested
          end
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

  describe "#finish(vulnerable_names)" do
    let(:open_secupdater_merge_requests) { [] }

    let!(:find_open_stub) do
      stub_request(:get, "#{project_api}/merge_requests")
        .with(query: { state: "opened", labels: "secupdater", target_branch: "main", per_page: "100" }, headers: headers)
        .to_return(status: 200, body: open_secupdater_merge_requests.to_json)
    end

    let!(:note_stub) { stub_request(:post, %r{\A#{project_api}/merge_requests/\d+/notes\z}).to_return(status: 201, body: "{}") }
    let!(:close_stub) do
      stub_request(:put, %r{\A#{project_api}/merge_requests/\d+\z})
        .with(body: { state_event: "close" })
        .to_return(status: 200, body: "{}")
    end

    context "an older MR for a dependency this run opened a new MR for" do
      let(:open_secupdater_merge_requests) do
        [
          { iid: 5, source_branch: "security/css_parser-1.0.5" },
          { iid: 9, source_branch: "security/css_parser-1.1.0" }
        ]
      end

      before { publish }

      it "closes it, saying which MR superseded it" do
        expect(gitlab.finish(["css_parser"])).to eq(["closed !5 (security/css_parser-1.0.5): Superseded by !9."])

        expect(a_request(:post, "#{project_api}/merge_requests/5/notes").with(body: { body: "Superseded by !9." })).to have_been_made
        expect(a_request(:put, "#{project_api}/merge_requests/5")).to have_been_made
        expect(a_request(:put, //)).to have_been_made.once
      end
    end

    context "an MR for a dependency that no longer has advisories" do
      let(:open_secupdater_merge_requests) { [{ iid: 4, source_branch: "security/net-ssh-7.3.8" }] }

      it "closes it, saying it's no longer needed" do
        expect(gitlab.finish(["css_parser"])).to eq(
          ["closed !4 (security/net-ssh-7.3.8): net-ssh no longer has any security advisories on main, so this is no longer needed."]
        )

        expect(a_request(:put, "#{project_api}/merge_requests/4")).to have_been_made
        expect(a_request(:put, //)).to have_been_made.once
      end
    end

    context "an MR for a dependency that still has advisories, but that this run didn't publish" do
      let(:open_secupdater_merge_requests) { [{ iid: 4, source_branch: "security/net-ssh-7.3.8" }] }

      it "leaves it alone" do
        expect(gitlab.finish(["net-ssh"])).to eq([])

        expect(a_request(:put, //)).not_to have_been_made
        expect(a_request(:post, //)).not_to have_been_made
      end
    end

    context "the MR this run opened or kept" do
      let(:open_secupdater_merge_requests) { [{ iid: 9, source_branch: "security/css_parser-1.1.0" }] }

      before { publish }

      it "leaves it alone" do
        expect(gitlab.finish(["css_parser"])).to eq([])

        expect(a_request(:put, //)).not_to have_been_made
      end
    end
  end
end
