# Lists available image tags from the self-hosted registry (ADR-025).
# "What exists," not "what is compatible" (the Decider's question, ADR-020).
class Api::V1::Control::RegistryController < ApplicationController
  def images
    unless CarbideControl::ImageRegistry.available?
      return render json: { error: 'registry not configured (REGISTRY_URL)' }, status: :service_unavailable
    end

    render json: { images: CarbideControl::ImageRegistry.list_images }
  rescue StandardError => e
    render json: { error: e.message }, status: :bad_gateway
  end
end
