require "secupdater"
require "secupdater/publisher"
require "json"
require "stringio"
require "tmpdir"

module UpdateSpec
  # outcomes: gem name => version try_update moves it to, :unchanged, :fail or :abort, or a hash of those by level
  class FakeEcosystem
    LOCKFILE = "Gemfile.lock"

    attr_reader :outcomes, :lockfiles_seen, :attempts

    def initialize(outcomes)
      @outcomes = outcomes
      @lockfiles_seen = {}
      @attempts = []
    end

    def update_levels = [:patch, :minor, :major]

    def ecosystem_name = "Fake"

    def snapshot
      JSON.parse(File.read(LOCKFILE)).to_h do |name, version|
        [name, Secupdater::DependencySpec.new(name, "ruby", Gem::Version.new(version))]
      end
    end

    def diff_snapshot(a, b) = Secupdater::Ecosystem::Rubygems.new.diff_snapshot(a, b)

    def try_update(name, level:)
      before = File.read(LOCKFILE)
      lockfiles_seen[[name, level]] = JSON.parse(before)
      attempts << [name, level]

      outcome = outcomes.fetch(name)
      outcome = outcome.fetch(level) if outcome.is_a?(Hash)

      case outcome
      when :fail
        raise Secupdater::UpdateCommandFailed.new("bundle update failed", 1, "could not resolve #{name}")
      when :abort
        raise Secupdater::Error, "lockfile is frozen"
      when :unchanged
        []
      else
        after = JSON.generate(JSON.parse(before).merge(name => outcome))
        File.write(LOCKFILE, after)
        [Secupdater::FileChange.new(LOCKFILE, "update", after, before)]
      end
    end

    def satisfies_requirement?(version, requirement)
      Gem::Requirement.create(requirement).satisfied_by?(Gem::Version.create(version))
    end
  end
end

