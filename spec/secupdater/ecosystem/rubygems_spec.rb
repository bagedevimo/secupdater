require "secupdater"
require "stringio"
require "tmpdir"

RSpec.describe Secupdater::Ecosystem::Rubygems do
  subject(:rubygems) { described_class.new }

  def lockfile(css_parser_version)
    <<~LOCKFILE
      GEM
        remote: https://rubygems.org/
        specs:
          addressable (2.8.0)
          css_parser (#{css_parser_version})
            addressable

      PLATFORMS
        ruby

      DEPENDENCIES
        css_parser

      BUNDLED WITH
         2.5.0
    LOCKFILE
  end

  def spec(name, version) = Secupdater::DependencySpec.new(name, "ruby", Gem::Version.new(version))

  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        File.write("Gemfile.lock", lockfile("1.0.0"))
        example.run
      end
    end
  end

  describe "#parse_advisories(io)" do
    context "bundle-audit JSON with unpatched_gem and insecure_source results" do
      let(:report) do
        {
          results: [
            {
              type: "unpatched_gem",
              gem: { name: "css_parser", version: "1.0.0" },
              advisory: { id: "CVE-2024-0001", cve: "2024-0001", osvdb: nil, ghsa: "abcd-efgh", patched_versions: [">= 1.1.0"] }
            },
            { type: "insecure_source", source: "http://rubygems.org/" }
          ]
        }
      end

      it "returns one advisory per unpatched gem with a joined cve/ghsa id and patched_versions" do
        expect(rubygems.parse_advisories(StringIO.new(report.to_json))).to eq([
          Secupdater::SecurityAdvisory.new("css_parser", "cve/2024-0001-ghsa/abcd-efgh", [">= 1.1.0"])
        ])
      end
    end

    context "an advisory with none of cve, osvdb or ghsa" do
      let(:report) do
        {
          results: [
            {
              type: "unpatched_gem",
              gem: { name: "css_parser", version: "1.0.0" },
              advisory: { id: "RUBYSEC-2024-1", cve: nil, osvdb: nil, ghsa: nil, patched_versions: [">= 1.1.0"] }
            }
          ]
        }
      end

      it "falls back to the advisory id" do
        expect(rubygems.parse_advisories(StringIO.new(report.to_json)).map(&:report_id)).to eq(["RUBYSEC-2024-1"])
      end
    end
  end

  describe "#snapshot" do
    context "fixture Gemfile.lock in root" do
      it "maps gem name to DependencySpec with version" do
        expect(rubygems.snapshot).to eq(
          "addressable" => spec("addressable", "2.8.0"),
          "css_parser" => spec("css_parser", "1.0.0")
        )
      end
    end
  end

  describe "#diff_snapshot" do
    context "one gem bumped, one added, one removed" do
      it "returns a diff for each with from/to" do
        before = { "css_parser" => spec("css_parser", "1.0.0"), "public_suffix" => spec("public_suffix", "4.0.0") }
        after = { "css_parser" => spec("css_parser", "1.1.0"), "addressable" => spec("addressable", "2.8.0") }

        expect(rubygems.diff_snapshot(before, after)).to contain_exactly(
          Secupdater::DependencySpecDiff.new(spec("css_parser", "1.0.0"), Gem::Version.new("1.0.0"), Gem::Version.new("1.1.0")),
          Secupdater::DependencySpecDiff.new(spec("public_suffix", "4.0.0"), Gem::Version.new("4.0.0"), nil),
          Secupdater::DependencySpecDiff.new(spec("addressable", "2.8.0"), nil, Gem::Version.new("2.8.0"))
        )
      end
    end

    context "unchanged gems" do
      it "leaves them out of the diff" do
        snapshot = { "css_parser" => spec("css_parser", "1.0.0") }

        expect(rubygems.diff_snapshot(snapshot, snapshot.dup)).to be_empty
      end
    end
  end

  describe "#satisfies_requirement?" do
    it "matches ~>, >= and a version that's too low" do
      expect(rubygems.satisfies_requirement?("1.1.5", "~> 1.1.4")).to be(true)
      expect(rubygems.satisfies_requirement?("1.2.0", "~> 1.1.4")).to be(false)
      expect(rubygems.satisfies_requirement?("2.0.0", ">= 1.1.0")).to be(true)
      expect(rubygems.satisfies_requirement?("1.0.0", ">= 1.1.0")).to be(false)
    end

    it "matches comma-separated requirements from bundle audit" do
      expect(rubygems.satisfies_requirement?("7.3.5", "~> 7.3, >= 7.3.5")).to be(true)
      expect(rubygems.satisfies_requirement?("7.3.4", "~> 7.3, >= 7.3.5")).to be(false)
      expect(rubygems.satisfies_requirement?("8.0.0", "~> 7.3, >= 7.3.5")).to be(false)
    end
  end

  describe "#try_update" do
    let(:status) { instance_double(Process::Status, success?: true, exitstatus: 0) }

    context "command succeeds" do
      before do
        allow(Open3).to receive(:capture2e) do
          File.write("Gemfile.lock", lockfile("1.1.0"))
          ["Bundle updated!", status]
        end
      end

      it "runs a strict, conservative, unfrozen bundle update at the given level" do
        rubygems.try_update("css_parser", level: :minor)

        expect(Open3).to have_received(:capture2e).with({ "BUNDLE_FROZEN" => "false" }, "bundle", "update", "css_parser", "--conservative", "--minor", "--strict")
      end

      it "returns the lockfile change with its new and original content" do
        expect(rubygems.try_update("css_parser", level: :patch)).to eq([
          Secupdater::FileChange.new("Gemfile.lock", "update", lockfile("1.1.0"), lockfile("1.0.0"))
        ])
      end
    end

    context "command succeeds without changing anything" do
      before { allow(Open3).to receive(:capture2e).and_return(["Bundle updated!", status]) }

      it "returns no file changes" do
        expect(rubygems.try_update("css_parser", level: :patch)).to eq([])
      end
    end

    context "gem name containing shell metacharacters" do
      before { allow(Open3).to receive(:capture2e).and_return(["", status]) }

      it "passes it as a single argument without going through a shell" do
        rubygems.try_update("css_parser; touch pwned", level: :patch)

        expect(Open3).to have_received(:capture2e).with({ "BUNDLE_FROZEN" => "false" }, "bundle", "update", "css_parser; touch pwned", "--conservative", "--patch", "--strict")
      end
    end

    context "command exits 1" do
      let(:status) { instance_double(Process::Status, success?: false, exitstatus: 1) }

      before { allow(Open3).to receive(:capture2e).and_return(["Could not find gem 'css_parser'", status]) }

      it "raises UpdateCommandFailed with the integer exit code and combined output" do
        expect { rubygems.try_update("css_parser", level: :patch) }.to raise_error(Secupdater::UpdateCommandFailed) do
          expect(it.exit_code).to eq(1)
          expect(it.output).to eq("Could not find gem 'css_parser'")
        end
      end
    end

    context "command exits 16 (frozen lockfile)" do
      let(:status) { instance_double(Process::Status, success?: false, exitstatus: 16) }

      before { allow(Open3).to receive(:capture2e).and_return(["frozen mode is set", status]) }

      it "raises Secupdater::Error rather than UpdateCommandFailed, so the run stops" do
        expect { rubygems.try_update("css_parser", level: :patch) }.to raise_error(Secupdater::Error) do
          expect(it).not_to be_a(Secupdater::UpdateCommandFailed)
          expect(it.message).to include("frozen mode is set")
        end
      end
    end
  end
end
