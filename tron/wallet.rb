require "peatio/tron/concerns/encryption"

module Tron
  class Wallet < Peatio::Wallet::Abstract
    include Encryption
    
    DEFAULT_FEE = { fee_limit: 1_000_000 }
    DEFAULT_FEATURES = { skip_deposit_collection: false }.freeze

    def initialize(custom_features = {})
      @features = DEFAULT_FEATURES.merge(custom_features).slice(*SUPPORTED_FEATURES)
      @settings = {}
    end

    def configure(settings = {})
      # Clean client state during configure.
      @client = nil

      @settings.merge!(settings.slice(*SUPPORTED_SETTINGS))

      @wallet = @settings.fetch(:wallet) do
        raise Peatio::Wallet::MissingSettingError, :wallet
      end.slice(:uri, :address, :secret)

      @currency = @settings.fetch(:currency) do
        raise Peatio::Wallet::MissingSettingError, :currency
      end.slice(:id, :base_factor, :options)
    end

    def create_address!(options = {})
      client.json_rpc(path: 'wallet/generateaddress')
            .yield_self { |r| { address: r.fetch('address'), secret: r.fetch('privateKey') } }
    rescue Tron::Client::Error => e
      raise Peatio::Wallet::ClientError, e
    end

    def create_transaction!(transaction, options = {})
      if @currency.dig(:options, :trc10_token_id).present?
        create_trc10_transaction!(transaction)
      elsif @currency.dig(:options, :trc20_contract_address).present?
        create_trc20_transaction!(transaction, options)
      else
        create_coin_transaction!(transaction, options)
      end
    rescue Tron::Client::Error => e
      raise Peatio::Wallet::ClientError, e
    end

    def prepare_deposit_collection!(transaction, deposit_spread, deposit_currency)
      # Don't prepare for deposit_collection in case of coin(tron) deposit.
      return [] if is_coin?(deposit_currency)
      return [] if deposit_spread.blank?

      options = DEFAULT_FEE.merge(deposit_currency.fetch(:options).slice(:fee_limit))

      # We collect fees depending on the number of spread deposit size
      # Example: if deposit spreads on three wallets need to collect tron fee for 3 transactions
      fees = convert_from_base_unit(options.fetch(:fee_limit).to_i)
      transaction.amount = fees * deposit_spread.size

      [create_coin_transaction!(transaction)]
    rescue Tron::Client::Error => e
      raise Peatio::Wallet::ClientError, e
    end

    def load_balance!
      if @currency.dig(:options, :trc10_token_id).present?
        client.json_rpc(path: 'wallet/getaccount',
                        params: { address: reformat_decode_address(@wallet.fetch(:address)) }
        ).fetch('assetV2', [])
              .find { |a| a['key'] == @currency[:options][:trc10_token_id] }
              .try(:fetch, 'value', 0)
      elsif @currency.dig(:options, :trc20_contract_address).present?
        client.json_rpc(path: 'wallet/triggersmartcontract',
                        params: {
                          owner_address: reformat_decode_address(@wallet.fetch(:address)),
                          contract_address: reformat_decode_address(@currency.dig(:options, :trc20_contract_address)),
                          function_selector: 'balanceOf(address)',
                          parameter: abi_encode(reformat_decode_address(@wallet.fetch(:address))[2..42]) }
        ).fetch('constant_result')[0].hex
      else
        client.json_rpc(path: 'wallet/getaccount',
                        params: { address: reformat_decode_address(@wallet.fetch(:address)) }
        ).fetch('balance', nil)
      end.yield_self { |amount| convert_from_base_unit(amount.to_i) }
    rescue Tron::Client::Error => e
      raise Peatio::Wallet::ClientError, e
    end

    private

    def create_trc10_transaction!(transaction, options = {})
      currency_options = @currency.fetch(:options).slice(:trc10_token_id)
      options.merge!(currency_options)

      amount = convert_to_base_unit(transaction.amount)

      txid = client.json_rpc(path: 'wallet/easytransferassetbyprivate',
                             params: {
                               privateKey: @wallet.fetch(:secret),
                               toAddress: reformat_decode_address(transaction.to_address),
                               assetId: currency_options.fetch(:trc10_token_id),
                               amount: amount
                             }).dig('transaction', 'txID')
                   .yield_self { |txid| reformat_txid(txid) }

      unless txid
        raise Peatio::Wallet::ClientError, \
            "Withdrawal from #{@wallet.fetch(:address)} to #{transaction.to_address} failed."
      end
      transaction.hash = reformat_txid(txid)
      transaction
    end

    def create_trc20_transaction!(transaction, options = {})
      currency_options = @currency.fetch(:options).slice(:trc20_contract_address, :fee_limit)
      options.merge!(DEFAULT_FEE, currency_options)

      amount = convert_to_base_unit(transaction.amount)

      signed_txn = sign_transaction(transaction, amount, options)

      # broadcast txn
      response = client.json_rpc(path: 'wallet/broadcasttransaction',
                                 params: signed_txn)

      txid = response.fetch('result', false) ? signed_txn.fetch('txID') : nil

      unless txid
        raise Peatio::Wallet::ClientError, \
            "Withdrawal from #{@wallet.fetch(:address)} to #{transaction.to_address} failed."
      end
      transaction.hash = reformat_txid(txid)
      transaction
    end

    def create_coin_transaction!(transaction, options = {})
      amount = convert_to_base_unit(transaction.amount)
      txid = client.json_rpc(path: 'wallet/easytransferbyprivate',
                             params: {
                               privateKey: @wallet.fetch(:secret),
                               toAddress: reformat_decode_address(transaction.to_address),
                               amount: amount
                             }).dig('transaction', 'txID')
                   .yield_self { |txid| reformat_txid(txid) }

      unless txid
        raise Peatio::Wallet::ClientError, \
            "Withdrawal from #{@wallet.fetch(:address)} to #{transaction.to_address} failed."
      end
      transaction.currency_id = 'trx' if transaction.currency_id.blank?
      transaction.amount = convert_from_base_unit(amount)
      transaction.hash = reformat_txid(txid)
      transaction.options = options
      transaction
    end

    def sign_transaction(transaction, amount, options)
      client.json_rpc(path: 'wallet/gettransactionsign',
                      params: {
                        transaction: trigger_smart_contract(transaction, amount, options),
                        privateKey: @wallet.fetch(:secret)
                      })
    end

    def trigger_smart_contract(transaction, amount, options)
      client.json_rpc(path: 'wallet/triggersmartcontract',
                      params: {
                        contract_address: reformat_decode_address(options.fetch(:trc20_contract_address)),
                        function_selector: 'transfer(address,uint256)',
                        parameter: abi_encode(reformat_decode_address(transaction.to_address)[2..42], amount.to_s(16)),
                        fee_limit: options.fetch(:fee_limit),
                        owner_address: reformat_decode_address(@wallet.fetch(:address))
                      }).fetch('transaction')
    end

    def is_coin?(deposit_currency)
      deposit_currency.dig(:options, :trc20_contract_address).blank?
    end

    def convert_from_base_unit(value)
      value.to_d / @currency.fetch(:base_factor)
    end

    def convert_to_base_unit(value)
      x = value.to_d * @currency.fetch(:base_factor)
      unless (x % 1).zero?
        raise Peatio::Wallet::ClientError,
              "Failed to convert value to base (smallest) unit because it exceeds the maximum precision: " \
          "#{value.to_d} - #{x.to_d} must be equal to zero."
      end
      x.to_i
    end

    def client
      uri = @wallet.fetch(:uri) { raise Peatio::Wallet::MissingSettingError, :uri }
      @client ||= Client.new(uri)
    end
  end
end