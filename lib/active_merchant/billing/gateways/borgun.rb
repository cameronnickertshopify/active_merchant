require 'nokogiri'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class BorgunGateway < Gateway
      self.display_name = 'Borgun'
      self.homepage_url = 'http://www.borgun.com'

      self.test_url = 'https://gatewaytest.borgun.is/ws/Heimir.pub.ws:Authorization'
      self.live_url = 'https://gateway01.borgun.is/ws/Heimir.pub.ws:Authorization'

      self.supported_countries = %w[IS GB HU CZ DE DK SE]
      self.default_currency = 'ISK'
      self.money_format = :cents
      self.supported_cardtypes = %i[visa master american_express diners_club discover jcb]

      self.homepage_url = 'https://www.borgun.is/'

      def initialize(options = {})
        requires!(options, :processor, :merchant_id, :username, :password)
        super
      end

      def purchase(money, payment, options = {})
        post = {}
        action = ''
        if options[:apply_3d_secure] == '1'
          add_3ds_preauth_fields(post, options)
          action = '3ds_preauth'
        else
          post[:TransType] = '1'
          add_3ds_fields(post, options)
          action = 'sale'
        end
        add_invoice(post, money, options)
        add_payment_method(post, payment)
        commit(action, post, options)
      end

      def authorize(money, payment, options = {})
        post = {}
        action = ''
        if options[:apply_3d_secure] == '1'
          add_3ds_preauth_fields(post, options)
          action = '3ds_preauth'
        else
          post[:TransType] = '5'
          add_3ds_fields(post, options)
          action = 'authonly'
        end
        add_invoice(post, money, options)
        add_payment_method(post, payment)
        commit(action, post, options)
      end

      def capture(money, authorization, options = {})
        post = {}
        post[:TransType] = '1'
        add_invoice(post, money, options)
        add_reference(post, authorization)
        commit('capture', post)
      end

      def refund(money, authorization, options = {})
        post = {}
        post[:TransType] = '3'
        add_invoice(post, money, options)
        add_reference(post, authorization)
        commit('refund', post)
      end

      def void(authorization, options = {})
        post = {}
        # TransType, TrAmount, and currency must match original values from auth or purchase.
        _, _, _, _, _, transtype, tramount, currency = split_authorization(authorization)
        post[:TransType] = transtype
        options[:currency] = options[:currency] || CURRENCY_CODES.key(currency)
        add_invoice(post, tramount.to_i, options)
        add_reference(post, authorization)
        commit('void', post)
      end

      def supports_scrubbing
        true
      end

      def scrub(transcript)
        transcript.gsub(%r((&lt;PAN&gt;)[^&]*(&lt;/PAN&gt;))i, '\1[FILTERED]\2').
          gsub(%r((&lt;CVC2&gt;)[^&]*(&lt;/CVC2&gt;))i, '\1[FILTERED]\2').
          gsub(%r(((?:\r\n)?Authorization: Basic )[^\r\n]+(\r\n)?), '\1[FILTERED]\2')
      end

      private

      CURRENCY_CODES = Hash.new { |_h, k| raise ArgumentError.new("Unsupported currency for HDFC: #{k}") }
      CURRENCY_CODES['ISK'] = '352'
      CURRENCY_CODES['EUR'] = '978'
      CURRENCY_CODES['USD'] = '840'

      def add_3ds_fields(post, options)
        post[:ThreeDSMessageId] = options[:three_ds_message_id] if options[:three_ds_message_id]
        post[:ThreeDS_PARes] = options[:three_ds_pares] if options[:three_ds_pares]
        post[:ThreeDS_CRes] = options[:three_ds_cres] if options[:three_ds_cres]
      end

      def add_3ds_preauth_fields(post, options)
        post[:SaleDescription] = options[:sale_description] || ''
        post[:MerchantReturnURL] = options[:merchant_return_url] if options[:merchant_return_url]
      end

      def add_invoice(post, money, options)
        post[:TrAmount] = amount(money)
        post[:TrCurrency] = CURRENCY_CODES[options[:currency] || currency(money)]
        # The ISK currency must have a currency exponent of 2 on the 3DS request but not on the auth request
        if post[:TrCurrency] == '352' && options[:apply_3d_secure] == '1'
          post[:TrCurrencyExponent] = 2
        else
          post[:TrCurrencyExponent] = 0
        end
        post[:TerminalID] = options[:terminal_id] || '1'
      end

      def add_payment_method(post, payment_method)
        post[:PAN] = payment_method.number
        post[:ExpDate] = format(payment_method.year, :two_digits) + format(payment_method.month, :two_digits)
        post[:CVC2] = payment_method.verification_value
        post[:DateAndTime] = Time.now.strftime('%y%m%d%H%M%S')
        post[:RRN] = 'AMRCNT' + six_random_digits
      end

      def add_reference(post, authorization)
        dateandtime, _batch, transaction, rrn, authcode, = split_authorization(authorization)
        post[:DateAndTime] = dateandtime
        post[:Transaction] = transaction
        post[:RRN] = rrn
        post[:AuthCode] = authcode
      end

      def parse(xml, options = nil)
        response = {}

        doc = Nokogiri::XML(CGI.unescapeHTML(xml))
        body = options[:apply_3d_secure] == '1' ? doc.xpath('//get3DSAuthenticationReply') : doc.xpath('//getAuthorizationReply')
        body = doc.xpath('//cancelAuthorizationReply') if body.length == 0
        body.children.each do |node|
          if node.text?
            next
          elsif node.elements.size == 0
            response[node.name.downcase.to_sym] = node.text
          else
            node.elements.each do |childnode|
              name = "#{node.name.downcase}_#{childnode.name.downcase}"
              response[name.to_sym] = childnode.text
            end
          end
        end
        response
      end

      def commit(action, post, options = {})
        post[:Version] = '1000'
        post[:Processor] = @options[:processor]
        post[:MerchantID] = @options[:merchant_id]

        request = build_request(action, post, options)
        raw = ssl_post(url(action), request, headers)
        pairs = parse(raw, options)
        success = success_from(pairs)

        Response.new(
          success,
          message_from(success, pairs),
          pairs,
          authorization: authorization_from(pairs),
          test: test?
        )
      end

      def success_from(response)
        (response[:actioncode] == '000') || (response[:status_resultcode] == '0')
      end

      def message_from(succeeded, response)
        if succeeded
          'Succeeded'
        else
          response[:message] || "Error with ActionCode=#{response[:actioncode]}"
        end
      end

      def authorization_from(response)
        [
          response[:dateandtime],
          response[:batch],
          response[:transaction],
          response[:rrn],
          response[:authcode],
          response[:transtype],
          response[:tramount],
          response[:trcurrency]
        ].join('|')
      end

      def split_authorization(authorization)
        dateandtime, batch, transaction, rrn, authcode, transtype, tramount, currency = authorization.split('|')
        [dateandtime, batch, transaction, rrn, authcode, transtype, tramount, currency]
      end

      def headers
        {
          'Authorization' => 'Basic ' + Base64.strict_encode64(@options[:username].to_s + ':' + @options[:password].to_s)
        }
      end

      def build_request(action, post, options = {})
        mode = action == 'void' ? 'cancel' : 'get'
        transaction_type = action == '3ds_preauth' ? '3DSAuthentication' : 'Authorization'
        xml = Builder::XmlMarkup.new indent: 18
        xml.instruct!(:xml, version: '1.0', encoding: 'utf-8')
        xml.tag!("#{mode}#{transaction_type}") do
          post.each do |field, value|
            xml.tag!(field, value)
          end
          build_airline_xml(xml, options[:passenger_itinerary_data]) if options[:passenger_itinerary_data]
        end
        inner = CGI.escapeHTML(xml.target!)
        envelope(mode, action).sub(/{{ :body }}/, inner)
      end

      def build_airline_xml(xml, airline_data)
        xml.tag!('PassengerItineraryData') do
          xml.tag!('A1') do
            airline_data.each do |field, value|
              xml.tag!(field, value)
            end
          end
        end
      end

      def envelope(mode, action)
        if action == '3ds_preauth'
          transaction_action = "#{mode}3DSAuthentication"
          request_action = "#{mode}Auth3DSReqXml"
        else
          transaction_action = "#{mode}AuthorizationInput"
          request_action = "#{mode}AuthReqXml"
        end
        <<-XML
          <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:aut="http://Borgun/Heimir/pub/ws/Authorization">
            <soapenv:Header/>
            <soapenv:Body>
              <aut:#{transaction_action}>
                <#{request_action}>
                {{ :body }}
                </#{request_action}>
              </aut:#{transaction_action}>
            </soapenv:Body>
          </soapenv:Envelope>
        XML
      end

      def url(action)
        (test? ? test_url : live_url)
      end

      def six_random_digits
        (0...6).map { rand(48..57).chr }.join
      end
    end
  end
end
