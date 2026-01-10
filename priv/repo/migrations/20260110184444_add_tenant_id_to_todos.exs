defmodule TodosMcp.Repo.Migrations.AddTenantIdToTodos do
  use Ecto.Migration

  def change do
    alter table(:todos) do
      add(:tenant_id, :string, null: false, default: "default")
    end

    create(index(:todos, [:tenant_id]))
  end
end