RSpec.describe Secupdater::Update do
  subject(:update) { described_class.new(logger, ecosystem, publisher: publisher) }

  let(:log) { StringIO.new }
  let(:logger) { Dry.Logger(:test, stream: log, template: "%<severity>s %<message>s", level: :debug) }
  let(:ecosystem) { UpdateSpec::FakeEcosystem.new(outcomes) }
  let(:publisher) { instance_double(Secupdater::Publisher) }
  let(:published) { [] }

  let(:lockfile) { { "rack" => "1.0", "nokogiri" => "1.0" } }

  def advisory(gem, id, patched = ">= 2.0") = Secupdater::SecurityAdvisory.new(gem, id, [patched])

  def lockfile_on_disk = JSON.parse(File.read("Gemfile.lock"))

  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        File.write("Gemfile.lock", JSON.generate(lockfile))
        example.run
      end
    end
  end

  before do
    allow(publisher).to receive(:call) { |*args| published << args } if publisher
  end

  describe "#call(advisories)" do
    context "one gem with 2 advisories updates to a patched version" do
      let(:outcomes) { { "rack" => "2.1" } }
      let(:advisories) { [advisory("rack", "cve/1"), advisory("rack", "cve/2")] }

      it "calls the publisher ONCE for the gem, with both advisories and the changes" do
        update.call(advisories)

        expect(published.length).to eq(1)

        eco, bump, advs, changes = published.first
        expect(eco).to be(ecosystem)
        expect(bump).to have_attributes(from: Gem::Version.new("1.0"), to: Gem::Version.new("2.1"))
        expect(bump.dependency.name).to eq("rack")
        expect(advs.map(&:report_id)).to contain_exactly("cve/1", "cve/2")
        expect(changes.map(&:filename)).to eq(["Gemfile.lock"])
        expect(JSON.parse(changes.first.content)).to include("rack" => "2.1")
      end

      it "logs which upgrade resolves each advisory" do
        update.call(advisories)

        expect(log.string).to match(%r{^INFO .*rack.*1\.0.*2\.1.*cve/1})
        expect(log.string).to match(%r{^INFO .*rack.*1\.0.*2\.1.*cve/2})
      end
    end

    context "update lands below the patched version" do
      let(:outcomes) { { "rack" => "1.5" } }

      it "warns with the from/to versions and doesn't publish" do
        update.call([advisory("rack", "cve/1")])

        expect(published).to be_empty
        expect(log.string).to match(/^WARN .*rack.*1\.0.*1\.5/)
      end
    end

    context "nothing changes for the first gem" do
      let(:outcomes) { { "rack" => :unchanged, "nokogiri" => "2.0" } }

      it "warns that it's stuck at the current version and continues to the next gem" do
        update.call([advisory("rack", "cve/1"), advisory("nokogiri", "cve/2")])

        expect(log.string).to match(/^WARN .*rack.*1\.0/)
        expect(published.map { it[1].dependency.name }).to eq(["nokogiri"])
      end
    end

    context "bundle update fails for the first gem" do
      let(:outcomes) { { "rack" => :fail, "nokogiri" => "2.0" } }

      it "records the failure and continues to the next gem" do
        update.call([advisory("rack", "cve/1"), advisory("nokogiri", "cve/2")])

        expect(log.string).to match(/^ERROR .*rack.*could not resolve rack/m)
        expect(published.map { it[1].dependency.name }).to eq(["nokogiri"])
      end
    end

    context "two vulnerable gems" do
      let(:outcomes) { { "rack" => "2.1", "nokogiri" => "2.0" } }
      let(:advisories) { [advisory("rack", "cve/1"), advisory("nokogiri", "cve/2")] }

      it "restores the lockfile between gems so each MR only has its own changes" do
        update.call(advisories)

        expect(ecosystem.lockfiles_seen[["nokogiri", :patch]]).to eq(lockfile)

        nokogiri_changes = published.find { it[1].dependency.name == "nokogiri" }[3]
        expect(JSON.parse(nokogiri_changes.first.content)).to eq("rack" => "1.0", "nokogiri" => "2.0")
      end

      it "leaves the lockfile as it found it" do
        update.call(advisories)

        expect(lockfile_on_disk).to eq(lockfile)
      end
    end

    context "an advisory for a gem that isn't in the lockfile" do
      let(:outcomes) { { "rack" => "2.1" } }

      it "raises Secupdater::Error naming the gem, before attempting any updates" do
        expect { update.call([advisory("rack", "cve/1"), advisory("left-pad", "cve/2")]) }
          .to raise_error(Secupdater::Error, /left-pad/)

        expect(ecosystem.lockfiles_seen).to be_empty
      end
    end

    context "no publisher configured (dry run)" do
      let(:publisher) { nil }
      let(:outcomes) { { "rack" => "2.1" } }

      it "updates and logs without publishing" do
        update.call([advisory("rack", "cve/1")])

        expect(log.string).to match(%r{^INFO .*rack.*2\.1.*cve/1})
        expect(lockfile_on_disk).to eq(lockfile)
      end

      it "returns :resolved for the gem" do
        expect(update.call([advisory("rack", "cve/1")])).to eq("rack" => :resolved)
      end
    end

    context "the patch update resolves the advisory" do
      let(:outcomes) { { "rack" => { patch: "2.0.1" } } }

      it "doesn't try the minor or major updates" do
        update.call([advisory("rack", "cve/1")])

        expect(ecosystem.attempts).to eq([["rack", :patch]])
        expect(published.length).to eq(1)
      end
    end

    context "the patch update is unresolved but the minor update resolves it" do
      let(:outcomes) { { "rack" => { patch: "1.0.1", minor: "2.1" } } }

      it "restores the lockfile before trying the minor update" do
        update.call([advisory("rack", "cve/1")])

        expect(ecosystem.lockfiles_seen[["rack", :minor]]).to eq(lockfile)
      end

      it "publishes the minor update's changes" do
        expect(update.call([advisory("rack", "cve/1")])).to eq("rack" => :published)

        _, bump, _, changes = published.first
        expect(bump.to).to eq(Gem::Version.new("2.1"))
        expect(JSON.parse(changes.first.content)).to include("rack" => "2.1")
      end

      it "logs which level resolved it" do
        update.call([advisory("rack", "cve/1")])

        expect(log.string).to match(%r{^INFO .*rack.*2\.1 \(minor\).*cve/1})
      end
    end

    context "the patch and minor updates fail but the major update resolves it" do
      let(:outcomes) { { "rack" => { patch: :fail, minor: :fail, major: "2.1" } } }

      it "returns :published without logging an error" do
        expect(update.call([advisory("rack", "cve/1")])).to eq("rack" => :published)
        expect(log.string).not_to match(/^ERROR/)
      end
    end

    context "every level fails" do
      let(:outcomes) { { "rack" => :fail } }

      it "tries each level, then returns :failed" do
        expect(update.call([advisory("rack", "cve/1")])).to eq("rack" => :failed)
        expect(ecosystem.attempts.map(&:last)).to eq([:patch, :minor, :major])
      end

      it "logs the last level's failure once, as an error" do
        update.call([advisory("rack", "cve/1")])

        expect(log.string.scan(/could not resolve rack/).length).to eq(3)
        expect(log.string).not_to include("major update:")
      end
    end

    context "publishing fails for the first gem" do
      let(:outcomes) { { "rack" => "2.1", "nokogiri" => "2.0" } }

      before do
        allow(publisher).to receive(:call) do |_, bump, *|
          raise Secupdater::PublishFailed, "branch already exists" if bump.dependency.name == "rack"

          published << bump
        end
      end

      it "returns :failed for that gem and continues to the next gem" do
        results = update.call([advisory("rack", "cve/1"), advisory("nokogiri", "cve/2")])

        expect(results).to eq("rack" => :failed, "nokogiri" => :published)
        expect(published.map { it.dependency.name }).to eq(["nokogiri"])
      end

      it "doesn't try the other levels" do
        update.call([advisory("rack", "cve/1")])

        expect(ecosystem.attempts).to eq([["rack", :patch]])
      end

      it "logs the failure as an error" do
        update.call([advisory("rack", "cve/1")])

        expect(log.string).to match(/^ERROR rack: branch already exists/)
      end

      it "leaves the lockfile as it found it" do
        update.call([advisory("rack", "cve/1")])

        expect(lockfile_on_disk).to eq(lockfile)
      end
    end

    context "an error that isn't an update failure" do
      let(:outcomes) { { "rack" => :abort, "nokogiri" => "2.0" } }

      it "stops the run without trying other levels or gems" do
        expect { update.call([advisory("rack", "cve/1"), advisory("nokogiri", "cve/2")]) }
          .to raise_error(Secupdater::Error, "lockfile is frozen")

        expect(ecosystem.attempts).to eq([["rack", :patch]])
      end

      it "leaves the lockfile as it found it" do
        expect { update.call([advisory("rack", "cve/1")]) }.to raise_error(Secupdater::Error)

        expect(lockfile_on_disk).to eq(lockfile)
      end
    end

    context "a mix of outcomes" do
      let(:lockfile) { { "rack" => "1.0", "nokogiri" => "1.0", "puma" => "1.0", "rails" => "1.0" } }
      let(:outcomes) { { "rack" => "2.1", "nokogiri" => "1.5", "puma" => :unchanged, "rails" => :fail } }

      it "returns a result per gem" do
        results = update.call(%w[rack nokogiri puma rails].map { advisory(it, "cve/#{it}") })

        expect(results).to eq(
          "rack" => :published,
          "nokogiri" => :unresolved,
          "puma" => :unchanged,
          "rails" => :failed
        )
      end
    end
  end
end
