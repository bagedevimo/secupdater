require "secupdater"
require "fileutils"
require "stringio"
require "tmpdir"

RSpec.describe "secupdater end to end" do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:env) { {} }

  def lockfile(css_parser_version)
    <<~LOCKFILE
      GEM
        remote: https://rubygems.org/
        specs:
          css_parser (#{css_parser_version})

      PLATFORMS
        ruby

      DEPENDENCIES
        css_parser

      BUNDLED WITH
         2.5.0
    LOCKFILE
  end

  let(:report) do
    {
      results: [
        {
          type: "unpatched_gem",
          gem: { name: "css_parser", version: "1.0.0" },
          advisory: { id: "CVE-2024-0001", cve: "2024-0001", patched_versions: [">= 1.1.0"] }
        }
      ]
    }
  end

  def run_cli(*arguments)
    Dry::CLI.new(Secupdater::CLI::Commands).call(arguments: ["run", "--ecosystem=rubygems", *arguments, "audit.json"], out: out, err: err)
  end

  around do |example|
    original_env = ENV.to_h

    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        File.write("Gemfile.lock", lockfile("1.0.0"))
        File.write("Gemfile.lock.after", lockfile("1.1.0"))
        File.write("audit.json", report.to_json)

        FileUtils.mkdir("bin")
        File.write("bin/bundle", "#!/bin/sh\ncp Gemfile.lock.after Gemfile.lock\n")
        File.chmod(0o755, "bin/bundle")

        ENV.delete("SECUPDATER_GITLAB_TOKEN")
        ENV.update(env.merge("PATH" => "#{dir}/bin:#{ENV['PATH']}"))
        example.run
      end
    end
  ensure
    ENV.replace(original_env)
  end

  context "fixture project + bundle-audit JSON + fake bundle command that swaps in an 'after' lockfile + WebMock'd GitLab" do
    let(:env) { { "SECUPDATER_GITLAB_TOKEN" => "token", "CI_PROJECT_ID" => "123", "CI_DEFAULT_BRANCH" => "main" } }

    let!(:find_mr_stub) do
      stub_request(:get, %r{\Ahttps://gitlab.com/api/v4/projects/123/merge_requests\?})
        .to_return(status: 200, body: "[]")
    end

    let!(:create_commit_stub) do
      stub_request(:post, "https://gitlab.com/api/v4/projects/123/repository/commits")
        .with(body: hash_including(
          branch: "security/css_parser-1.1.0",
          actions: [{ action: "update", file_path: "Gemfile.lock", content: lockfile("1.1.0") }]
        ))
        .to_return(status: 201, body: "{}")
    end

    let!(:create_mr_stub) do
      stub_request(:post, "https://gitlab.com/api/v4/projects/123/merge_requests")
        .with(body: hash_including(source_branch: "security/css_parser-1.1.0", target_branch: "main"))
        .to_return(status: 201, body: "{}")
    end

    it "exits 0, commits the new Gemfile.lock and opens one MR per vulnerable gem" do
      expect { run_cli }.not_to raise_error

      expect(find_mr_stub).to have_been_requested.once
      expect(create_commit_stub).to have_been_requested.once
      expect(create_mr_stub).to have_been_requested.once
      expect(File.read("Gemfile.lock")).to eq(lockfile("1.0.0"))
    end
  end

  context "same fixture project without GitLab configuration (dry run)" do
    it "exits 0, reports what would be updated and makes no HTTP requests" do
      expect { run_cli("--verbose") }.to output(/css_parser from 1\.0\.0 to 1\.1\.0 \(patch\) would resolve/).to_stdout

      expect(a_request(:any, //)).not_to have_been_made
      expect(File.read("Gemfile.lock")).to eq(lockfile("1.0.0"))
    end
  end

  context "real bundle update --local against fixture vendor/cache gems", :integration do
    it "bumps the gem in Gemfile.lock"
  end
end
