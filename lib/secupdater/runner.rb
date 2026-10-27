module Secupdater
  class Runner
    def initialize(ecosystem:, log_level: :warn, publisher: nil)
      @ecosystem = Secupdater::Ecosystem.resolve(ecosystem)
      @logger = Secupdater.build_logger(log_level: log_level)
      @publisher = publisher
    end

    def call(advisories_path)
      raise Secupdater::Error, "Cannot open #{advisories_path}" unless File.file?(advisories_path)

      advisories = File.open(advisories_path) { @ecosystem.parse_advisories(it) }
      Update.new(@logger, @ecosystem, publisher: @publisher).call(advisories)
    end
  end
end
