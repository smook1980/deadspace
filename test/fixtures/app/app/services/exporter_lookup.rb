class ExporterLookup
  def self.for(format) = Object.const_get("#{format.upcase}Exporter")
end
