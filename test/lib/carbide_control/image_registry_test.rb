# frozen_string_literal: true

# ruby test/lib/carbide_control/image_registry_test.rb
#
# No Rails boot and no gems beyond minitest: ImageRegistry is a plain module
# over Net::HTTP, and a test that needed a database to check an HTTP retry
# would not get run.

require 'minitest/autorun'
require 'json'
require 'net/http'

LIB = File.expand_path('../../../lib', __dir__)
$LOAD_PATH.unshift(LIB) unless $LOAD_PATH.include?(LIB)
require 'carbide_control/image_registry'

# A GitLab-shaped registry: every /v2 read is 401 + a Bearer challenge until a
# token minted at the realm is presented. Records every request so the test can
# assert what was sent, which is where the bugs are.
class FakeRegistry
  Response = Struct.new(:code, :body, :headers) do
    def [](key) = headers[key.downcase]
    def is_a?(klass) = klass == Net::HTTPSuccess ? code == '200' : super
  end

  CHALLENGE = 'Bearer realm="https://gitlab.example/jwt/auth",' \
              'service="container_registry",scope="repository:ns/carbide2:pull"'

  attr_reader :requests

  def initialize(token: 'minted-token', anonymous: false, token_status: '200')
    @token = token
    @anonymous = anonymous
    @token_status = token_status
    @requests = []
  end

  def request(uri, req)
    @requests << { host: uri.host, path: req.path, auth: req['Authorization'], accept: req['Accept'] }
    return token_response if uri.host == 'gitlab.example'
    return ok if @anonymous

    if req['Authorization'].to_s == "Bearer #{@token}"
      ok
    else
      Response.new('401', '', { 'www-authenticate' => CHALLENGE })
    end
  end

  def ok = Response.new('200', JSON.generate({ 'tags' => %w[aaa bbb] }), {})

  def token_response
    return Response.new(@token_status, '', {}) unless @token_status == '200'

    Response.new('200', JSON.generate({ 'token' => @token }), {})
  end
end

class ImageRegistryAuthTest < Minitest::Test
  def setup
    @fake = nil
    @env = {}
    set_env('REGISTRY_URL' => 'https://registry.example:5009',
            'REGISTRY_PATH' => 'ns',
            'REGISTRY_USERNAME' => 'FrankD',
            'REGISTRY_PASSWORD' => 'gldt-secret')
  end

  def teardown
    @env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def set_env(pairs)
    pairs.each do |k, v|
      @env[k] = ENV[k] unless @env.key?(k)
      v.nil? ? ENV.delete(k) : ENV[k] = v
    end
  end

  # Swap http_for so no socket is opened; the module keeps building real
  # Net::HTTP::Get objects, so header construction is genuinely under test.
  def with_registry(fake)
    @fake = fake
    mod = CarbideControl::ImageRegistry
    mod.singleton_class.send(:alias_method, :http_for_real, :http_for)
    mod.define_singleton_method(:http_for) { |uri| FakeConn.new(uri, TEST_FAKE) }
    yield
  ensure
    mod.singleton_class.send(:alias_method, :http_for, :http_for_real)
  end

  FakeConn = Struct.new(:uri, :fake) do
    def request(req) = fake.request(uri, req)
  end

  def run_with(fake, &block)
    Object.const_set(:TEST_FAKE, fake)
    with_registry(fake, &block)
  ensure
    Object.send(:remove_const, :TEST_FAKE) if Object.const_defined?(:TEST_FAKE)
  end

  # The bug: without this exchange every read 401s, the controller turns the
  # raise into a 502, and the dashboard says "no registry configured".
  def test_a_bearer_challenge_is_answered_and_the_read_retried
    fake = FakeRegistry.new
    result = run_with(fake) { CarbideControl::ImageRegistry.send(:get, '/v2/ns/carbide2/tags/list') }

    assert_equal %w[aaa bbb], result['tags']
    assert_equal 3, fake.requests.length, 'challenge, token, retry'
    assert_equal 'gitlab.example', fake.requests[1][:host], 'the token comes from the realm'
    assert_equal 'Bearer minted-token', fake.requests[2][:auth]
  end

  # The realm already named the repository and action. Rebuilding that string is
  # how a namespaced repo gets the scope wrong.
  def test_the_scope_is_taken_from_the_challenge_not_reconstructed
    fake = FakeRegistry.new
    run_with(fake) { CarbideControl::ImageRegistry.send(:get, '/v2/ns/carbide2/tags/list') }

    assert_includes fake.requests[1][:path], 'scope=repository%3Ans%2Fcarbide2%3Apull'
    assert_includes fake.requests[1][:path], 'service=container_registry'
  end

  def test_the_token_request_carries_the_credentials
    fake = FakeRegistry.new
    run_with(fake) { CarbideControl::ImageRegistry.send(:get, '/v2/ns/carbide2/tags/list') }

    refute_nil fake.requests[1][:auth]
    assert fake.requests[1][:auth].start_with?('Basic '), fake.requests[1][:auth].to_s
  end

  # A self-hosted registry answers anonymously and must not be sent down the
  # token path at all.
  def test_an_anonymous_registry_is_read_in_one_request
    set_env('REGISTRY_USERNAME' => nil, 'REGISTRY_PASSWORD' => nil)
    fake = FakeRegistry.new(anonymous: true)
    result = run_with(fake) { CarbideControl::ImageRegistry.send(:get, '/v2/ns/carbide2/tags/list') }

    assert_equal %w[aaa bbb], result['tags']
    assert_equal 1, fake.requests.length
    assert_nil fake.requests[0][:auth]
  end

  # A token endpoint that refuses must surface the registry's 401 rather than
  # retrying forever or reporting success.
  def test_a_refused_token_leaves_the_original_failure_visible
    fake = FakeRegistry.new(token_status: '403')
    err = assert_raises(RuntimeError) do
      run_with(fake) { CarbideControl::ImageRegistry.send(:get, '/v2/ns/carbide2/tags/list') }
    end

    assert_match(/401/, err.message)
  end

  def test_a_non_bearer_challenge_is_not_followed
    header = 'Basic realm="registry"'

    assert_nil CarbideControl::ImageRegistry.send(:bearer_challenge, header)
  end

  def test_the_challenge_parses_into_its_parts
    parsed = CarbideControl::ImageRegistry.send(:bearer_challenge, FakeRegistry::CHALLENGE)

    assert_equal 'https://gitlab.example/jwt/auth', parsed['realm']
    assert_equal 'container_registry', parsed['service']
  end
