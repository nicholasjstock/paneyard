class AddUsageTelemetryToWorkers < ActiveRecord::Migration[8.1]
  def change
    add_column :workers, :model, :string
    add_column :workers, :agent_turn_count, :integer
    add_column :workers, :input_tokens, :bigint
    add_column :workers, :output_tokens, :bigint
    add_column :workers, :cache_read_input_tokens, :bigint
    add_column :workers, :cache_creation_input_tokens, :bigint
    add_column :workers, :total_cost_usd, :decimal, precision: 12, scale: 6
  end
end
