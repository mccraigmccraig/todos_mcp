defmodule TodosMcp.Repo.Migrations.RemoveTenantIdDefault do
  use Ecto.Migration

  def change do
    alter table(:todos) do
      modify(:tenant_id, :string, null: false, default: nil)
    end
  end
end
