module DatabaseCleaning
  EXCLUDED_TABLES = %w[ar_internal_metadata schema_migrations].freeze

  module_function

  def clean!
    ApplicationRecord.connection_pool.with_connection do |connection|
      connection.disable_referential_integrity do
        tables(connection).each do |table|
          connection.execute("DELETE FROM #{connection.quote_table_name(table)}")
        end

        reset_sqlite_sequences(connection)
      end
    end
  end

  def tables(connection)
    connection.tables - EXCLUDED_TABLES
  end

  def reset_sqlite_sequences(connection)
    return unless connection.adapter_name.casecmp("SQLite").zero?
    return unless connection.data_source_exists?("sqlite_sequence")

    connection.execute("DELETE FROM sqlite_sequence")
  end
end

RSpec.configure do |config|
  config.before(:suite) do
    DatabaseCleaning.clean!
  end

  config.around do |example|
    DatabaseCleaning.clean!
    example.run
    DatabaseCleaning.clean!
  end
end
