class CreateWebauthnCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :webauthn_credentials do |t|
      t.references :user, null: false, foreign_key: true
      t.string :external_id, null: false        # credential ID from the authenticator
      t.text   :public_key,  null: false        # COSE public key (PEM/encoded)
      t.bigint :sign_count,  null: false, default: 0
      t.string :nickname,    null: false        # user-facing label, e.g. "YubiKey"
      t.timestamps
    end

    add_index :webauthn_credentials, :external_id, unique: true
    add_index :webauthn_credentials, [:user_id, :nickname], unique: true
  end
end
