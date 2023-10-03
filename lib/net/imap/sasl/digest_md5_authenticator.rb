# frozen_string_literal: true

# Net::IMAP authenticator for the +DIGEST-MD5+ SASL mechanism type, specified
# in RFC-2831[https://tools.ietf.org/html/rfc2831].  See Net::IMAP#authenticate.
#
# == Deprecated
#
# "+DIGEST-MD5+" has been deprecated by
# RFC-6331[https://tools.ietf.org/html/rfc6331] and should not be relied on for
# security.  It is included for compatibility with existing servers.
class Net::IMAP::SASL::DigestMD5Authenticator
  DataFormatError    = Net::IMAP::DataFormatError
  ResponseParseError = Net::IMAP::ResponseParseError
  private_constant :DataFormatError, :ResponseParseError

  STAGE_ONE = :stage_one
  STAGE_TWO = :stage_two
  STAGE_DONE = :stage_done
  private_constant :STAGE_ONE, :STAGE_TWO, :STAGE_DONE

  # Authentication identity: the identity that matches the #password.
  #
  # RFC-2831[https://tools.ietf.org/html/rfc2831] uses the term +username+.
  # "Authentication identity" is the generic term used by
  # RFC-4422[https://tools.ietf.org/html/rfc4422].
  # RFC-4616[https://tools.ietf.org/html/rfc4616] and many later RFCs abbreviate
  # this to +authcid+.
  attr_reader :username
  alias authcid username

  # A password or passphrase that matches the #username.
  #
  # The +password+ will be used to create the response digest.
  attr_reader :password

  # Authorization identity: an identity to act as or on behalf of.  The identity
  # form is application protocol specific.  If not provided or left blank, the
  # server derives an authorization identity from the authentication identity.
  # The server is responsible for verifying the client's credentials and
  # verifying that the identity it associates with the client's authentication
  # identity is allowed to act as (or on behalf of) the authorization identity.
  #
  # For example, an administrator or superuser might take on another role:
  #
  #     imap.authenticate "DIGEST-MD5", "root", ->{passwd}, authzid: "user"
  #
  attr_reader :authzid

  # A namespace or collection of identities which contains +username+.
  #
  # Used by DIGEST-MD5, GSS-API, and NTLM.  This is often a domain name that
  # contains the name of the host performing the authentication.
  #
  # <em>Defaults to the last realm in the server-provided list of
  # realms.</em>
  attr_reader :realm

  # Fully qualified canonical DNS host name for the requested service.
  #
  # <em>Defaults to #realm.</em>
  attr_reader :host

  # The service protocol, a
  # {registered GSSAPI service name}[https://www.iana.org/assignments/gssapi-service-names/gssapi-service-names.xhtml],
  # e.g. "imap", "ldap", or "xmpp".
  #
  # For Net::IMAP, the default is "imap" and should not be overridden.  This
  # must be set appropriately to use authenticators in other protocols.
  #
  # If an IANA-registered name isn't available, GSS-API
  # (RFC-2743[https://tools.ietf.org/html/rfc2743]) allows the generic name
  # "host".
  attr_reader :service

  # The generic server name when the server is replicated.
  #
  # Not used by other \SASL mechanisms.  +service_name+ will be ignored when it
  # is +nil+ or identical to +host+.
  #
  # From RFC-2831[https://tools.ietf.org/html/rfc2831]:
  # >>>
  #     The service is considered to be replicated if the client's
  #     service-location process involves resolution using standard DNS lookup
  #     operations, and if these operations involve DNS records (such as SRV, or
  #     MX) which resolve one DNS name into a set of other DNS names.  In this
  #     case, the initial name used by the client is the "serv-name", and the
  #     final name is the "host" component.
  attr_reader :service_name

  # Parameters sent by the server are stored in this hash.
  attr_reader :sparams

  # The charset sent by the server.  "UTF-8" (case insensitive) is the only
  # allowed value.  +nil+ should be interpreted as ISO 8859-1.
  attr_reader :charset

  # nonce sent by the server
  attr_reader :nonce

  # qop-options sent by the server
  attr_reader :qop

  # :call-seq:
  #   new(authcid:,  password:, authzid:  nil, **options) -> authenticator
  #   new(username:, password:, authzid:  nil, **options) -> authenticator
  #   new(username,  password,  authzid = nil, **options) -> authenticator
  #
  # Creates an Authenticator for the "+DIGEST-MD5+" SASL mechanism.
  #
  # Called by Net::IMAP#authenticate and similar methods on other clients.
  #
  # ==== Parameters
  #
  # * #username ― Authentication identity that is associated with #password.
  # * #authcid  ― An alias for +username+.
  # * #password ― A password or passphrase associated with this #username.
  # * _optional_ #authzid ― Authorization identity to act as or on behalf of.
  # * _optional_ $realm — A namespace for the #username, e.g. a domain.
  #   <em>Defaults to the last realm in the server-provided .</em>
  # * _optional_ #host — FQDN for requested service.
  #   <em>Defaults to</em> #realm
  # * _optional_ #service_name — The generic host name, when the server is
  #   replicated.
  # * _optional_ #service — the registered service protocol. e.g. "imap",
  #   "smtp", "ldap", "xmpp".  <em>For Net::IMAP, this defaults to "imap".</em>
  # * _optional_ +warn_deprecation+ — Set to +false+ to silence the warning.
  #
  # Any other keyword arguments are silently ignored.
  #
  # When +authzid+ is not set, the server should derive the authorization
  # identity from the authentication identity.
  #
  # See the documentation for each attribute for more details.
  def initialize(user = nil, pass = nil, authz = nil,
                 authcid: nil, username: nil,
                 authzid: nil,
                 password: nil,
                 realm: nil,
                 service: "imap",
                 host: nil,
                 service_name: nil,
                 warn_deprecation: true,
                 **)
    @username     = authcid  || username || user
    @password     = password || pass
    @authzid      = authzid  || authz
    @realm        = realm
    @host         = host
    @service      = service
    @service_name = service_name
    @username or raise ArgumentError, "missing username (authcid)"
    @password or raise ArgumentError, "missing password"
    if warn_deprecation
      warn "WARNING: DIGEST-MD5 SASL mechanism was deprecated by RFC-6331."
    end
    require "digest/md5"
    require "securerandom"
    require "strscan"
    @nc, @stage = {}, STAGE_ONE
  end

  # From RFC-2831[https://tools.ietf.org/html/rfc2831]:
  # >>>
  #     Indicates the principal name of the service with which the client wishes
  #     to connect, formed from the serv-type, host, and serv-name.  For
  #     example, the FTP service on "ftp.example.com" would have a "digest-uri"
  #     value of "ftp/ftp.example.com"; the SMTP server from the example above
  #     would have a "digest-uri" value of "smtp/mail3.example.com/example.com".
  def digest_uri
    if service_name && service_name != host
      "#{service}/#{host}/#{service_name}"
    else
      "#{service}/#{host}"
    end
  end

  def initial_response?; false end

  # Responds to server challenge in two stages.
  def process(challenge)
    case @stage
    when STAGE_ONE
      @stage = STAGE_TWO
      process_stage_one(challenge)
      stage_one_response
    when STAGE_TWO
      @stage = STAGE_DONE
      process_stage_two(challenge)
      "" # if at the second stage, return an empty string
    else
      raise ResponseParseError, challenge
    end
  end

  def done?; @stage == STAGE_DONE end

  private

  def process_stage_one(challenge)
    @sparams = parse_challenge(challenge)
    @qop = sparams.key?("qop") ? ["auth"] : sparams["qop"].flatten

    guard_stage_one(challenge)

    @nonce   = sparams["nonce"]  .first
    @charset = sparams["charset"].first

    @realm ||= sparams["realm"].last
    @host  ||= realm
  end

  def guard_stage_one(challenge)
    if !qop.include?("auth")
      raise DataFormatError, "Server does not support auth (qop = %p)" % [
        sparams["qop"]
      ]
    elsif (emptykey = REQUIRED.find { sparams[_1].empty? })
      raise DataFormatError, "Server didn't send %p (%p)" % [emptykey, challenge]
    elsif (multikey = NO_MULTIPLES.find { sparams[_1].length > 1 })
      raise DataFormatError, "Server sent multiple %p (%p)" % [multikey, challenge]
    end
  end

  def stage_one_response
    response = {
      nonce:        nonce,
      username:     username,
      realm:        realm,
      cnonce:       SecureRandom.base64(32),
      "digest-uri": digest_uri,
      qop:          "auth",
      maxbuf:       65535,
      nc:           "%08d" % nc(nonce),
      charset:      charset,
    }

    response[:authzid]  = authzid unless authzid.nil?
    response[:response] = compute_digest(response)

    format_response(response)
  end

  def process_stage_two(challenge)
    raise ResponseParseError, challenge unless challenge =~ /rspauth=/
  end

  def nc(nonce)
    @nc[nonce] = @nc.key?(nonce) ? @nc[nonce] + 1 : 1
    @nc[nonce]
  end

  def compute_digest(response)
    a1 = compute_a1(response)
    a2 = compute_a2(response)
    Digest::MD5.hexdigest(
      [
        Digest::MD5.hexdigest(a1),
        response.values_at(:nonce, :nc, :cnonce, :qop),
        Digest::MD5.hexdigest(a2)
      ].join(":")
    )
  end

  def compute_a0(response)
    Digest::MD5.digest(
      [ response.values_at(:username, :realm), password ].join(":")
    )
  end

  def compute_a1(response)
    a0 = compute_a0(response)
    a1 = [ a0, response.values_at(:nonce, :cnonce) ].join(":")
    a1 << ":#{response[:authzid]}" unless response[:authzid].nil?
    a1
  end

  def compute_a2(response)
    a2 = "AUTHENTICATE:#{response[:"digest-uri"]}"
    if response[:qop] and response[:qop] =~ /^auth-(?:conf|int)$/
      a2 << ":00000000000000000000000000000000"
    end
    a2
  end

  # Directives which must not have multiples.  The RFC states:
  # >>>
  #   This directive may appear at most once; if multiple instances are present,
  #   the client should abort the authentication exchange.
  NO_MULTIPLES = %w[nonce stale maxbuf charset algorithm].freeze

  # Required directives which must occur exactly once.  The RFC states: >>>
  #   This directive is required and MUST appear exactly once; if not present,
  #   or if multiple instances are present, the client should abort the
  #   authentication exchange.
  REQUIRED = %w[nonce algorithm].freeze

  # Directives which are composed of one or more comma delimited tokens
  QUOTED_LISTABLE = %w[qop cipher].freeze

  private_constant :NO_MULTIPLES, :REQUIRED, :QUOTED_LISTABLE

  LWS        = /[\r\n \t]*/n # less strict than RFC, more strict than '\s'
  TOKEN      = /[^\x00-\x20\x7f()<>@,;:\\"\/\[\]?={}]+/n
  QUOTED_STR = /"(?: [\t\x20-\x7e&&[^"]] | \\[\x00-\x7f] )*"/nx
  LIST_DELIM = /(?:#{LWS} , )+ #{LWS}/nx
  AUTH_PARAM = /
    (#{TOKEN}) #{LWS} = #{LWS} (#{QUOTED_STR} | #{TOKEN}) #{LIST_DELIM}?
  /nx

  private_constant :LWS, :TOKEN, :QUOTED_STR, :LIST_DELIM, :AUTH_PARAM

  def parse_challenge(challenge)
    sparams = Hash.new {|h, k| h[k] = [] }
    c = StringScanner.new(challenge)
    c.skip LIST_DELIM
    while c.scan AUTH_PARAM
      k, v = c[1], c[2]
      k = k.downcase
      if v =~ /\A"(.*)"\z/mn
        v = $1.gsub(/\\(.)/mn, '\1')
        v = split_quoted_list(v, challenge) if QUOTED_LISTABLE.include? k
      end
      sparams[k] << v
    end
    c.eos? or raise DataFormatError, "Bad Challenge: %p" % [challenge]
    sparams.any? or raise DataFormatError, "Bad Challenge: %p" % [challenge]
    sparams
  end

  def split_quoted_list(value, challenge)
    value.split(LIST_DELIM).reject(&:empty?).tap do
      _1.any? or raise DataFormatError, "Bad Challenge: %p" % [challenge]
    end
  end

  def format_response(response)
    response
      .keys
      .map {|key| qdval(key.to_s, response[key]) }
      .join(",")
  end

  # some responses need quoting
  def qdval(key, val)
    return if key.nil? or val.nil?
    if %w[username authzid realm nonce cnonce digest-uri qop].include? key
      val = val.gsub(/([\\"])/n, "\\\1")
      '%s="%s"' % [key, val]
    else
      "%s=%s" % [key, val]
    end
  end

end
