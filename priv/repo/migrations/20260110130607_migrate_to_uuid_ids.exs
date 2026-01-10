defmodule TodosMcp.Repo.Migrations.MigrateToUuidIds do
  use Ecto.Migration

  def change do
    # Drop the old table with integer IDs
    drop(table(:todos))

    # Recreate with UUID primary key
    create table(:todos, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:title, :string, null: false)
      add(:description, :text, default: "")
      add(:completed, :boolean, default: false, null: false)
      add(:priority, :string, default: "medium", null: false)
      add(:due_date, :date)
      add(:tags, {:array, :string}, default: [])
      add(:position, :integer)

      timestamps(type: :utc_datetime)
    end

    create(index(:todos, [:completed]))
    create(index(:todos, [:priority]))
    create(index(:todos, [:due_date]))
  end
end
