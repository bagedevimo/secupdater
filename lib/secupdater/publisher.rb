module Secupdater
  class Publisher
    attr_reader :ecosystem, :bump, :advisories, :changes

    def initialize = raise NotImplementedError

    # Returns [status, message], with a message explaining any status other
    # than :published (e.g. :declined, :skipped or :up_to_date)
    def run = raise NotImplementedError

    def call(ecosystem, dependency_bump, advisories, changes)
      @ecosystem = ecosystem
      @bump = dependency_bump
      @advisories = advisories
      @changes = changes

      run
    end

    # Called once every dependency has been through #call, with the names of all
    # the dependencies that have advisories. Returns messages about anything it
    # tidied up.
    def finish(vulnerable_names) = []

    REFERENCE_PATTERN = %r{\Asecurity/(?<name>.+)-(?<version>[^-]+)\z}

    def reference = "security/#{bump.dependency.name}-#{bump.to}"

    def title = "Upgrade #{ecosystem.ecosystem_name} dependency #{bump.dependency.name} to version #{bump.to}"

    def description
      heading = "Upgrade #{ecosystem.ecosystem_name} dependency #{bump.dependency.name} to version #{bump.to} to address the following security advisories:"
      # Advisories for other dependencies this update also fixes say which one
      items = advisories.map do |advisory|
        advisory.name == bump.dependency.name ? "* #{advisory.report_id}" : "* #{advisory.report_id} (#{advisory.name})"
      end.join("\n")
      "#{heading}\n\n#{items}\n"
    end
    
    private
    def pluralize(count, singular, plural = nil)
      if count == 1
        "#{count} #{singular}"
      elsif plural
        "#{count} #{plural}"
      else
        "#{count} #{singular}s"
      end
    end
  end

end
