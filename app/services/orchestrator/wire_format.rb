module Orchestrator
  # The MCP/JSON-RPC wire format is camelCase (an external protocol
  # requirement, not a style choice) while everything on the Ruby side --
  # service objects, local variables, model attributes -- is idiomatic
  # snake_case. This is the single conversion point between the two,
  # applied once at each tool's response boundary (see McpTools::ToolResponse)
  # rather than camelCase leaking into internal computation.
  module WireFormat
    module_function

    def camelize_keys(value)
      case value
      when Hash
        value.each_with_object({}) { |(k, v), h| h[k.to_s.camelize(:lower).to_sym] = camelize_keys(v) }
      when Array
        value.map { |v| camelize_keys(v) }
      else
        value
      end
    end

    def underscore_keys(value)
      case value
      when Hash
        value.each_with_object({}) { |(k, v), h| h[k.to_s.underscore.to_sym] = underscore_keys(v) }
      when Array
        value.map { |v| underscore_keys(v) }
      else
        value
      end
    end
  end
end
