class CreateWebauthnChallenges < ActiveRecord::Migration[8.1]
  def change
    create_table :webauthn_challenges do |t|
      t.string :challenge, null: false
      t.datetime :expires_at, null: false
      t.boolean :consumed, null: false, default: false
      t.timestamps
    end

    add_index :webauthn_challenges, :challenge, unique: true
    add_index :webauthn_challenges, :expires_at
  end
end
