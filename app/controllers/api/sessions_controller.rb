class Api::SessionsController < ApplicationController
  skip_before_action :authenticate_request, only: [:create, :signup]

  USER_TOKEN_TTL = 24 * 60 * 60  # 24h. Dashboard tokens, not workspace tokens.

  # POST /api/login {email, password}
  def create
    user = User.find_by(email: params[:email].to_s.downcase.strip)
    if user&.valid_password?(params[:password])
      render json: { token: mint_user_token(user), user: user_json(user) }
    else
      render json: { error: 'invalid credentials' }, status: :unauthorized
    end
  end

  # POST /api/signup {email, password}
  def signup
    user = User.new(email: params[:email].to_s.downcase.strip, password: params[:password])
    if user.save
      render json: { token: mint_user_token(user), user: user_json(user) }, status: :created
    else
      render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/logout — JWT is stateless; client just drops the token.
  def destroy
    head :no_content
  end

  private

  def mint_user_token(user)
    payload = {
      iss:     'carbide-control',
      sub:     "user:#{user.id}",
      aud:     'control:dashboard',
      iat:     Time.now.to_i,
      exp:     Time.now.to_i + USER_TOKEN_TTL,
      user_id: user.id,
      scope:   'control:user'
    }
    JWT.encode(payload, CARBIDE_JWT_SECRET, 'HS256')
  end

  def user_json(user)
    { id: user.id, email: user.email }
  end
end