end

# The manifest walk (index -> platform manifest -> config blob). Only successes
# are memoized: a nil also covers a transient failure, and caching it would
# strand the tag until the pod restarts.
class ImageRegistryMetaCacheTest < Minitest::Test
  class FakeManifests
    Response = Struct.new(:code, :body, :headers) do
      def [](key) = headers[key.downcase]
      def is_a?(klass) = klass == Net::HTTPSuccess ? code == '200' : super
    end

    attr_reader :requests

    def initialize(map)
      @map = map
      @requests = []
    end

    def request(_uri, req)
      @requests << req.path
      body = @map.find { |frag, _| req.path.include?(frag) }&.last
      return Response.new('500', '', {}) if body == :error

      Response.new('200', JSON.generate(body || {}), {})
    end
  end

  VALID = {
    'manifests/aaa'        => { 'manifests' => [{ 'platform' => { 'architecture' => 'amd64' },
                                                  'digest' => 'sha256:plat' }] },
    'manifests/sha256:plat' => { 'config' => { 'digest' => 'sha256:cfg' } },
    'blobs/sha256:cfg'      => { 'config' => { 'Labels' => { 'org.carbide.version' => '0.6.0',
                                                             'org.carbide.codename' => 'magnum',
                                                             'org.carbide.commit_time' => '2026-09-16T00:00:00Z' },
                                             'Env' => [] } }
  }.freeze

  Conn = Struct.new(:uri, :fake) do
    def request(req) = fake.request(uri, req)
  end

  def setup
    @saved = ENV.to_h.slice('REGISTRY_URL', 'REGISTRY_PATH', 'REGISTRY_USERNAME', 'REGISTRY_PASSWORD')
    ENV['REGISTRY_URL'] = 'https://registry.example:5009'
    ENV['REGISTRY_PATH'] = 'ns'
    ENV.delete('REGISTRY_USERNAME')
    ENV.delete('REGISTRY_PASSWORD')
    reset_cache
  end

  def teardown
    @saved.each { |k, v| ENV[k] = v }
    reset_cache
  end

  def reset_cache
    CarbideControl::ImageRegistry.instance_variable_set(:@cache, {})
  end

  def run_with(fake)
    mod  = CarbideControl::ImageRegistry
    conn = fake
    mod.singleton_class.send(:alias_method, :http_for_real, :http_for)
    mod.define_singleton_method(:http_for) { |uri| Conn.new(uri, conn) }
    yield
  ensure
    mod.singleton_class.send(:alias_method, :http_for, :http_for_real)
  end

  def test_valid_metadata_is_read_and_then_served_from_cache
    fake   = FakeManifests.new(VALID)
    first  = run_with(fake) { CarbideControl::ImageRegistry.image_meta_for('carbide2', 'aaa') }
    reread = run_with(fake) { CarbideControl::ImageRegistry.image_meta_for('carbide2', 'aaa') }

    assert_equal '0.6.0', first[:version]
    assert_equal 'magnum', first[:codename]
    assert_equal first, reread
    assert_equal 1, fake.requests.count { |p| p.include?('manifests/aaa') }, 'second read is cached'
  end

  # A manifest with no config digest: the walk returns nil and must re-walk.
  def test_a_malformed_manifest_is_not_cached
    fake = FakeManifests.new('manifests/bbb' => {})
    run_with(fake) { assert_nil CarbideControl::ImageRegistry.image_meta_for('carbide2', 'bbb') }
    run_with(fake) { assert_nil CarbideControl::ImageRegistry.image_meta_for('carbide2', 'bbb') }

    assert_equal 2, fake.requests.count { |p| p.include?('manifests/bbb') }, 'nil is re-walked'
  end

  # A 500 is transient. Cached, it would strand the tag until the pod restarts.
  def test_a_failed_fetch_is_not_cached
    fake = FakeManifests.new('manifests/ccc' => :error)
    run_with(fake) { assert_nil CarbideControl::ImageRegistry.image_meta_for('carbide2', 'ccc') }
    run_with(fake) { assert_nil CarbideControl::ImageRegistry.image_meta_for('carbide2', 'ccc') }

    assert_equal 2, fake.requests.count { |p| p.include?('manifests/ccc') }, 'a failed read retries'
  end
end
