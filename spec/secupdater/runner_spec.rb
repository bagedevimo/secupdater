require "secupdater"
require "tmpdir"

RSpec.describe Secupdater::Runner do
  describe "#initialize" do
    context "with ecosystem 'rubygems'" do
      it "resolves the Rubygems ecosystem" do
        expect(Secupdater::Ecosystem).to receive(:resolve).with("rubygems").and_call_original

        described_class.new(ecosystem: "rubygems")
      end
    end

    context "with an unknown ecosystem" do
      it "raises Secupdater::Error naming the ecosystem" do
        expect { described_class.new(ecosystem: "npm") }.to raise_error(Secupdater::Error, /npm/)
      end
    end
  end

  describe "#call(advisories_path)" do
    subject(:runner) { described_class.new(ecosystem: "rubygems", publisher: publisher) }

    let(:ecosystem) { instance_double(Secupdater::Ecosystem::Rubygems) }
    let(:publisher) { instance_double(Secupdater::Publisher) }
    let(:update) { instance_double(Secupdater::Update, call: { "rack" => :published }) }
    let(:advisories) { [Secupdater::SecurityAdvisory.new("rack", "cve/1", [">= 2.0"])] }

    around do |example|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { example.run }
      end
    end

    before do
      File.write("audit.json", "{}")
      allow(Secupdater::Ecosystem).to receive(:resolve).and_return(ecosystem)
      allow(ecosystem).to receive(:parse_advisories) { |io| advisories if io.read == "{}" }
      allow(Secupdater::Update).to receive(:new).and_return(update)
    end

    it "parses the advisories file with the ecosystem and passes them to Update" do
      expect(runner.call("audit.json")).to eq("rack" => :published)

      expect(Secupdater::Update).to have_received(:new)
        .with(an_instance_of(Dry::Logger::Dispatcher), ecosystem, publisher: publisher)
      expect(update).to have_received(:call).with(advisories)
    end

    context "when the advisories file doesn't exist" do
      it "raises Secupdater::Error naming the path" do
        expect { runner.call("missing.json") }.to raise_error(Secupdater::Error, "Cannot open missing.json")
      end
    end
  end
end
