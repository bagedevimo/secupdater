require "secupdater"
require "stringio"

RSpec.describe Secupdater::CLI::Commands::Run do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:runner) { instance_double(Secupdater::Runner, call: { "rack" => :published }) }
  let(:env) { {} }
  let(:git_head) { ["abc123\n", instance_double(Process::Status, success?: true)] }

  def run_cli(*arguments)
    Dry::CLI.new(Secupdater::CLI::Commands).call(arguments: ["run", *arguments], out: out, err: err)
  end

  def expect_exit(status, &block)
    expect(&block).to raise_error(SystemExit) { expect(it.status).to eq(status) }
  end

  before do
    stub_const("ENV", env)
    allow(Secupdater::Runner).to receive(:new).and_return(runner)
    allow(Open3).to receive(:capture2e).with("git", "rev-parse", "--verify", "HEAD").and_return(git_head)
  end

  describe "#call" do
    context "with --ecosystem rubygems and an advisories path" do
      it "builds a Runner for rubygems at log level :warn and calls it with the advisories path" do
        run_cli("--ecosystem=rubygems", "audit.json")

        expect(Secupdater::Runner).to have_received(:new).with(ecosystem: "rubygems", log_level: :warn, publisher: nil)
        expect(runner).to have_received(:call).with("audit.json")
      end
    end

    context "with --verbose" do
      it "builds the Runner with log level :info" do
        run_cli("--ecosystem=rubygems", "--verbose", "audit.json")

        expect(Secupdater::Runner).to have_received(:new).with(hash_including(log_level: :info))
      end
    end

    context "with --debug" do
      it "builds the Runner with log level :debug, even when --verbose is also given" do
        run_cli("--ecosystem=rubygems", "--verbose", "--debug", "audit.json")

        expect(Secupdater::Runner).to have_received(:new).with(hash_including(log_level: :debug))
      end
    end

    context "with SECUPDATER_GITLAB_TOKEN set" do
      let(:env) { { "SECUPDATER_GITLAB_TOKEN" => "token", "CI_PROJECT_ID" => "123", "CI_DEFAULT_BRANCH" => "main" } }

      it "publishes to GitLab using the CI project and default branch, starting from the checked out commit" do
        run_cli("--ecosystem=rubygems", "audit.json")

        expect(Secupdater::Runner).to have_received(:new).with(hash_including(
          publisher: an_instance_of(Secupdater::Publisher::Gitlab).and(
            have_attributes(access_token: "token", project_id: "123", target_branch: "main", start_sha: "abc123")
          )
        ))
      end

      context "outside a git checkout" do
        let(:git_head) { ["fatal: not a git repository\n", instance_double(Process::Status, success?: false)] }

        it "prints why and exits non-zero" do
          expect_exit(1) { run_cli("--ecosystem=rubygems", "audit.json") }

          expect(err.string).to include("Can't find the current git commit", "not a git repository")
          expect(Secupdater::Runner).not_to have_received(:new)
        end
      end
    end

    context "with SECUPDATER_GITLAB_TOKEN set but no CI_PROJECT_ID" do
      let(:env) { { "SECUPDATER_GITLAB_TOKEN" => "token", "CI_DEFAULT_BRANCH" => "main" } }

      it "prints which variable is missing and exits non-zero" do
        expect_exit(1) { run_cli("--ecosystem=rubygems", "audit.json") }

        expect(err.string).to eq("SECUPDATER_GITLAB_TOKEN is set but CI_PROJECT_ID isn't\n")
      end
    end

    context "with an unknown --ecosystem" do
      it "prints an error naming the bad option and exits non-zero" do
        expect_exit(1) { run_cli("--ecosystem=npm", "audit.json") }

        expect(err.string).to include("--ecosystem=npm")
        expect(Secupdater::Runner).not_to have_received(:new)
      end
    end

    context "without an advisories argument" do
      it "prints usage and exits non-zero" do
        expect_exit(1) { run_cli("--ecosystem=rubygems") }

        expect(err.string).to include("ADVISORIES")
        expect(Secupdater::Runner).not_to have_received(:new)
      end
    end

    context "when the advisories file doesn't exist" do
      before { allow(Secupdater::Runner).to receive(:new).and_call_original }

      it "prints 'Cannot open <path>' and exits non-zero, rather than an Errno::ENOENT backtrace" do
        expect_exit(1) { run_cli("--ecosystem=rubygems", "missing.json") }

        expect(err.string).to eq("Cannot open missing.json\n")
      end
    end

    context "when a dependency fails to update" do
      let(:runner) { instance_double(Secupdater::Runner, call: { "rack" => :failed, "nokogiri" => :published }) }

      it "exits non-zero" do
        expect_exit(1) { run_cli("--ecosystem=rubygems", "audit.json") }
      end
    end
  end
end
